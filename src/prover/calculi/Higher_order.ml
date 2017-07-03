
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 boolean subterms} *)

open Logtk

module BV = CCBV
module T = Term

let section = Util.Section.make ~parent:Const.section "ho"

let stat_eq_res = Util.mk_stat "ho.eq_res.steps"
let stat_eq_res_syntactic = Util.mk_stat "ho.eq_res_syntactic.steps"
let stat_ext_neg = Util.mk_stat "ho.extensionality-.steps"
let stat_complete_eq = Util.mk_stat "ho.complete_eq.steps"
let stat_beta = Util.mk_stat "ho.beta_reduce.steps"
let stat_eta_expand = Util.mk_stat "ho.eta_expand.steps"
let stat_prim_enum = Util.mk_stat "ho.prim_enum.steps"
let stat_elim_pred = Util.mk_stat "ho.elim_pred.steps"
let stat_ho_unif = Util.mk_stat "ho.unif.calls"
let stat_ho_unif_steps = Util.mk_stat "ho.unif.steps"

let prof_eq_res = Util.mk_profiler "ho.eq_res"
let prof_eq_res_syn = Util.mk_profiler "ho.eq_res_syntactic"
let prof_ho_unif = Util.mk_profiler "ho.unif"

module type S = sig
  module Env : Env.S
  module C : module type of Env.C

  (** {6 Registration} *)

  val setup : unit -> unit
  (** Register rules in the environment *)
end

let k_some_ho : bool Flex_state.key = Flex_state.create_key()
let k_enabled : bool Flex_state.key = Flex_state.create_key()
let k_enable_ho_unif : bool Flex_state.key = Flex_state.create_key()
let k_enable_ho_prim : bool Flex_state.key = Flex_state.create_key()
let k_ho_prim_max_penalty : int Flex_state.key = Flex_state.create_key()

