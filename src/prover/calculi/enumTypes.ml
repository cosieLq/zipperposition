
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Inference and simplification rules for Algebraic types} *)

open Libzipperposition

module T = FOTerm
module S = Substs
module Lit = Literal
module Lits = Literals

type term = T.t

let prof_detect = Util.mk_profiler "enum_types.detect"
let prof_instantiate = Util.mk_profiler "enum_types.instantiate_vars"

let stat_declare = Util.mk_stat "enum_types.declare"
let stat_simplify = Util.mk_stat "enum_types.simplify"
let stat_instantiate = Util.mk_stat "enum_types.instantiate_axiom"

let section = Util.Section.make ~parent:Const.section "enum_ty"

exception Error of string

let () = Printexc.register_printer
  (function Error s -> Some ("error in enum_types: " ^s)
  | _ -> None)

let error_ s = raise (Error s)
let errorf_ msg = CCFormat.ksprintf msg ~f:error_

(** {2 Inference rules} *)

module type S = sig
  module Env : Env.S
  module C : module type of Env.C

  type decl

  val pp_decl : decl CCFormat.printer

  type declare_result =
    | New of decl
    | AlreadyDeclared of decl

  val declare_ty :
    proof:C.t ProofStep.of_ ->
    ty:Type.t ->
    var:Type.t HVar.t ->
    term list ->
    declare_result
  (** Declare that the given type's domain is the given list of cases
      for the given variable [var] (whose type must be [ty]).
      Will be ignored if the type already has a enum declaration.
      @return either the new declaration, or the already existing one if any *)

  val instantiate_vars : Env.multi_simpl_rule
  (** Instantiate variables whose type is a known enumerated type,
      with all cases of this type. *)

  (** {6 Registration} *)

  val setup : unit -> unit
  (** Register rules in the environment *)
end

let _enable = ref true
let _instantiate_shielded = ref false
let _accept_unary_types = ref true

