(*
    ||M||  This file is part of HELM, an Hypertextual, Electronic
    ||A||  Library of Mathematics, developed at the Computer Science
    ||T||  Department, University of Bologna, Italy.
    ||I||
    ||T||  HELM is free software; you can redistribute it and/or
    ||A||  modify it under the terms of the GNU General Public License
    \   /  version 2 or (at your option) any later version.
     \ /   This software is distributed as is, NO WARRANTY.
      V_______________________________________________________________ *)

open Types
open Hashcons

module T = Terms
module C = Clauses

(* Main pretty printing functions *)

(* print a list of items using the printing function *)
let rec pp_list ?(sep=", ") pp_item  formatter = function
  | x::y::xs -> Format.fprintf formatter "%a%s@,%a"
      pp_item x sep (pp_list ~sep:sep pp_item) (y::xs)
  | x::[] -> pp_item formatter x
  | [] -> ()

(* print a term *)
let rec pp_foterm formatter t = match t.node.term with
  | Leaf x -> Signature.pp_symbol formatter x
  | Var i -> Format.fprintf formatter "X%d" i
  | Node (head::args) -> Format.fprintf formatter
      "@[<h>%a(%a)@]" pp_foterm head (pp_list ~sep:", " pp_foterm) args
  | Node [] -> failwith "bad term"

let string_of_direction = function
    | Left2Right -> "Left to right"
    | Right2Left -> "Right to left"
    | Nodir -> "No direction"

let string_of_pos s = match s with
  | _ when s == C.left_pos -> "left"
  | _ when s == C.right_pos -> "right"
  | _ -> assert false

(* print substitution *)
let pp_substitution formatter subst =
  Format.fprintf formatter "@[<h>";
  List.iter
    (fun (v, t) ->
       Format.fprintf formatter "?%a ->@, %a@;" pp_foterm v pp_foterm t)
    subst;
  Format.fprintf formatter "@]"

(* print proof
let pp_proof bag ~formatter:f p =
  let rec aux eq = function
    | Terms.Exact t ->
        Format.fprintf f "%d: Exact (" eq;
        pp_foterm f t;
        Format.fprintf f ")@;";
    | Terms.Step (rule,eq1,eq2,dir,pos,subst) ->
        Format.fprintf f "%d: %s("
          eq (string_of_rule rule);
      Format.fprintf f "|%d with %d dir %s))" eq1 eq2
        (string_of_direction dir);
      let (_, _, _, proof1),_,_ = Terms.get_from_bag eq1 bag in
      let (_, _, _, proof2),_,_ = Terms.get_from_bag eq2 bag in
        Format.fprintf f "@[<v 2>";
          aux eq1 proof1;
          aux eq2 proof2;
        Format.fprintf f "@]";
  in
    Format.fprintf f "@[<v>";
    aux 0 p;
    Format.fprintf f "@]"
;;
*)

let string_of_comparison = function
  | Lt -> "=<="
  | Gt -> "=>="
  | Eq -> "==="
  | Incomparable -> "=?="
  | Invertible -> "=<->="

let pp_literal formatter = function
  | Equation (left, right, false, _) when right = T.true_symbol ->
    Format.fprintf formatter "~%a" pp_foterm left
  | Equation (left, right, true, _) when right = T.true_symbol ->
    pp_foterm formatter left
  | Equation (left, right, true, _) when left = T.true_symbol ->
    pp_foterm formatter right
  | Equation (left, right, false, _) when left = T.true_symbol ->
    Format.fprintf formatter "~%a" pp_foterm right
  | Equation (left, right, sign, ord) ->
    if sign
    then Format.fprintf formatter "@[%a@ %a@ %a@]"
        pp_foterm left pp_foterm T.eq_symbol pp_foterm right
    else Format.fprintf formatter "@[<hv 2>%a !%a@ %a@]"
        pp_foterm left pp_foterm T.eq_symbol pp_foterm right

let pp_clause formatter {clits=lits} =
  Format.fprintf formatter "@[<hv 2>%a@]" (pp_list ~sep:" | " pp_literal) lits

let pp_clause_pos formatter (c, pos) =
  Format.fprintf formatter "[%a at @[<h>%a@]]@;"
  pp_clause c (pp_list ~sep:"." Format.pp_print_int) pos

let pp_bag formatter bag =
  Format.fprintf formatter "@[<v>((*) mean active, (_) discarded)@;";
  C.M.iter
    (fun _ hc -> Format.fprintf formatter "%a@;" pp_clause hc.node)
    bag.C.bag_clauses;
  Format.fprintf formatter "@]"

(* String buffer implementation *)
let on_buffer ?(margin=80) f t =
  let buff = Buffer.create 100 in
  let formatter = Format.formatter_of_buffer buff in
  Format.pp_set_margin formatter margin;
  f formatter t;
  Format.fprintf formatter "@?";
  Buffer.contents buff

