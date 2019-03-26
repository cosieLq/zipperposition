(* This file is free software, part of Zipperposition. See file "license" for more details. *)

module T = Term
module US = Unif_subst

type subst = US.t

module S : sig

  val apply : subst -> T.t Scoped.t -> T.t
  val pp : subst CCFormat.printer

end

(* Disable getting only the first solution for unifying arguments
   after performing identification *)
val disable_conservative_elim : unit -> unit
(* Apply imitation and projection rules for flex-flex pairs *)
val disable_cons_ff : unit -> unit
(* Apply imitation before projection *)
val enable_imit_first : unit -> unit
(* Solve pairs that have exactly one unifier directly using 
   an extension of pattern unification algorithm. *)
val enable_solve_var : unit -> unit

(* Unify terms of the same scope. Assumes that terms are in eta-long form. *)
val unify : depth:int ->
            nr_iter:int ->
            scope:Scoped.scope ->
            counter:int ref ->
            subst:US.t -> (T.t * T.t * bool) CCList.t -> US.t option OSeq.t

val unify_scoped : T.t Scoped.t -> T.t Scoped.t -> subst option OSeq.t