module Make(E : Env.S) : S with module Env = E = struct
  module Env = E
  module C = Env.C
  module PS = Env.ProofState
  module Ctx = Env.Ctx

  (* one particular enum type. The return type has the shape [id(vars)],
    such as [list(a)] or [map(a,b)] *)
  type decl = {
    decl_ty_id : ID.t;
    decl_ty_vars : Type.t HVar.t list;
    decl_ty : Type.t;  (* id applied to ty_vars (shortcut) *)
    decl_var : Type.t HVar.t; (* x = ... *)
    decl_cases : term list; (* ... t1 | t2 | ... | tn *)
    decl_proof : C.t ProofStep.of_; (* justification for the enumeration axiom *)
    mutable decl_symbols : ID.Set.t; (* set of declared symbols for t1,...,tn *)
  }

  let pp_decl out d =
    Format.fprintf out "@[<1>{enum_ty=@[%a@],@ cases=@[%a@]}@]"
      Type.pp d.decl_ty (Util.pp_list T.pp) d.decl_cases

  (* set of enumerated types (indexed by [decl_ty_id]) *)
  let decls_ = ID.Tbl.create 16

  let on_new_decl = Signal.create ()

  (* check that [var] is the only free variable in all cases *)
  let check_uniq_var_is_ ~var cases =
    List.for_all
      (fun t -> T.Seq.vars t |> Sequence.for_all (HVar.equal var))
      cases

  (* if [ty = id(v1,....,vn)] with the variables pairwise distinct,
     return [id, [v1;...;vn]] else fail *)
  let extract_ty_ ty =
    (* check that all vars in [l] are pairwise distinct *)
    let rec check_all_distinct_ acc l = match l with
      | [] -> true
      | v :: l' ->
          not (CCList.Set.mem ~eq:HVar.equal v acc)
          && check_all_distinct_ (v :: acc) l'
    in
    match Type.view ty with
    | Type.App (id, []) -> id, []
    | Type.App (id, l) ->
        begin try
          let l =
            List.map
              (fun a -> match Type.view a with Type.Var v -> v | _ -> raise Exit) l
          in
          if check_all_distinct_ [] l then id,l
          else errorf_ "need variables @[%a@] to be pairwise distinct"
            (Util.pp_list HVar.pp) l;
        with Exit ->
          error_ "need the type to have the shape `const(v1,...,vn)`"
        end
    | _ ->
        error_ "need the type to have the shape `const(v1,...,vn)`"

  let can_extract_ty ty =
    try ignore (extract_ty_ ty); true
    with Error _ -> false

  type declare_result =
    | New of decl
    | AlreadyDeclared of decl

  (* declare an enumerated type *)
  let declare_ty ~proof ~ty ~var cases =
    if List.exists (fun t -> not (Type.equal ty (T.ty t))) cases
      then errorf_ "invalid declaration @[%a@]@ (type mismatch)" (Util.pp_list T.pp) cases;
    let id, ty_vars = extract_ty_ ty in
    if not (check_uniq_var_is_ ~var cases)
      then errorf_ "invalid declaration %a (free variables)" (Util.pp_list T.pp) cases;
    try
      let decl = ID.Tbl.find decls_ id in
      Util.debugf ~section 3 "@[an enum is already declared for type %a@]"
        (fun k->k ID.pp id);
      AlreadyDeclared decl
    with Not_found ->
      Util.debugf ~section 1 "@[<2>declare new enum type @[%a@]@ @[(cases %a = %a)@]"
        (fun k->k Type.pp ty HVar.pp var (Util.pp_list ~sep:"|" T.pp) cases);
      Util.incr_stat stat_declare;
      (* set of already declared symbols *)
      let decl_symbols =
        List.fold_left
          (fun set t -> match T.head t with
             | None -> errorf_ "non-symbolic case @[%a@]" T.pp t
             | Some s -> ID.Set.add s set)
          ID.Set.empty cases
      in
      let decl = {
        decl_ty_id=id;
        decl_ty_vars=ty_vars;
        decl_ty=ty;
        decl_var=var;
        decl_cases=cases;
        decl_symbols;
        decl_proof=proof;
      } in
      ID.Tbl.add decls_ id decl;
      Signal.send on_new_decl decl;
      New decl

  (* detect whether the clause [c] is a declaration of enum type *)
  let detect_decl_ c =
    let eq_var_ ~var t = match T.view t with
      | T.Var v' -> HVar.equal var v'
      | _ -> false
    and get_var_ t = match T.view t with
      | T.Var v -> v
      | _ -> assert false
    in
    (* loop over literals checking whether they are all of the form
       [var = t] for some [t] *)
    let rec _check_all_vars ~ty ~var acc lits = match lits with
      | [] ->
          (* now also check that no case has free variables other than [var],
              and that there are at least 2 cases *)
          if check_uniq_var_is_ ~var acc
          && (!_accept_unary_types || List.length acc >= 2)
          then Some (ty, var, acc)
          else None
      | Lit.Equation (l, r, true) :: lits' when eq_var_ ~var l ->
          _check_all_vars ~ty ~var (r::acc) lits'
      | Lit.Equation (l, r, true) :: lits' when eq_var_ ~var r ->
          _check_all_vars ~ty ~var (l::acc) lits'
      | _ -> None
    in
    let lits = C.lits c in
    if CCArray.exists (fun l -> not (Lit.is_eq l)) lits then None
    else match Array.to_list lits with
      | Lit.Equation (l,r,true) :: lits when T.is_var l && can_extract_ty (T.ty l) ->
          let var = get_var_ l in
          _check_all_vars ~ty:(T.ty l) ~var [r] lits
      | Lit.Equation (l,r,true) :: lits when T.is_var r && can_extract_ty (T.ty r) ->
          let var = get_var_ r in
          _check_all_vars ~ty:(T.ty r) ~var [l] lits
      | _ -> None

  let detect_declaration c = Util.with_prof prof_detect detect_decl_ c

  (* retrieve variables that are directly under a positive equation *)
  let vars_under_eq_ lits =
    Sequence.of_array lits
    |> Sequence.filter Lit.is_eq
    |> Sequence.flatMap Lit.Seq.terms
    |> Sequence.filter T.is_var

  (* variables occurring under some function symbol (at non-0 depth) *)
  let _shielded_vars lits =
    Sequence.of_array lits
    |> Sequence.flatMap Lit.Seq.terms
    |> Sequence.flatMap T.Seq.subterms_depth
    |> Sequence.fmap
      (fun (v,depth) -> if depth>0 && T.is_var v then Some v else None)
    |> T.Seq.add_set T.Set.empty

  let naked_vars_ lits =
    let v =
      vars_under_eq_ lits
      |> T.Seq.add_set T.Set.empty
    in
    T.Set.diff v (_shielded_vars lits)
    |> T.Set.elements

  (* assuming [length decl.decl_ty_vars = length args], bind them pairwise
     in a substitution *)
  let bind_vars_ (d,sc_decl) (args,sc_args) =
    List.fold_left2
      (fun subst v arg ->
        let v = (v : Type.t HVar.t :> InnerTerm.t HVar.t) in
        Substs.Ty.bind subst (v,sc_decl) (arg,sc_args))
      Substs.empty d.decl_ty_vars args

  (* given a type [ty], find whether it's an enum type, and if it is the
     case return [Some (decl, subst)] *)
  let find_ty_ sc_decl ty sc_ty = match Type.view ty with
    | Type.App (id, l) ->
        begin try
          let d = ID.Tbl.find decls_ id in
          if List.length l = List.length d.decl_ty_vars
          then
            let subst = bind_vars_ (d,sc_decl) (l,sc_ty) in
            Some (d, subst)
          else None
        with Not_found -> None
        end
    | _ -> None

  (* instantiate variables that belong to an enum case *)
  let instantiate_vars_ c =
    (* which variables are candidate? depends on a CLI flag *)
    let vars =
      if !_instantiate_shielded
      then vars_under_eq_ (C.lits c) |> Sequence.to_rev_list
      else naked_vars_ (C.lits c)
    in
    let s_c = 0 and s_decl = 1 in
    CCList.find_map
      (fun v ->
         match find_ty_ s_decl (T.ty v) s_c with
         | None -> None
         | Some (decl, subst) ->
             (* we found an enum type declaration for [v], replace it
                with each case for the enum type *)
             Util.incr_stat stat_simplify;
             let l =
               List.map
                 (fun case ->
                    (* replace [v] with [case] now *)
                    let subst = Unif.FO.unification ~subst (v,s_c) (case,s_decl) in
                    let renaming = Ctx.renaming_clear () in
                    let lits' = Lits.apply_subst ~renaming subst (C.lits c,s_c) in
                    let proof =
                      ProofStep.mk_inference [C.proof c]
                        ~rule:(ProofStep.mk_rule ~subst:[subst] "enum_type_case_switch")
                    in
                    let trail = C.trail c in
                    let c' = C.create_a ~trail lits' proof in
                    Util.debugf ~section 3
                      "@[<2>deduce @[%a@]@ from @[%a@]@ @[(enum_type switch on %a)@]@]"
                      (fun k->k C.pp c' C.pp c Type.pp decl.decl_ty);
                    c')
                 decl.decl_cases
             in
             Some l)
      vars

  let instantiate_vars c = Util.with_prof prof_instantiate instantiate_vars_ c

  (* assume [s args : decl.decl_ty_id] and [s : ty_s] *)
  let instantiate_axiom_ ~ty_s s args decl =
    if ID.Set.mem s decl.decl_symbols
    then None (* already declared *)
    else (
      (* need to add an axiom instance for this symbol and declaration *)
      decl.decl_symbols <- ID.Set.add s decl.decl_symbols;
      (* create the axiom.
         - build [subst = decl.x->s(v1,...,vn)]
         - evaluate [decl.x = decl.t1 | decl.t2 .... | decl.t_m] in subst
      *)
      let vars = List.mapi (fun i ty -> HVar.make ~ty i |> T.var) args in
      let t = T.app (T.const ~ty:ty_s s) vars in
      let subst = bind_vars_ (decl,0) (args,1) in
      let subst = Unif.FO.unification ~subst (T.var decl.decl_var,0) (t,1) in
      let renaming = Ctx.renaming_clear () in
      let lits =
        List.map
          (fun case ->
            Lit.mk_eq
              (S.FO.apply ~renaming subst (t,0))
              (S.FO.apply ~renaming subst (case,1)))
          decl.decl_cases
      in
      let proof =
        ProofStep.mk_inference
          ~rule:(ProofStep.mk_rule "axiom_enum_types") [decl.decl_proof] in
      let trail = C.Trail.empty in
      let c' = C.create ~trail lits proof in
      Util.debugf ~section 3 "@[<2>declare enum type for @[%a@]:@ clause @[%a@]@]"
        (fun k->k ID.pp s C.pp c');
      Util.incr_stat stat_instantiate;
      Some c'
    )

  (* [check_decl_ id ~ty decl] checks whether [ty] is compatible
     with [decl.decl_ty]. If it is the case, let [c a1...an = ty], we
     add the axiom
     [forall x1:a1...xn:an, id(x1...xn) = t_1[x := id(x1..xn)] or ... or t_m[...]]
     where the [t_i] are the cases of [decl] *)
  let check_decl_ ~ty s decl =
    match Type.view ty with
    | Type.App (c, args)
      when ID.equal c decl.decl_ty_id
      && List.length args = List.length decl.decl_ty_vars->
        instantiate_axiom_ ~ty_s:ty s args decl
    | _ -> None

  (* add axioms for new symbol [s] with type [ty], if needed *)
  let _on_new_symbol s ~ty =
    let clauses = match Type.view ty with
      | Type.App (id, _) ->
          begin try
            let decl = ID.Tbl.find decls_ id in
            check_decl_ ~ty s decl |> CCOpt.to_list
          with Not_found -> []
          end
      | _ -> []
    in
    PS.PassiveSet.add (Sequence.of_list clauses)

  let _on_new_decl decl =
    let clauses =
      Signature.fold (Ctx.signature ()) []
        (fun acc s ty ->
           match check_decl_ s ~ty decl with
           | None -> acc
           | Some c -> c::acc)
    in
    PS.PassiveSet.add (Sequence.of_list clauses)

  (* flag for clauses that are declarations of enumerated types *)
  let flag_enumeration_clause = C.new_flag ()

  let is_trivial c =
    C.get_flag flag_enumeration_clause c

  let setup () =
    if !_enable then (
      Util.debug ~section  1 "register handling of enumerated types";
      Env.add_multi_simpl_rule instantiate_vars;
      Env.add_is_trivial is_trivial;
      (* signals: instantiate axioms upon new symbols, or when new
          declarations are added *)
      Signal.on_every Ctx.on_new_symbol
        (fun (s, ty) -> _on_new_symbol s ~ty);
      Signal.on_every on_new_decl
        (fun decl ->
           _on_new_decl decl;
           (* need to simplify (instantiate) active clauses that have naked
              variables of the given type *)
           Env.simplify_active_with instantiate_vars);
      Signature.iter (Ctx.signature ()) (fun s ty -> _on_new_symbol s ~ty);
      (* detect whether the clause is a declaration of enum type, and if it
          is, declare the type! *)
      let _detect_and_declare c =
        Util.debugf ~section 5 "@[<2>examine clause@ `@[%a@]`@]" (fun k->k C.pp c);
        match detect_declaration c with
          | None -> ()
          | Some (ty,var,cases) ->
              let is_new = declare_ty ~ty ~var ~proof:(C.proof c) cases in
              (* clause becomes redundant if it's a new declaration *)
              match is_new with
              | New _ -> C.set_flag flag_enumeration_clause c true
              | AlreadyDeclared _ -> ()
      in
      Signal.on_every PS.PassiveSet.on_add_clause _detect_and_declare;
      Signal.on_every PS.ActiveSet.on_add_clause _detect_and_declare;
    )
end

(* TODO: during preprocessing, scan clauses to find declarations asap *)

(** {2 As Extension} *)

let extension =
  let register env =
    let module E = (val env : Env.S) in
    let module ET = Make(E) in
    ET.setup ()
  in
  { Extensions.default with
    Extensions.name = "enum_types";
    Extensions.actions=[Extensions.Do register];
  }

let () =
  Extensions.register extension;
  Params.add_opts
    [ "--enum-types"
      , Options.switch_set true _enable
      , " enable inferences for enumerated/inductive types"
    ; "--no-enum-types"
      , Options.switch_set false _enable
      , " disable inferences for enumerated/inductive types"
    ; "--enum-shielded"
      , Options.switch_set true _instantiate_shielded
      , " enable/disable instantiation of shielded variables of enum type"
    ; "--no-enum-shielded"
      , Options.switch_set false _instantiate_shielded
      , " enable/disable instantiation of shielded variables of enum type"
    ; "--enum-unary"
      , Options.switch_set true _accept_unary_types
      , " enable support for unary enum types (one case)"
    ; "--no-enum-unary"
      , Options.switch_set false _accept_unary_types
      , " disable support for unary enum types (one case)"
    ]
