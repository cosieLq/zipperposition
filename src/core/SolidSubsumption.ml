module TS = Term.Set
module T  = Term
module VT = T.VarTbl
module L = Literal
module Ls = Literals
module IntSet = Set.Make(CCInt)
module SU = SolidUnif

(* Meta subst *)
module MS = Term.VarMap

exception SolidMatchFail
exception UnsupportedLiteralKind

type multiterm =
  (* Application of Builtin constant to a list of multiterms.
     Third argument are possible replacements. *)
  | AppBuiltin of Builtin.t * multiterm list * TS.t
  (* Application of constants or bound variables to a list of multiterms.
     Head can be represented possibly in many ways!
     Third argument are possible replacements. *)
  | App of TS.t * multiterm list * TS.t
  (* Lambda abstraction of multiterms *)
  | Fun of Type.t * multiterm 
  (* Replacements that are either bound variables or constants *)
  | Repl of TS.t

let bvar_or_const t =
  Term.is_const t || Term.is_bvar t

let app_builtin b args repls =
  if TS.for_all bvar_or_const repls then (
    AppBuiltin(b,args,repls)
  ) else invalid_arg "replacements must be bound vars or constants"

let app hd args repls =
  if TS.for_all bvar_or_const hd then (
    if TS.for_all bvar_or_const repls then App (hd,args,repls)
    else invalid_arg "replacements must be bound vars or constants"
  ) else invalid_arg "head of multiterm is bound var or constant"

let fun_ ty body =
  Fun(ty,body)

let fun_l ty_args body =
  List.fold_right fun_ ty_args body

let open_builtin = function
  | AppBuiltin(hd,args,repls) -> (hd,args,repls)
  | _ -> invalid_arg "cannot open builtin"

let open_app = function
  | App(hds,args,repls) -> (hds,args,repls)
  | _ -> invalid_arg "cannot open app"

let open_fun = function
  | Fun(ty,bodys) -> (ty,bodys)
  | _ -> invalid_arg "cannot open fun"

let open_repl = function
  | Repl repls -> repls
  | _ -> invalid_arg "cannot open repl"

let repl repls = 
  if TS.for_all bvar_or_const repls then (
    Repl repls
  ) else invalid_arg "replacements must be bound vars or constants"

let rec pp out = function 
  | AppBuiltin(b,args,repls) ->
    CCFormat.printf "[|@[%a@](@[%a@])|@[%a@]|]" Builtin.pp b (CCList.pp ~sep:" " pp) args (TS.pp ~sep:" " T.pp) repls;
  | App(hds,args,repls) ->
    CCFormat.printf "[|@[%a@](@[%a@])|@[%a@]|]" (TS.pp ~sep:"," ~start:"{" ~stop:"}" T.pp) hds (CCList.pp ~sep:" " pp) args (TS.pp ~sep:" " T.pp) repls;
  | Fun(ty,repls) ->
    CCFormat.printf "[|l@[%a@].@[%a@]|]" Type.pp ty pp repls;
  | Repl repls ->
    CCFormat.printf "{r:@[%a@]}" (TS.pp ~sep:" " T.pp) repls

let cover t solids : multiterm = 
  assert(List.for_all T.is_ground solids);
  (* If the term is not of base type, then it must be a bound variable *)
  assert(List.for_all (fun t -> not @@ Type.is_fun @@ T.ty t || T.is_bvar t) solids);
  let n = List.length solids in

  let rec aux ~depth s_args t : multiterm  =
    (* All the ways in which we can represent term t using solids *)
    let sols_as_db = List.mapi (fun i t -> 
      (t,T.bvar ~ty:(T.ty t) (n-i-1+depth))) s_args in
    let matches_of_solids target = 
      (CCList.filter_map (fun (s, s_db) -> 
        if T.equal s target then Some s_db else None) 
      sols_as_db)
      |> TS.of_list in
    let db_hits = matches_of_solids t in

    match T.view t with
    | AppBuiltin (hd,args) ->
      app_builtin hd (List.map (aux ~depth s_args) args) db_hits
    | App(hd,args) ->
      assert(not (CCList.is_empty args));
      assert(bvar_or_const hd);
      let hds = TS.add hd @@ matches_of_solids hd in
      let args = List.map (aux ~depth s_args) args in
      app hds args db_hits
    | Fun _ -> 
      assert(TS.is_empty db_hits);
      let ty_args, body = T.open_fun t in
      let d_inc = List.length ty_args in
      let s_args' = List.map (T.DB.shift d_inc) s_args in
      let res = aux ~depth:(depth+d_inc) s_args' body in
      fun_l ty_args res
    | DB i when i >= depth ->
      if TS.is_empty db_hits then raise SolidMatchFail
      else repl db_hits
    | _ -> repl (TS.add t db_hits) in
  aux ~depth:0 solids t

