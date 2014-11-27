
(*
Zipperposition: a functional superposition prover for prototyping
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Clauses} *)

open Logtk

module Hash = CCHash
module BV = CCBV
module ST = ScopedTerm
module T = FOTerm
module S = Substs
module Lit = Literal
module Lits = Literals

let stat_fresh = Util.mk_stat "fresh_clause"
let stat_clause_create = Util.mk_stat "clause_create"
let prof_clause_create = Util.mk_profiler "clause_create"

type scope = Substs.scope

module type S = Clause_intf.S

module ISet = Sequence.Set.Make(CCInt)

(** {2 Type def} *)
module Make(Ctx : Ctx.S) : S with module Ctx = Ctx = struct
  module Ctx = Ctx

  type t = {
    hclits : Literal.t array;               (** the literals *)
    mutable hctag : int;                    (** unique ID of the clause *)
    mutable hcflags : int;                  (** boolean flags for the clause *)
    mutable hcselected : BV.t;              (** bitvector for selected literals *)
    mutable hcproof : Proof.t;              (** Proof of the clause *)
    mutable hcparents : t list;             (** parents of the clause *)
    mutable hcdescendants : int SmallSet.t ;(** the set of IDs of descendants of the clause *)
    mutable hcsimplto : t option;           (** simplifies into the clause *)
    mutable as_bool : int option;           (** boolean wrap *)
    mutable trail : ISet.t;                 (** boolean trail *)
  }

  type clause = t

  (** {2 boolean flags} *)

  let new_flag =
    let flag_gen = Util.Flag.create () in
    fun () -> Util.Flag.get_new flag_gen

  let flag_ground = new_flag ()
  let flag_lemma = new_flag ()
  let flag_persistent = new_flag ()

  let set_flag flag c truth =
    if truth
      then c.hcflags <- c.hcflags lor flag
      else c.hcflags <- c.hcflags land (lnot flag)

  let get_flag flag c = (c.hcflags land flag) != 0

  (** {2 Hashcons} *)

  let eq hc1 hc2 = hc1.hctag = hc2.hctag

  let compare hc1 hc2 = hc1.hctag - hc2.hctag

  let hash_fun c h = Lits.hash_fun c.hclits h
  let hash c = Hash.apply hash_fun c

  let id c = c.hctag

  let parents c = c.hcparents


  let is_ground c = get_flag flag_ground c

  let weight c = Lits.weight c.hclits

  let as_bool c = c.as_bool

  let as_bool_exn c = match c.as_bool with
    | None -> failwith "C.as_bool_exn"
    | Some i -> i

  let set_bool_name c i =
    (* check consistency *)
    begin match c.as_bool with
      | None -> ()
      | Some j -> if i<>j then failwith "C.set_bool_name"
    end;
    c.as_bool <- Some i

  module Trail = struct
    type t = ISet.t

    let equal = ISet.equal
    let compare = ISet.compare
    let hash_fun trail h = Hash.seq Hash.int_ (ISet.to_seq trail) h
    let hash = Hash.apply hash_fun

    type bool_lit = Ctx.BoolLit.bool_lit

    let singleton = ISet.singleton
    let of_list = ISet.of_list
    let to_list = ISet.to_list
    let is_empty = ISet.is_empty

    let subsumes t1 t2 = ISet.subset t1 t2

    let is_trivial trail =
      ISet.exists
        (fun i -> ISet.mem (-i) trail)
        trail

    let merge = function
      | [] -> ISet.empty
      | [t] -> t
      | [t1;t2] -> ISet.union t1 t2
      | t::l -> List.fold_left ISet.union t l

    type valuation = bool_lit -> bool
    (** A boolean valuation *)

    let is_active trail ~v =
      ISet.for_all
        (fun i ->
          let j = abs i in
          (i > 0) = (v j)  (* valuation match sign *)
        ) trail

    let pp buf trail =
      if not (ISet.is_empty trail)
        then Printf.bprintf buf " ← %a"
          (Sequence.pp_buf ~sep:" ⊓ " Ctx.BoolLit.pp) (ISet.to_seq trail)

    let print fmt trail =
      if not (ISet.is_empty trail)
      then Format.fprintf fmt " ← @[<hov>%a@]"
          (Sequence.pp_seq ~sep:" ⊓ " Ctx.BoolLit.print) (ISet.to_seq trail)
  end

  let get_trail c = c.trail
  let has_trail c = not (Trail.is_empty c.trail)
  let trail_subsumes c1 c2 = Trail.subsumes (get_trail c1) (get_trail c2)
  let is_active c ~v = Trail.is_active c.trail ~v

  let lits c = c.hclits

  module CHashtbl = Hashtbl.Make(struct
    type t = clause
    let hash c = hash c
    let equal c1 c2 = eq c1 c2
  end)

  module CHashSet = struct
    type t = unit CHashtbl.t
    let create () = CHashtbl.create 13
    let is_empty t = CHashtbl.length t = 0
    let member t c = CHashtbl.mem t c
    let iter t f = CHashtbl.iter (fun c _ -> f c) t
    let add t c = CHashtbl.replace t c ()
    let to_list t =
      let l = ref [] in
      iter t (fun c -> l := c :: !l);
      !l
  end

  (** {2 Utils} *)

  (** [is_child_of ~child c] is to be called to remember that [child] is a child
      of [c], is has been infered/simplified from [c] *)
  let is_child_of ~child c =
    (* update the parent clauses' sets of descendants by adding [child] *)
    let descendants = SmallSet.add c.hcdescendants child.hctag in
    c.hcdescendants <- descendants

  (* see if [c] is known to simplify into some other clause *)
  let rec _follow_simpl n c =
    if n > 10_000 then
      failwith (Util.sprintf "follow_simpl loops on %a" Lits.pp c.hclits);
    match c.hcsimplto with
    | None -> c
    | Some c' ->
      Util.debug 3 "clause %a already simplified to %a"
        Lits.pp c.hclits Lits.pp c'.hclits;
      _follow_simpl (n+1) c'

  let follow_simpl c = _follow_simpl 0 c

  (* [from] simplifies into [into] *)
  let simpl_to ~from ~into =
    let from = follow_simpl from in
    assert (from.hcsimplto = None);
    let into' = follow_simpl into in
    (* avoid cycles *)
    if from != into' then
      from.hcsimplto <- Some into

  let is_conjecture c = Proof.is_conjecture c.hcproof

  let distance_to_conjecture c =
    Proof.distance_to_conjecture c.hcproof

  (* hashconsing of clauses. Clauses are equal if they have the same literals
      and the same trail *)
  module CHashcons = Hashcons.Make(struct
    type t = clause
    let hash_fun c h =
      h |> Lits.hash_fun c.hclits |> Trail.hash_fun c.trail
    let hash c = Hash.apply hash_fun c
    let equal c1 c2 =
      Lits.eq_com c1.hclits c2.hclits && Trail.equal c1.trail c2.trail
    let tag i c = (assert (c.hctag = (-1)); c.hctag <- i)
  end)

  let __no_select = BV.empty ()

  let on_proof = Signal.create ()

  let compact_trail trail =
    ISet.fold
      (fun i acc ->
        let sign = i<0 in
        match Ctx.BoolLit.extract (abs i) with
        | None -> failwith "wrong trail"
        | Some (Ctx.BoolLit.Clause_component lits) -> (sign, `Box_clause lits) :: acc
        | Some (Ctx.BoolLit.Provable _ | Ctx.BoolLit.Name _) ->
            failwith "clause trail contains a non-Clause_component guard"
      ) trail []

  let compact c = CompactClause.make c.hclits (compact_trail c.trail)

  let create ?parents ?selected ?trail lits proof =
    Util.enter_prof prof_clause_create;
    let lits = lits
      |> List.filter (function Lit.False -> false | _ -> true)
      |> List.sort Lit.compare
    in
    let lits = Array.of_list lits in
    (* trail *)
    let trail = match trail, parents with
      | Some t, _ -> t
      | None, None -> ISet.empty
      | None, Some parent_list -> Trail.merge (List.map get_trail parent_list)
    in
    (* proof *)
    let cc = CompactClause.make lits (compact_trail trail) in
    let proof' = proof cc in
    Signal.send on_proof (lits, proof');
    (* create the structure *)
    let c = {
      hclits = lits;
      hcflags = 0;
      hctag = (-1);
      hcselected = __no_select;
      hcproof = proof';
      hcparents = [];
      hcdescendants = SmallSet.empty ~cmp:(fun i j -> i-j);
      hcsimplto = None;
      as_bool = None;
      trail;
    } in
    let old_hc, c = c, CHashcons.hashcons c in
    if c == old_hc then begin
      (* select literals, if not already done *)
      begin c.hcselected <- match selected with
        | Some bv -> bv
        | None -> Ctx.select lits
      end;
      (* compute flags *)
      if Lits.is_ground lits then set_flag flag_ground c true;
      (* parents *)
      begin match parents with
      | None -> ()
      | Some parents ->
        c.hcparents <- parents;
        List.iter (fun parent -> is_child_of ~child:c parent) parents
      end;
    end;
    (* return clause *)
    Util.incr_stat stat_clause_create;
    Util.exit_prof prof_clause_create;
    c

  let create_a ?parents ?selected ?trail lits proof =
    create ?parents ?selected ?trail (Array.to_list lits) proof

  let of_forms ?parents ?selected ?trail forms proof =
    let lits = List.map Ctx.Lit.of_form forms in
    create ?parents ?selected ?trail lits proof

  let of_forms_axiom ?(role="axiom") ~file ~name forms =
    let lits = List.map Lit.Conv.of_form forms in
    let proof c = Proof.mk_c_file ~role ~file ~name c in
    create lits proof

  let proof c = c.hcproof

  let is_empty c =
    Array.length c.hclits = 0 && Trail.is_empty c.trail

  let length c = Array.length c.hclits

  let stats () = CHashcons.stats ()

  (** descendants of the clause *)
  let descendants c = c.hcdescendants

  (** Apply substitution to the clause. Note that using the same renaming for all
      literals is important. *)
  let apply_subst ~renaming subst c scope =
    let lits = Array.map
      (fun lit -> Lit.apply_subst ~renaming subst lit scope)
      c.hclits in
    let descendants = c.hcdescendants in
    let proof = Proof.adapt_c c.hcproof in
    let new_hc = create_a ~parents:[c] lits proof in
    new_hc.hcdescendants <- descendants;
    new_hc

  let _apply_subst_no_simpl subst lits sc =
    if Substs.is_empty subst
    then lits  (* id *)
    else
      let renaming = S.Renaming.create () in
      Array.map
        (fun l -> Lit.apply_subst_no_simp ~renaming subst l sc)
        lits

  (** Bitvector that indicates which of the literals of [subst(clause)]
      are maximal under [ord] *)
  let maxlits c scope subst =
    let ord = Ctx.ord () in
    let lits' = _apply_subst_no_simpl subst c.hclits scope in
    Lits.maxlits ~ord lits'

  (** Check whether the literal is maximal *)
  let is_maxlit c scope subst ~idx =
    let ord = Ctx.ord () in
    let lits' = _apply_subst_no_simpl subst c.hclits scope in
    Lits.is_max ~ord lits' idx

  (** Bitvector that indicates which of the literals of [subst(clause)]
      are eligible for resolution. *)
  let eligible_res c scope subst =
    let ord = Ctx.ord () in
    let lits' = _apply_subst_no_simpl subst c.hclits scope in
    let selected = c.hcselected in
    if BV.is_empty selected
    then (
      (* maximal literals *)
      Lits.maxlits ~ord lits'
    ) else (
      let bv = BV.copy selected in
      let n = Array.length lits' in
      (* Only keep literals that are maximal among selected literals of the
          same sign. *)
      for i = 0 to n-1 do
        (* i-th lit is already known not to be max? *)
        if not (BV.get bv i) then () else
        let lit = lits'.(i) in
        for j = i+1 to n-1 do
          let lit' = lits'.(j) in
          (* check if both lits are still potentially eligible, and have the same
             sign if [check_sign] is true. *)
          if Lit.is_pos lit = Lit.is_pos lit' &&  BV.get bv j
          then match Lit.Comp.compare ~ord lit lit' with
            | Comparison.Incomparable
            | Comparison.Eq -> ()     (* no further information about i-th and j-th *)
            | Comparison.Gt -> BV.reset bv j  (* j-th cannot be max *)
            | Comparison.Lt -> BV.reset bv i  (* i-th cannot be max *)
        done;
      done;
      bv
    )

  (** Bitvector that indicates which of the literals of [subst(clause)]
      are eligible for paramodulation. *)
  let eligible_param c scope subst =
    let ord = Ctx.ord () in
    if BV.is_empty c.hcselected then begin
      let lits' = _apply_subst_no_simpl subst c.hclits scope in
      (* maximal ones *)
      let bv = Lits.maxlits ~ord lits' in
      (* only keep literals that are positive equations *)
      BV.filter bv (fun i -> Lit.is_eq lits'.(i));
      bv
    end else BV.empty ()  (* no eligible literal when some are selected *)

  let is_eligible_param c scope subst ~idx =
    Lit.is_pos c.hclits.(idx)
    &&
    BV.is_empty c.hcselected
    &&
    is_maxlit c scope subst ~idx

  let eligible_chaining c scope subst =
    let ord = Ctx.ord () in
    if BV.is_empty c.hcselected then begin
      let renaming = S.Renaming.create () in
      let lits = Lits.apply_subst ~renaming subst c.hclits scope in
      let bv = Lits.maxlits ~ord lits in
      (* only keep literals that are positive *)
      BV.filter bv (fun i -> Lit.is_pos lits.(i));
      (* only keep ordering lits *)
      BV.filter bv (fun i -> Lit.is_ineq lits.(i));
      bv
    end else BV.empty ()

  (** are there selected literals in the clause? *)
  let has_selected_lits c = not (BV.is_empty c.hcselected)

  (** Check whether the literal is selected *)
  let is_selected c i = BV.get c.hcselected i

  (** Indexed list of selected literals *)
  let selected_lits c = BV.selecti c.hcselected c.hclits

  (** is the clause a unit clause? *)
  let is_unit_clause c = match c.hclits with
    | [|_|] -> true
    | _ -> false

  let is_oriented_rule c =
    let ord = Ctx.ord () in
    match c.hclits with
    | [| Lit.Equation (l, r, true) |] ->
        begin match Ordering.compare ord l r with
        | Comparison.Gt
        | Comparison.Lt -> true
        | Comparison.Eq
        | Comparison.Incomparable -> false
        end
    | [| Lit.Prop (_, true) |] -> true
    | _ -> false

  let symbols ?(init=Symbol.Set.empty) seq =
    Sequence.fold
      (fun set c -> Lits.symbols ~init:set c.hclits)
      init seq

  module Seq = struct
    let lits c = Sequence.of_array c.hclits
    let terms c = lits c |> Sequence.flatMap Lit.Seq.terms
    let vars c = terms c |> Sequence.flatMap T.Seq.vars
    let abstract c =
      Lits.Seq.abstract c.hclits
  end

  (** {2 Filter literals} *)

  module Eligible = struct
    type t = int -> Lit.t -> bool

    let res c =
      let bv = eligible_res c 0 S.empty in
      fun i lit -> BV.get bv i

    let param c =
      let bv = eligible_param c 0 S.empty in
      fun i lit -> BV.get bv i

    let chaining c =
      let bv = eligible_chaining c 0 S.empty in
      fun i lit -> BV.get bv i

    let eq i lit = match lit with
      | Lit.Equation (_, _, true) -> true
      | _ -> false

    let ineq c = fun i lit -> Lit.is_ineq lit

    let ineq_of clause instance =
      fun i lit -> Lit.is_ineq_of ~instance lit

    let arith i lit = Lit.is_arith lit

    let filter f i lit = f lit

    let max c =
      let bv = lazy (Lits.maxlits ~ord:(Ctx.ord ()) c.hclits) in
      fun i lit ->
        BV.get (Lazy.force bv) i

    let pos i lit = Lit.is_pos lit

    let neg i lit = Lit.is_neg lit

    let always i lit = true

    let combine l = match l with
    | [] -> (fun i lit -> true)
    | [x] -> x
    | [x; y] -> (fun i lit -> x i lit && y i lit)
    | [x; y; z] -> (fun i lit -> x i lit && y i lit && z i lit)
    | _ -> (fun i lit -> List.for_all (fun eligible -> eligible i lit) l)

    let ( ** ) f1 f2 i lit = f1 i lit && f2 i lit
    let ( ++ ) f1 f2 i lit = f1 i lit || f2 i lit
    let ( ~~ ) f i lit = not (f i lit)
  end

  (** {2 Set of clauses} *)

  (** Simple set *)
  module ClauseSet = Set.Make(struct
    type t = clause
    let compare hc1 hc2 = hc1.hctag - hc2.hctag
  end)

  (** Set with access by ID, bookeeping of maximal var... *)
  module CSet = struct
    module IntMap = Map.Make(struct
      type t = int
      let compare i j = i - j
    end)

    type t = clause IntMap.t
      (** Set of hashconsed clauses. Clauses are indexable by their ID. *)

    let empty = IntMap.empty

    let is_empty = IntMap.is_empty

    let size set = IntMap.fold (fun _ _ b -> b + 1) set 0

    let add set c = IntMap.add c.hctag c set

    let add_list set hcs =
      List.fold_left add set hcs

    let remove_id set i = IntMap.remove i set

    let remove set c = remove_id set c.hctag

    let remove_list set hcs =
      List.fold_left remove set hcs

    let get set i = IntMap.find i set

    let mem set c = IntMap.mem c.hctag set

    let mem_id set i = IntMap.mem i set

    let choose set =
      try Some (snd (IntMap.choose set))
      with Not_found -> None

    let union s1 s2 = IntMap.merge
      (fun _ c1 c2 -> match c1, c2 with
        | Some c1, Some c2 -> assert (c1 == c2); Some c1
        | Some c, None
        | None, Some c -> Some c
        | None, None -> None)
      s1 s2

    let inter s1 s2 = IntMap.merge
      (fun _ c1 c2 -> match c1, c2 with
        | Some c1, Some c2 -> assert (c1 == c2); Some c1
        | Some _, None
        | None, Some _
        | None, None -> None)
      s1 s2

    let iter set k = IntMap.iter (fun _ c -> k c) set

    let iteri set k = IntMap.iter k set

    let fold set acc f =
      let acc = ref acc in
      iteri set (fun i c -> acc := f !acc i c);
      !acc

    let to_list set =
      IntMap.fold (fun _ c acc -> c :: acc) set []

    let of_list l =
      add_list empty l

    let to_seq set =
      Sequence.from_iter
        (fun k -> iter set k)

    let of_seq set seq = Sequence.fold add set seq

    let remove_seq set seq = Sequence.fold remove set seq

    let remove_id_seq set seq = Sequence.fold remove_id set seq
  end

  (** {2 Positions in clauses} *)

  module Pos = struct
    let at c pos = Lits.Pos.at c.hclits pos
  end

  module WithPos = struct
    type t = {
      clause : clause;
      pos : Position.t;
      term : T.t;
    }
    let compare t1 t2 =
      let c = t1.clause.hctag - t2.clause.hctag in
      if c <> 0 then c else
      let c = T.cmp t1.term t2.term in
      if c <> 0 then c else
      Position.compare t1.pos t2.pos

    let pp buf t =
      Printf.bprintf buf "clause %a at pos %a" Lits.pp t.clause.hclits Position.pp t.pos
  end


  (** {2 IO} *)

  let pp buf c =
    let pp_annot selected maxlits i =
      ""^(if BV.get selected i then "+" else "")
        ^(if BV.get maxlits i then "*" else "")
    in
    (* print literals with a '*' for maximal, and '+' for selected *)
    let selected = c.hcselected in
    let max = maxlits c 0 S.empty in
    Buffer.add_char buf '[';
    if Array.length c.hclits = 0 then Buffer.add_string buf "⊥";
    Util.pp_arrayi ~sep:" | "
      (fun buf i lit ->
        let annot = pp_annot selected max i in
        Lit.pp buf lit;
        Buffer.add_string buf annot)
      buf c.hclits;
    Buffer.add_char buf ']';
    Trail.pp buf c.trail;
    ()

  let pp_tstp buf c =
    match c.hclits with
    | [| |] -> Buffer.add_string buf "$false"
    | [| l |] -> Lit.pp_tstp buf l
    | _ -> Printf.bprintf buf "(%a)" Lits.pp_tstp c.hclits

  let pp_tstp_full buf c =
    Printf.bprintf buf "cnf(%d, plain, %a)." c.hctag pp_tstp c

  let to_string = Util.on_buffer pp

  let fmt fmt c =
    Format.pp_print_string fmt (to_string c)

  let pp_set buf set =
    Sequence.iter
      (fun c -> pp buf c; Buffer.add_char buf '\n')
      (CSet.to_seq set)

  let pp_set_tstp buf set =
    Sequence.iter
      (fun c -> pp_tstp buf c; Buffer.add_char buf '\n')
      (CSet.to_seq set)
end