module Make(E : Env.S) : S with module Env = E = struct
  module Env = E
  module C = Env.C
  module Ctx = Env.Ctx

  (* @param vars the free variables the parameter must depend upon
     @param ty_ret the return type *)
  let mk_parameter =
    let n = ref 0 in
    fun vars ty_ret ->
      let i = CCRef.incr_then_get n in
      let id = ID.makef "#k%d" i in
      ID.set_payload id (ID.Attr_parameter i);
      let ty_vars, vars =
        List.partition (fun v -> Type.is_tType (HVar.ty v)) vars
      in
      let ty =
        Type.forall_fvars ty_vars
          (Type.arrow (List.map HVar.ty vars) ty_ret)
      in
      T.app_full (T.const id ~ty)
        (List.map Type.var ty_vars)
        (List.map T.var vars)

  (* index for ext-neg, to ensure α-equivalent negative equations have the same skolems *)
  module FV_ext_neg = FV_tree.Make(struct
      type t = Literal.t * T.t list (* lit -> skolems *)
      let compare = CCOrd.(pair Literal.compare (list T.compare))
      let to_lits (l,_) = Sequence.return (Literal.Conv.to_form l)
      let labels _ = Util.Int_set.empty
  end)

  let idx_ext_neg_ : FV_ext_neg.t ref = ref (FV_ext_neg.empty())

  (* retrieve skolems for this literal, if any *)
  let find_skolems_ (lit:Literal.t) : T.t list option =
    FV_ext_neg.retrieve_alpha_equiv_c !idx_ext_neg_ (lit, [])
    |> Sequence.find_map
      (fun (lit',skolems) ->
         let subst = Literal.variant (lit',0) (lit,1) |> Sequence.head in
         begin match subst with
           | Some subst ->
             let skolems =
               List.map (fun t -> Subst.FO.apply_no_renaming subst (t,0)) skolems
             in
             Some skolems
           | None -> None
         end)

  (* negative extensionality rule:
     [f != g] where [f : a -> b] becomes [f k != g k] for a fresh parameter [k] *)
  let ext_neg (lit:Literal.t): Literal.t option = match lit with
    | Literal.Equation (f, g, false)
      when Type.is_fun (T.ty f) &&
           not (T.is_var f) &&
           not (T.is_var g) &&
           not (T.equal f g) ->
      let n_ty_params, ty_args, _ = Type.open_poly_fun (T.ty f) in
      assert (n_ty_params=0);
      let params = match find_skolems_ lit with
        | Some l -> l
        | None ->
          (* create new skolems, parametrized by free variables *)
          let vars = Literal.vars lit in
          let l = List.map (mk_parameter vars) ty_args in
          (* save list *)
          idx_ext_neg_ := FV_ext_neg.add !idx_ext_neg_ (lit,l);
          l
      in
      let new_lit =
        Literal.mk_neq
          (T.app f params)
          (T.app g params)
      in
      Util.incr_stat stat_ext_neg;
      Util.debugf ~section 4
        "(@[ho_ext_neg@ :old `%a`@ :new `%a`@])"
        (fun k->k Literal.pp lit Literal.pp new_lit);
      Some new_lit
    | _ -> None

  (* complete [f = g] into [f x1…xn = g x1…xn] for each [n ≥ 1] *)
  let complete_eq_args (c:C.t) : C.t list =
    let var_offset = C.Seq.vars c |> Type.Seq.max_var |> succ in
    let new_c =
      C.lits c
      |> Sequence.of_array |> Sequence.zip_i |> Sequence.zip
      |> Sequence.flat_map_l
        (fun (lit_idx,lit) -> match lit with
          | Literal.Equation (t, u, true) when Type.is_fun (T.ty t) ->
            let n_ty_args, ty_args, _ = Type.open_poly_fun (T.ty t) in
            assert (n_ty_args = 0);
            assert (ty_args <> []);
            let vars =
              List.mapi
                (fun i ty -> HVar.make ~ty (i+var_offset) |> T.var)
                ty_args
            in
            let new_lit = Literal.mk_eq (T.app t vars) (T.app u vars) in
            let new_lits = new_lit :: CCArray.except_idx (C.lits c) lit_idx in
            let proof =
              Proof.Step.inference [C.proof_parent c]
                ~rule:(Proof.Rule.mk "ho_complete_eq")
            in
            let new_c =
              C.create new_lits proof ~penalty:(C.penalty c) ~trail:(C.trail c)
            in
            [new_c]
          | _ -> [])
      |> Sequence.to_rev_list
    in
    if new_c<>[] then (
      Util.add_stat stat_complete_eq (List.length new_c);
      Util.debugf ~section 4
        "(@[complete-eq@ :clause %a@ :yields (@[<hv>%a@])@])"
        (fun k->k C.pp c (Util.pp_list ~sep:" " C.pp) new_c);
    );
    new_c

  (* try to eliminate a predicate variable in one fell swoop *)
  let elim_pred_variable (c:C.t) : C.t list =
    (* find unshielded predicate vars *)
    let find_vars(): _ HVar.t Sequence.t =
      C.Seq.vars c
      |> T.VarSet.of_seq |> T.VarSet.to_seq
      |> Sequence.filter
        (fun v ->
           (Type.is_prop @@ Type.returns @@ HVar.ty v) &&
           not (Literals.is_shielded v (C.lits c)))
    (* find all constraints on [v], also returns the remaining literals.
       returns None if some constraints contains [v] itself. *)
    and gather_lits v : (Literal.t list * (T.t list * bool) list) option =
      try
        Array.fold_left
          (fun (others,set) lit ->
             begin match lit with
               | Literal.Prop (t, sign) ->
                 let f, args = T.as_app t in
                 begin match T.view f with
                   | T.Var q when HVar.equal Type.equal v q ->
                     (* found an occurrence *)
                     if List.exists (T.var_occurs ~var:v) args then (
                       raise Exit; (* [P … t[v] …] is out of scope *)
                     );
                     others, (args, sign) :: set
                   | _ -> lit :: others, set
                 end
               | _ -> lit :: others, set
             end)
          ([], [])
          (C.lits c)
        |> CCOpt.return
      with Exit -> None
    in
    (* try to eliminate [v], if it doesn't occur in its own arguments *)
    let try_elim_var v: _ option =
      (* gather constraints on [v] *)
      begin match gather_lits v with
        | None
        | Some (_, []) -> None
        | Some (other_lits, constr_l) ->
          (* gather positive/negative args *)
          let pos_args, neg_args =
            CCList.partition_map
              (fun (args,sign) -> if sign then `Left args else `Right args)
              constr_l
          in
          (* build substitution used for this inference *)
          let subst =
            let some_tup = match pos_args, neg_args with
              | tup :: _, _ | _, tup :: _ -> tup
              | [], [] -> assert false
            in
            let offset = C.Seq.vars c |> T.Seq.max_var |> succ in
            let vars =
              List.mapi (fun i t -> HVar.make ~ty:(T.ty t) (i+offset)) some_tup
            in
            let vars_t = List.map T.var vars in
            let body =
              neg_args
              |> List.map
                (fun tup ->
                   assert (List.length tup = List.length vars);
                   List.map2 T.Form.eq vars_t tup |> T.Form.and_l)
              |> T.Form.or_l
            in
            Util.debugf ~section 5
              "(@[elim-pred-with@ (@[@<1>λ @[%a@].@ %a@])@])"
              (fun k->k (Util.pp_list ~sep:" " Type.pp_typed_var) vars T.pp body);
            Util.incr_stat stat_elim_pred;
            let t = T.fun_of_fvars vars body in
            Subst.FO.of_list [((v:>InnerTerm.t HVar.t),0), (t,0)]
          in
        (* build new clause *)
        let renaming = Ctx.renaming_clear () in
        let new_lits =
          let l1 = Literal.apply_subst_list ~renaming subst (other_lits,0) in
          let l2 =
            CCList.product
              (fun args_pos args_neg ->
                 let args_pos = Subst.FO.apply_l ~renaming subst (args_pos,0) in
                 let args_neg = Subst.FO.apply_l ~renaming subst (args_neg,0) in
                 List.map2 Literal.mk_eq args_pos args_neg)
              pos_args
              neg_args
            |> List.flatten
          in
          l1 @ l2
        in
        let proof =
          Proof.Step.inference ~rule:(Proof.Rule.mk "ho_elim_pred")
            [ C.proof_parent_subst (c,0) subst ]
        in
        let new_c =
          C.create new_lits proof
            ~penalty:(C.penalty c) ~trail:(C.trail c)
        in
        Util.debugf ~section 3
          "(@[<2>elim_pred_var %a@ :clause %a@ :yields %a@])"
          (fun k->k T.pp_var v C.pp c C.pp new_c);
        Some new_c
      end
    in
    begin
      find_vars()
      |> Sequence.filter_map try_elim_var
      |> Sequence.to_rev_list
    end

  (* maximum penalty on clauses to perform Primitive Enum on *)
  let max_penalty_prim_ = E.flex_get k_ho_prim_max_penalty

  (* rule for primitive enumeration of predicates [P t1…tn]
     (using ¬ and ∧ and =) *)
  let prim_enum_ (c:C.t) : C.t list =
    (* set of variables to refine (only those occurring in "interesting" lits) *)
    let vars =
      Literals.fold_lits ~eligible:C.Eligible.always (C.lits c)
      |> Sequence.map fst
      |> Sequence.flat_map Literal.Seq.terms
      |> Sequence.flat_map T.Seq.subterms
      |> Sequence.filter (fun t -> Type.is_prop (T.ty t))
      |> Sequence.filter_map
        (fun t ->
           let hd = T.head_term t in
           begin match T.as_var hd, Type.arity (T.ty hd) with
             | Some v, Type.Arity (0, n)
               when n>0 && Type.returns_prop (T.ty hd) ->
               Some v
             | _ -> None
           end)
      |> T.VarSet.of_seq (* unique *)
    in
    if not (T.VarSet.is_empty vars) then (
      Util.debugf ~section 5 "(@[<hv2>ho.refine@ :clause %a@ :terms {@[%a@]}@])"
        (fun k->k C.pp c (Util.pp_seq T.pp_var) (T.VarSet.to_seq vars));
    );
    let sc_c = 0 in
    let offset = C.Seq.vars c |> T.Seq.max_var |> succ in
    begin
      vars
      |> T.VarSet.to_seq
      |> Sequence.flat_map_l
        (fun v -> HO_unif.enum_prop (v,sc_c) ~offset)
      |> Sequence.map
        (fun (subst,penalty) ->
           let renaming = Ctx.renaming_clear() in
           let lits = Literals.apply_subst ~renaming subst (C.lits c,sc_c) in
           let proof =
             Proof.Step.inference ~rule:(Proof.Rule.mk "ho.refine")
               [C.proof_parent_subst (c,sc_c) subst]
           in
           let new_c =
             C.create_a lits proof
               ~penalty:(C.penalty c + penalty) ~trail:(C.trail c)
           in
           Util.debugf ~section 3
             "(@[<hv2>ho.refine@ :from %a@ :subst %a@ :yields %a@])"
             (fun k->k C.pp c Subst.pp subst C.pp new_c);
           Util.incr_stat stat_prim_enum;
           new_c)
      |> Sequence.to_rev_list
    end

  let prim_enum c =
    if C.penalty c < max_penalty_prim_
    then prim_enum_ c
    else []

  let pp_pairs_ out =
    let open CCFormat in
    Format.fprintf out "(@[<hv>%a@])"
      (Util.pp_list ~sep:" " @@ hvbox @@ HO_unif.pp_pair)

  (* perform HO unif on [pairs].
     invariant: [C.lits c = pairs @ other_lits] *)
  let ho_unif_real_ c pairs other_lits : C.t list =
    Util.debugf ~section 5
      "(@[ho_unif.try@ :pairs (@[<hv>%a@])@ :other_lits %a@])"
      (fun k->k pp_pairs_ pairs (Util.pp_list~sep:" " Literal.pp) other_lits);
    Util.incr_stat stat_ho_unif;
    let offset = C.Seq.vars c |> T.Seq.max_var |> succ in
    begin
      HO_unif.unif_pairs ?fuel:None (pairs,0) ~offset
      |> List.map
        (fun (new_pairs, us, penalty) ->
           let renaming = Ctx.renaming_clear() in
           let subst = Unif_subst.subst us in
           let c_guard = Literal.of_unif_subst ~renaming us in
           let new_pairs =
             List.map
               (fun (env,t,u) ->
                  let t = Subst.FO.apply ~renaming subst (T.fun_l env t,0) in
                  let u = Subst.FO.apply ~renaming subst (T.fun_l env u,0) in
                  Literal.mk_constraint t u)
               new_pairs
           and other_lits =
             Literal.apply_subst_list ~renaming subst (other_lits,0)
           in
           let all_lits = c_guard @ new_pairs @ other_lits in
           let proof =
             Proof.Step.inference ~rule:(Proof.Rule.mk "ho_unif")
               [C.proof_parent_subst (c,0) subst]
           in
           let new_c =
             C.create all_lits proof
               ~trail:(C.trail c) ~penalty:(C.penalty c + penalty)
           in
           Util.debugf ~section 5
             "(@[ho_unif.step@ :pairs (@[%a@])@ :subst %a@ :yields %a@])"
             (fun k->k pp_pairs_ pairs Subst.pp subst C.pp new_c);
           Util.incr_stat stat_ho_unif_steps;
           new_c
        )
    end

  (* HO unification of constraints *)
  let ho_unif (c:C.t) : C.t list =
    if C.lits c |> CCArray.exists Literal.is_ho_constraint then (
      (* separate constraints from the rest *)
      let pairs, others =
        C.lits c
        |> Array.to_list
        |> CCList.partition_map
          (function
            | Literal.Equation (t,u, false) as lit
              when Literal.is_ho_constraint lit -> `Left ([],t,u)
            | lit -> `Right lit)
      in
      assert (pairs <> []);
      Util.enter_prof prof_ho_unif;
      let r = ho_unif_real_ c pairs others in
      Util.exit_prof prof_ho_unif;
      r
    ) else []

  (* rule for β-reduction *)
  let beta_reduce t =
    assert (T.DB.is_closed t);
    let t' = Lambda.snf t in
    if (T.equal t t') then None
    else (
      Util.debugf ~section 4 "(@[beta_reduce `%a`@ :into `%a`@])"
        (fun k->k T.pp t T.pp t');
      Util.incr_stat stat_beta;
      assert (T.DB.is_closed t');
      Some t'
    )

  (* TODO: eta reduction *)
  (* TODO: positive extensionality `m x = n x --> m = n` *)

  (* rule for eta-expansion *)
  let eta_expand t =
    assert (T.DB.is_closed t);
    let t' = Lambda.eta_expand t in
    if (T.equal t t') then None
    else (
      Util.debugf ~section 4 "(@[eta_expand `%a`@ :into `%a`@])"
        (fun k->k T.pp t T.pp t');
      Util.incr_stat stat_eta_expand;
      assert (T.DB.is_closed t');
      Some t'
    )

  let setup () =
    if not (Env.flex_get k_enabled) then (
      Util.debug ~section 1 "HO rules disabled";
    ) else (
      Util.debug ~section 1 "setup HO rules";
      Env.Ctx.lost_completeness();
      Env.add_unary_inf "ho_complete_eq" complete_eq_args;
      Env.add_unary_inf "ho_elim_pred_var" elim_pred_variable;
      Env.add_lit_rule "ho_ext_neg" ext_neg;
      Env.add_rewrite_rule "beta_reduce" beta_reduce;
      Env.add_rewrite_rule "eta_expand" eta_expand;
      if Env.flex_get k_enable_ho_unif then (
        Env.add_unary_inf "ho_unif" ho_unif;
      );
      if Env.flex_get k_enable_ho_prim then (
        Env.add_unary_inf "ho_prim_enum" prim_enum;
      )
    );
    ()
end

let enabled_ = ref true
let enable_unif_ = ref true
let enable_prim_ = ref true
let prim_max_penalty = ref 15 (* FUDGE *)

let st_contains_ho (st:(_,_,_) Statement.t): bool =
  let is_non_atomic_ty ty =
    let n_ty_vars, args, _ = Type.open_poly_fun ty in
    n_ty_vars > 0 || args<>[]
  in
  (* is there a HO variable? *)
  let has_ho_var () =
    Statement.Seq.terms st
    |> Sequence.flat_map T.Seq.vars
    |> Sequence.exists (fun v -> is_non_atomic_ty (HVar.ty v))
  (* is there a HO symbol? *)
  and has_ho_sym () =
    Statement.Seq.ty_decls st
    |> Sequence.exists (fun (_,ty) -> Type.order ty > 1)
  and has_ho_eq() =
    Statement.Seq.forms st
    |> Sequence.exists
      (fun c ->
         c |> List.exists
           (function
             | SLiteral.Eq (t,u) | SLiteral.Neq (t,u) ->
               T.is_ho_at_root t || T.is_ho_at_root u || is_non_atomic_ty (T.ty t)
             | _ -> false))
  in
  has_ho_sym () || has_ho_var () || has_ho_eq()

let extension =
  let register env =
    let module E = (val env : Env.S) in
    if E.flex_get k_some_ho then (
      let module ET = Make(E) in
      ET.setup ()
    )
  (* check if there are HO variables *)
  and check_ho vec state =
    let is_ho =
      CCVector.to_seq vec
      |> Sequence.exists st_contains_ho
    in
    if is_ho then (
      Util.debug ~section 2 "problem is HO"
    );
    state
    |> Flex_state.add k_some_ho is_ho
    |> Flex_state.add k_enabled !enabled_
    |> Flex_state.add k_enable_ho_unif (!enabled_ && !enable_unif_)
    |> Flex_state.add k_enable_ho_prim (!enabled_ && !enable_prim_)
    |> Flex_state.add k_ho_prim_max_penalty !prim_max_penalty
  in
  { Extensions.default with
      Extensions.name = "ho";
      post_cnf_actions=[check_ho];
      env_actions=[register];
  }

let () =
  Options.add_opts
    [ "--ho", Arg.Set enabled_, " enable HO reasoning";
      "--no-ho", Arg.Clear enabled_, " disable HO reasoning";
      "--ho-unif", Arg.Set enable_unif_, " enable full HO unification";
      "--no-ho-unif", Arg.Clear enable_unif_, " disable full HO unification";
      "--ho-prim-enum", Arg.Set enable_unif_, " enable HO primitive enum";
      "--no-ho-prim-enum", Arg.Clear enable_unif_, " disable HO primitive enum";
      "--ho-prim-max", Arg.Set_int prim_max_penalty, " max penalty for HO primitive enum";
    ];
  Extensions.register extension;