let term_intersection s t =
  let rec aux s t =  
    match s with 
    | AppBuiltin(s_b,s_args,s_repls) ->
      let (t_b,t_args,t_repls) = open_builtin t in
      if s_b = t_b then (
        let args = List.map (fun (s,t) -> aux s t) @@ 
                    List.combine s_args t_args in
        app_builtin s_b args (TS.inter s_repls t_repls)
      ) else raise SolidMatchFail
    | App(s_hds,s_args,s_repls) ->
      let (t_hds,t_args,t_repls) = open_app t in
      let i_hds = TS.inter s_hds t_hds in
      if not @@ TS.is_empty i_hds then (
        let args = List.map (fun (s,t) -> aux s t) @@ 
                      List.combine s_args t_args in
        app i_hds args (TS.inter s_repls t_repls)
      ) else raise SolidMatchFail
    | Fun(s_ty,s_bodys) ->
      let t_ty,t_bodys = open_fun t in
      if Type.equal s_ty t_ty then (
        fun_ s_ty (aux s_bodys t_bodys)
      ) else raise SolidMatchFail
    | Repl(repls) ->
      let res = TS.inter repls (open_repl t) in
      if TS.is_empty res then raise SolidMatchFail
      else repl res
  in
  try 
    aux s t
  with Invalid_argument s ->
    Util.debugf 3 "Incompatible constructors: %s" (fun k -> k s);
    raise SolidMatchFail


let refine_subst subst var t = 
  if not @@ MS.mem var subst then (
    MS.add var t subst
  ) else (
    let old = CCOpt.get_exn @@ MS.get var subst in
    MS.add var (term_intersection old t) subst 
  )

