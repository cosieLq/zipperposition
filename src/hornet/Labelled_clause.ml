
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Labelled Clause} *)

open Libzipperposition
open Hornet_types

module T = FOTerm

type t = labelled_clause

let make c sel subst lc_real_subst : t =
  {lc_clause=c; lc_sel=sel; lc_subst=subst; lc_real_subst}

let make_empty (c:clause) (sel:select_lit): t =
  (* initial subst: maps each var to itself *)
  let subst =
    IArray.to_seq c.c_lits
    |> Sequence.flat_map Lit.vars_seq
    |> T.VarSet.of_seq
    |> T.VarSet.to_seq
    |> Sequence.map (fun v -> v, T.var v)
    |> Type.VarMap.of_seq
  in
  make c sel subst (Lazy.from_val Subst.empty)

let equal = Hornet_types_util.equal_lc
let hash = Hornet_types_util.hash_lc
let compare = Hornet_types_util.compare_lc
let pp = Hornet_types_util.pp_lc
let to_string = CCFormat.to_string pp

let filter_subst = Hornet_types_util.lc_filter_subst

let to_subst (lc:t): Subst.t = Lazy.force lc.lc_real_subst

let to_subst_real lc_subst: Subst.t =
  let sc = 0 in
  filter_subst lc_subst
  |> Sequence.map
    (fun (v,t) ->
       (* add scope, perform ugly casting *)
       ((v:Type.t HVar.t:>InnerTerm.t HVar.t),sc), ((t:T.t:>InnerTerm.t),sc))
  |> Subst.of_seq

let apply_subst ~renaming subst (lc,sc) =
  let lc_subst =
    Type.VarMap.map (fun t -> Subst.FO.apply ~renaming subst (t,sc))
      lc.lc_subst
  in
  { lc with lc_subst; lc_real_subst=lazy (to_subst_real lc_subst) }

let is_empty (lc:t) =
  let subst = to_subst lc in
  Subst.is_empty subst || Subst.is_renaming subst

let to_dismatch (lc:t): Dismatching_constr.t =
  filter_subst lc.lc_subst
  |> Sequence.map (fun (v,t) -> T.var v, t)
  |> Sequence.to_rev_list
  |> CCFun.tap (fun l -> assert (l<>[]))
  |> Dismatching_constr.make
