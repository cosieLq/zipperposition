
(* This file is free software, part of Logtk. See file "license" for more details. *)

(** {1 Skolem symbols} *)

module ST = ScopedTerm
module T = FOTerm
module Ty = Type
module S = Substs

let section = Util.Section.(make ~parent:logtk "skolem")

type polarity =
  [ `Pos
  | `Neg
  | `Both
  ]

type definition = {
  form : Formula.FO.t;
  proxy : Formula.FO.t;
  polarity : polarity ref;
}

type ctx = {
  sc_prefix : string;
  sc_prop_prefix : string;
  sc_ty_prop : Type.t;
  mutable sc_gensym : int;              (* new symbols *)
  mutable sc_var_index : int;           (* fresh universal vars *)
  mutable sc_fcache : (F.t * F.t) list; (* cache for skolemization *)
  mutable sc_defs : definition F.Map.t; (* formula -> definition of formula *)
  mutable sc_new_defs : definition list; (* "new" definitions *)
  mutable sc_signature : Signature.t;
}

(* TODO: use a term index for the cache? *)

let create ?(ty_prop=Type.TPTP.o)
    ?(prefix="logtk_sk__") ?(prop_prefix="logtk_prop__") signature =
  let ctx = {
    sc_prefix=prefix;
    sc_prop_prefix=prop_prefix;
    sc_ty_prop=ty_prop;
    sc_gensym = 0;
    sc_var_index = 0;
    sc_fcache = [];
    sc_defs = F.Map.empty;
    sc_new_defs = [];
    sc_signature = signature;
  } in
  ctx

let to_signature ctx = ctx.sc_signature

let fresh_sym_with ~ctx ~ty prefix =
  let n = ctx.sc_gensym in
  ctx.sc_gensym <- n+1;
  let s = Symbol.of_string (prefix ^ string_of_int n) in
  (* declare type of the new symbol *)
  ctx.sc_signature <- Signature.declare ctx.sc_signature s ty;
  Util.debugf ~section 3 "new skolem symbol %a with type %a"
    (fun k->k Symbol.pp s Type.pp ty);
  s

let fresh_sym ~ctx ~ty = fresh_sym_with ~ctx ~ty ctx.sc_prefix

let fresh_ty_const ?(prefix="__logtk_ty") ~ctx () =
  let n = ctx.sc_gensym in
  ctx.sc_gensym <- n+1;
  let s = Symbol.of_string (prefix ^ string_of_int n) in
  Util.debugf ~section 3 "new (type) skolem symbol %a"
    (fun k->k Symbol.pp s);
  s

(* update varindex in [ctx] so that it won't get captured in [t] *)
let update_var ~ctx t =
  let m1 = T.Seq.vars t |> T.Seq.max_var in
  let m2 = T.Seq.ty_vars t |> Type.Seq.max_var in
  let m = max ctx.sc_var_index (max m1 m2) + 1 in
  ctx.sc_var_index <- m

let clear_var ~ctx =
  ctx.sc_var_index <- 0

let fresh_var ~ctx =
  let n = ctx.sc_var_index in
  ctx.sc_var_index <- n + 1;
  n

let apply env f =
  let t = ST.DB.eval env (f : F.t :> ST.t) in
  let t = ST.DB.unshift 1 t in
  match F.of_term t with
  | Some f'' -> f''
  | None ->
      (* got an atom just under the quantifier *)
      assert (T.is_term t);
      F.Base.atom (T.of_term_exn t)

let instantiate_ty f ty =
  let env = DBEnv.singleton (ty : Ty.t :> ST.t) in
  apply env f

let instantiate f t =
  let env = DBEnv.singleton (t : T.t :> ST.t) in
  apply env f

exception FoundFormVariant of F.t * F.t * S.t

let skolem_form ~ctx ~ty f =
  let vars = F.Seq.vars f |> T.Seq.add_set T.Set.empty |> T.Set.elements in
  (* find a variant of [f] *)
  try
    List.iter
      (fun (f', new_f') ->
         Util.debugf ~section 5 "check variant %a and %a" (fun k->k F.pp f F.pp f');
         match Unif.Form.variant f' 1 f 0 |> Sequence.take 1 |> Sequence.to_list with
         | [subst] -> raise (FoundFormVariant (f', new_f', subst))
         | _ -> ())
      ctx.sc_fcache;
    (* fresh symbol with the proper type *)
    let ty_of_vars = List.map T.ty vars in
    let ty = Type.(ty <== ty_of_vars) in
    (* close the type w.r.t its type variables *)
    let tyargs = Type.vars ty in
    let ty = Type.forall tyargs ty in
    let const = T.const ~ty (fresh_sym ~ctx ~ty) in
    let skolem_term = T.app_full const tyargs vars in
    (* replace variable by skolem t*)
    let new_f = instantiate f skolem_term in
    ctx.sc_fcache <- (f, new_f) :: ctx.sc_fcache;
    Util.debugf ~section 5 "skolemize %a using new term %a"
      (fun k->k F.pp f T.pp skolem_term);
    new_f
  with FoundFormVariant(f',new_f',subst) ->
    Util.debugf ~section 5 "form %a is variant of %a under %a"
      (fun k->k F.pp f' F.pp f S.pp subst);
    let new_f = S.Form.apply_no_renaming subst new_f' 1 in
    new_f

(** {2 Definitions} *)

let has_definition ~ctx f =
  F.Map.mem f ctx.sc_defs

let get_definition ~ctx ~polarity f =
  let ty_prop = ctx.sc_ty_prop in
  try
    (* we only check alpha equivalence w.r.t the bound variables (De Bruijn)
     * because it's simple and efficient. *)
    let def = F.Map.find f ctx.sc_defs in
    assert (T.Set.equal (F.free_vars_set f) (F.free_vars_set def.proxy));
    begin match polarity, !(def.polarity) with
      | `Pos, `Pos
      | `Neg, `Neg
      | `Both, `Both -> ()
      | _ ->
          def.polarity := `Both
    end;
    (* same name, no need to introduce a new def! *)
    def.proxy
  with Not_found ->
    (* ok, we have to introduce a new name. It will have all free variables
       (bound in a surrouding scope or not) as arguments. *)
    let vars = F.free_vars f in
    let ty_bvars, bvars = F.de_bruijn_set f in
    let ty_bvars = Type.Set.elements ty_bvars
    and bvars = T.Set.elements bvars in
    let all_vars = vars @ bvars in
    let ty_of_vars = List.map T.ty all_vars in
    (* build the proxy literal *)
    let ty = Type.(forall ty_bvars (ty_prop <== ty_of_vars)) in
    let const = T.const ~ty (fresh_sym_with ~ctx ~ty ctx.sc_prop_prefix) in
    let p = F.Base.atom (T.app_full const ty_bvars all_vars) in
    (* introduce new name for [f] *)
    Util.debugf ~section 5 "define formula %a with %a" (fun k->k F.pp f F.pp p);
    let def = {form=f; proxy=p; polarity=ref polarity; } in
    ctx.sc_defs <- F.Map.add f def ctx.sc_defs;
    (* map bvars to fresh vars and evaluate [p] and [f] to remove them! *)
    let env =
      let l1 = List.map (fun db -> match T.view db with
          | T.BVar i ->
              let v = T.var ~ty:(T.ty db) (fresh_var ~ctx) in
              i, (v : T.t :> ST.t)
          | _ -> assert false) bvars
      and l2 = List.map (fun db -> match Type.view db with
          | Type.BVar i ->
              let v = Type.var (fresh_var ~ctx) in
              i, (v : Type.t :> ST.t)
          | _ -> assert false) ty_bvars
      in
      DBEnv.of_list (l1 @ l2)
    in
    Util.debug ~section 5 "remember def...";
    let p' = ST.DB.eval env (p:F.t:>ST.t) |> F.of_term_exn in
    let f' = ST.DB.eval env (f:F.t:>ST.t) |> F.of_term_exn in
    (* the definition to introduce defines [p'] in function of [f'];
     * they are similar to [p] and [f] but don't have De Bruijn indices *)
    ctx.sc_new_defs <- {form=f'; proxy=p'; polarity=def.polarity; } :: ctx.sc_new_defs;
    Util.debugf ~section 5 "... returning %a" (fun k->k F.pp p);
    (* return proxy *)
    Util.debug ~section 5 "return def.";
    p

let remove_def ~ctx def =
  ctx.sc_defs <- F.Map.remove def.form ctx.sc_defs

let all_definitions ~ctx =
  F.Map.to_seq ctx.sc_defs
  |> Sequence.map snd

let clear_skolem_cache ~ctx =
  ctx.sc_fcache <- []

let pop_new_definitions ~ctx =
  let l = ctx.sc_new_defs in
  List.iter (remove_def ~ctx) l;
  ctx.sc_new_defs <- [];
  l

let has_new_definitions ~ctx = match ctx.sc_new_defs with
  | [] -> false
  | _::_ -> true

let skolem_ho ~ctx:_ ~ty:_ _f = failwith "Skolem_ho: not implemented"