let solid_match ~subst ~pattern ~target =
  assert(T.is_ground target);

  let rec aux subst l r =
    match T.view l with
    | AppBuiltin(b, args) ->
      begin match T.view r with 
      | AppBuiltin(b', args') 
        when Builtin.equal b b' && List.length args = List.length args' ->
        List.fold_left 
          (fun subst (l',r') ->  aux subst l' r') 
        subst (List.combine args args')
      | _ -> raise SolidMatchFail end
    | App(hd, args) when T.is_var hd -> 
      refine_subst subst (T.as_var_exn hd) (cover r args)
    | App(hd, args) -> 
      assert(T.is_const hd || T.is_bvar hd);
      begin match T.view r with 
      | App(hd', args') when T.equal hd hd' ->
        assert(List.length args = List.length args');
        List.fold_left 
          (fun subst (l',r') ->  aux subst l' r') 
        subst (List.combine args args')
      | _ -> raise SolidMatchFail end
    | Fun(ty, body) ->
      let prefix, body = T.open_fun l in
      let prefix', body' = T.open_fun r in
      assert(List.length prefix = List.length prefix');
      aux subst body body'
    | Var x -> refine_subst subst x (cover r [])
    | _ -> if T.equal l r then subst else raise SolidMatchFail 
  in
  
  if Type.equal (T.ty pattern) (T.ty target) then aux subst pattern target
  else raise SolidMatchFail

let normaize_clauses subsumer target =
  let eta_exp_snf ?(f=CCFun.id) =
     Ls.map (fun t -> f @@ Lambda.eta_expand @@ Lambda.snf @@ t) in
  
  let target' = 
    Ls.ground_lits @@ eta_exp_snf target in
  
  let subsumer = eta_exp_snf subsumer in
  let args_to_remove = VT.create 16 in

  (* We populate app_var_map to contain indices of all arguments that
     should be removed *)
  Ls.Seq.terms subsumer
  |> Iter.flat_map T.Seq.subterms
  |> Iter.iter (fun s ->
      if Term.is_app_var s then (
        let hd,args = T.as_var_exn (T.head_term s), T.args s in
        let res = ref (VT.get_or args_to_remove hd ~default:IntSet.empty) in
        CCList.iteri (fun i arg -> 
          let ty = T.ty arg in
          if not @@ IntSet.mem i !res then (
            if Type.is_fun ty then (
              if not @@ T.is_bvar (Lambda.eta_reduce arg) then (
                res := IntSet.add i !res;
            )) else (
              if not @@ T.is_ground arg then (
                res := IntSet.add i !res;
            )))
        ) args;
        VT.replace args_to_remove hd !res;
    ));
  let max_var = Ls.Seq.vars subsumer
                |> Iter.max ~lt:(fun x y -> HVar.id x < HVar.id y)
                |> CCOpt.map HVar.id
                |> CCOpt.get_or ~default:0 in
  let counter = ref (max_var +1) in
  let arg_prune_subst = 
    VT.to_seq args_to_remove
    |> Iter.fold (fun subst (var, idxs) -> 
      let arg_tys, ret_ty = Type.open_fun @@ HVar.ty var in
      let n = List.length arg_tys in
      let matrix_args = 
        List.mapi (fun i ty -> 
          if IntSet.mem i idxs then None else Some (T.bvar ty (n-i-1))) arg_tys
        |> CCList.filter_map CCFun.id in
      let fresh_var_ty = Type.arrow (List.map T.ty matrix_args) ret_ty in
      let fresh_var = HVar.fresh_cnt ~counter ~ty:fresh_var_ty () in
      let matrix = T.app (T.var fresh_var) matrix_args in
      let subs_term = T.fun_l arg_tys matrix in
      Subst.FO.bind' subst (var,0) (subs_term,0)
    ) Subst.empty in
  
  let subsumer' =
    Ls.apply_subst Subst.Renaming.none arg_prune_subst (subsumer,0)
    |> eta_exp_snf ~f:(SU.solidify ~limit:false)  in
  subsumer', target'

let cmp_by_sign l1 l2 =
  let sign l = 
    let res = 
      match l with 
      | L.Equation (l, r, sign) ->
        if sign && T.is_true_or_false r then T.equal r T.true_ else sign
      | L.Int o -> Int_lit.sign o
      | L.False -> false
      | _ -> true 
    in
    if res then 1 else 0 in

  CCOrd.int (sign l1) (sign l2)

let cmp_by_weight l1 l2 = 
  CCOrd.int (L.ho_weight l1) (L.ho_weight l2)

let subsumption_cmp l1 l2 =
  let sign_res = cmp_by_sign l1 l2 in
  if sign_res != 0 then sign_res
  else cmp_by_weight l1 l2

let lit_matchers ~subst ~pattern ~target k =
  begin match pattern with
  | L.Equation(lhs,rhs,sign) ->
    begin match target with
    | L.Equation(lhs', rhs',sign') ->
      if sign=sign' then (
        try 
          let subst = (solid_match ~subst ~pattern:lhs ~target:lhs') in
          k (solid_match ~subst ~pattern:rhs ~target:rhs')
        with SolidMatchFail -> ();
        try 
          let subst = (solid_match ~subst ~pattern:lhs ~target:rhs') in
          k (solid_match ~subst ~pattern:rhs ~target:lhs')
        with SolidMatchFail -> ()) 
      | _ -> () end
  | L.True -> begin match target with | L.True -> k subst | _ -> () end
  | L.False -> begin match target with | L.False -> k subst | _ -> () end
  | _ -> 
    raise UnsupportedLiteralKind end

let check_subsumption_possibility subsumer target =
  let is_more_specific pattern target =
    not @@ Iter.is_empty (lit_matchers ~subst:MS.empty ~pattern ~target) in

  let neg_s, neg_t = CCPair.map_same CCBV.cardinal (Ls.neg subsumer, Ls.neg target) in 
  let pos_s, pos_t = CCPair.map_same CCBV.cardinal (Ls.pos subsumer, Ls.pos target) in
  Ls.ho_weight subsumer <= Ls.ho_weight target && 
  neg_s <= neg_t && pos_s <= pos_t &&
  (not (neg_t >=3 || pos_t >= 3) ||
    CCArray.for_all (fun l -> CCArray.exists (is_more_specific l) target) subsumer)


let subsumes subsumer target =
  let n = Array.length subsumer in
  (* let subsumer_o, target_o = subsumer, target in *)
  
  let rec aux ?(i=0) picklist subst subsumer target =
    if i >= n then ( 
      (* CCFormat.printf "SUCESS:@.s:@[%a@];@.t:@[%a@]@.subst:@[%a@]@."
        Ls.pp subsumer Ls.pp target (MS.pp HVar.pp pp) subst; *)
      true
    )
    else (
      let lit = subsumer.(i) in
      CCArray.exists (fun (j,lit') -> 
        if CCBV.get picklist j || cmp_by_sign lit lit' != 0
           || cmp_by_weight lit lit' > 0 then false
        else (
          Iter.exists (fun subst ->
            CCBV.set picklist j;
            let res = aux ~i:(i+1) picklist subst subsumer target in
            CCBV.reset picklist j;
            res) (lit_matchers ~subst ~pattern:lit ~target:lit')
        )) (CCArray.mapi (fun i l -> (i,l)) target)
    ) in


  let subsumer,target = normaize_clauses subsumer target in

  CCArray.sort subsumption_cmp subsumer;
  CCArray.sort subsumption_cmp target;

  if check_subsumption_possibility subsumer target then (
    let picklist = CCBV.create ~size:(Array.length target) false in
    let res = aux picklist MS.empty subsumer target in
    (* CCFormat.printf 
      "subsumption[%s]:@.S_O:@[%a@]@.S_N:@[%a@]@.T_O:@[%a@]@.T_N:@[%a@]@.@." 
        (if res then "OK" else "FAIL")
        Ls.pp subsumer_o Ls.pp subsumer
        Ls.pp target_o Ls.pp target; *)
    res
  ) else false