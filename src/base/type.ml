(*
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

(** {1 Types} *)

exception Error of string
  (** Generic error on types. *)

module T = ScopedTerm

type symbol = Symbol.t

type t = T.t

type ty = t

let kind = T.Kind.Type

type view =
  | Var of int              (** Type variable *)
  | BVar of int             (** Bound variable (De Bruijn index) *)
  | App of symbol * t list  (** parametrized type *)
  | Fun of t * t list       (** Function type *)
  | Record of (string*t) list * t option  (** Record type *)
  | Forall of t             (** explicit quantification using De Bruijn index *)

let view t = match T.kind t with
  | T.Kind.Type ->
    begin match T.view t with
    | T.Var i -> Var i
    | T.BVar i -> BVar i
    | T.Bind (Symbol.Conn Symbol.ForallTy, varty, t') ->
      assert (T.eq varty T.tType);
      Forall t'
    | T.Const s -> App (s, [])
    | T.SimpleApp ((Symbol.Conn Symbol.Arrow), ret::l) ->
        Fun (ret, l)
    | T.SimpleApp (s, l) -> App (s, l)
    | T.Record (l, rest) -> Record (l, rest)
    | _ -> failwith "Type.view"
    end
  | _ -> raise (Invalid_argument "Type.view")

let hash = T.hash
let eq = T.eq
let cmp = T.cmp

let is_var ty = match view ty with | Var _ -> true | _ -> false
let is_bvar ty = match view ty with | BVar _ -> true | _ -> false
let is_app ty = match view ty with App _ -> true | _ -> false
let is_fun ty = match view ty with | Fun _ -> true | _ -> false
let is_forall ty = match view ty with | Forall _ -> true | _ -> false

let tType = T.tType

let var i =
  if i < 0 then raise (Invalid_argument "Type.var");
  T.var ~kind ~ty:tType i

let app s l = T.simple_app ~kind ~ty:tType s l

let const s = T.const ~kind ~ty:tType s

let rec mk_fun ret args =
  match args with
  | [] -> ret
  | _::_ ->
    match T.view ret with
    | T.SimpleApp (Symbol.Conn Symbol.Arrow, ret'::args') ->
      (* invariant: flatten function types. Symmetric w.r.t the {!HOTerm.At}
          constructor invariant. [args] must be applied before [args']
          need to be supplied.
          Example: [(a <- b) <- c] requires [c] first *)
      mk_fun ret' (args @ args')
    | _ ->
      T.simple_app ~kind ~ty:tType Symbol.Base.arrow (ret :: args)

let forall vars ty =
  T.bind_vars ~kind ~ty:tType Symbol.Base.forall_ty vars ty

let rec record l ~rest =
  match rest with
  | Some r ->
    begin match T.view r with
    | T.Record (l', rest') ->
        (* flatten records! *)
        T.record ~kind ~ty:tType (l @ l') ~rest:rest'
    | _ -> T.record ~kind ~ty:tType l ~rest
    end
  | None -> T.record ~kind ~ty:tType l ~rest

let __bvar i =
  T.bvar ~kind ~ty:tType i

let __forall ty =
  T.bind ~kind ~ty:tType ~varty:tType Symbol.Base.forall_ty ty

let multiset ty = app Symbol.Base.multiset [ty]

let (<==) = mk_fun
let (<=.) ret a = mk_fun ret [a]
let (@@) = app

(* downcast *)
let of_term ty = match T.kind ty with
  | T.Kind.Type -> Some ty
  | _ -> None

let of_term_exn ty = match T.kind ty with
  | T.Kind.Type -> ty
  | _ -> raise (Invalid_argument "Type.of_term_exn")

let is_type t = match T.kind t with
  | T.Kind.Type -> true
  | _ -> false

let () =
  assert(not(is_type tType));
  ()

(** {2 Containers} *)

module Set = Sequence.Set.Make(struct
  type t = ty
  let compare = cmp
end)
module Map = Sequence.Map.Make(struct
  type t = ty
  let compare = cmp
end)
module Tbl = Hashtbl.Make(struct
  type t = ty
  let hash = hash
  let equal = eq
end)

module Seq = struct
  let vars ty = Sequence.fmap of_term (T.Seq.vars ty)
  let sub ty = Sequence.fmap of_term (T.Seq.subterms ty)
  let add_set set t = Sequence.fold (fun set x -> Set.add x set) set t
end

let vars_set set t =
  Seq.add_set set (Seq.vars t)

let vars t = Set.elements (vars_set Set.empty t)

let close_forall ty = forall (vars ty) ty

let rec arity ty = match view ty with
  | Fun (_, l) -> 0, List.length l
  | Var _
  | BVar _
  | Record _
  | App _ -> 0, 0
  | Forall ty' ->
    let i1, i2 = arity ty' in
    i1 + 1, i2

let rec expected_args ty = match view ty with
  | Fun (_, l) -> l
  | BVar _
  | Var _
  | Record _
  | App _ -> []
  | Forall ty' -> expected_args ty'

let is_ground = T.ground

let size = T.size

let _error msg = raise (Error msg)

let apply ty arg =
  match T.view ty with
  | T.SimpleApp(Symbol.Conn Symbol.Arrow, ret::x::args') ->
    if eq x arg
    then mk_fun ret args'
    else 
      let msg = Util.sprintf
        "Type.apply: wrong argument type, expected %a but got %a" T.pp x T.pp arg
      in _error msg
  | T.Bind (Symbol.Conn Symbol.ForallTy, _, ty') ->
      T.DB.eval (DBEnv.singleton arg) ty'
  | _ ->
      let msg = Util.sprintf
        "Type.apply: expected quantified or function type, but got %a" T.pp ty
      in _error msg

(* apply a type to arguments. *)
let rec apply_list ty args = match args with
  | [] -> ty
  | arg::args' ->
      let ty' = apply ty arg in
      apply_list ty' args'

(*
let bij = T.bij
*)

let __var =
  let r = ref ~-1 in
  fun () ->
    let n = !r in
    decr r;
    T.var ~ty:tType n

type print_hook = int -> (Buffer.t -> t-> unit) -> Buffer.t -> t-> bool

module TPTP = struct
  let arrow = Symbol.of_string ">"
  let forall_ty = Symbol.of_string "!>"
  let tType = T.tType

  let i = const Symbol.TPTP.i
  let o = const Symbol.TPTP.o
  let int = const Symbol.TPTP.int
  let rat = const Symbol.TPTP.rat
  let real = const Symbol.TPTP.real

  let rec pp_tstp_rec depth buf t = match view t with
    | Var i -> Printf.bprintf buf "T%d" i
    | BVar i -> Printf.bprintf buf "Tb%d" (depth-i-1)
    | App (p, []) -> Symbol.pp buf p
    | App (p, args) -> Printf.bprintf buf "%a(%a)" Symbol.pp p
      (Util.pp_list (pp_tstp_rec depth)) args
    | Fun (ret, []) -> assert false
    | Fun (ret, [arg]) ->
      Printf.bprintf buf "%a > %a" (pp_inner depth) arg (pp_inner depth) ret
    | Fun (ret, l) ->
      Printf.bprintf buf "(%a) > %a"
        (Util.pp_list ~sep:" * " (pp_inner depth)) l (pp_tstp_rec depth) ret
    | Record _ -> failwith "cannot print record types in TPTP"
    | Forall ty' ->
      Printf.bprintf buf "!>[Tb%d:$tType]: %a" depth (pp_inner (depth+1)) ty'
  and pp_inner depth buf t = match view t with
    | Fun (_, _::_) ->
      Buffer.add_char buf '('; pp_tstp_rec depth buf t; Buffer.add_char buf ')'
    | _ -> pp_tstp_rec depth buf t

  let pp buf t = pp_tstp_rec 0 buf t

  let pp_depth ?hooks depth buf t = pp_tstp_rec depth buf t

  let to_string t =
    let b = Buffer.create 15 in
    pp b t;
    Buffer.contents b

  let fmt fmt t = Format.pp_print_string fmt (to_string t)
end

(** {2 IO} *)

let rec pp_rec depth buf t = match view t with
  | Var i -> Printf.bprintf buf "A%d" i
  | BVar i -> Printf.bprintf buf "T%i" (depth-i-1)
  | App (p, []) -> Buffer.add_string buf (Symbol.to_string p)
  | App (p, args) ->
    Printf.bprintf buf "%s(%a)"
      (Symbol.to_string p) (Util.pp_list (pp_rec depth)) args
  | Fun (ret, []) -> assert false
  | Fun (ret, [arg]) ->
    Printf.bprintf buf "%a → %a" (pp_inner depth) arg (pp_inner depth) ret
  | Fun (ret, l) ->
    Printf.bprintf buf "(%a) → %a"
      (Util.pp_list ~sep:" * " (pp_inner depth)) l (pp_rec depth) ret
  | Record (l, None) ->
    Buffer.add_char buf '{';
    List.iteri
      (fun i (s, t') ->
        if i>0 then Buffer.add_string buf ", ";
        Printf.bprintf buf "%s: " s;
        pp_rec depth buf t')
      l;
    Buffer.add_char buf '}'
  | Record (l, Some r) ->
    Buffer.add_char buf '{';
    List.iteri
      (fun i (s, t') ->
        if i>0 then Buffer.add_string buf ", ";
        Printf.bprintf buf "%s: " s;
        pp_rec depth buf t')
      l;
  | Forall ty' ->
    Printf.bprintf buf "Λ T%i. %a" depth (pp_inner (depth+1)) ty'
and pp_inner depth buf t = match view t with
  | Fun (_, _::_) ->
    Buffer.add_char buf '('; pp_rec depth buf t; Buffer.add_char buf ')'
  | _ -> pp_rec depth buf t

let pp_depth ?hooks depth buf t = pp_rec depth buf t

let pp buf t = pp_rec 0 buf t

(* let pp buf ty = T.pp buf ty *)
let to_string = Util.on_buffer pp
let fmt fmt ty = Format.pp_print_string fmt (to_string ty)

(*
let bij =
  let (!!) = Lazy.force in
  Bij.(fix (fun bij' ->
    let bij_app = lazy (pair string_ (list_ (!! bij'))) in
    let bij_fun = lazy (pair (!! bij') (list_ (!! bij'))) in
    let bij_forall = bij' in
    switch
      ~inject:(fun ty -> match ty.ty with
        | Var i -> "v", BranchTo (int_, i)
        | BVar i -> "bv", BranchTo (int_, i)
        | App (p, l) -> "at", BranchTo (!! bij_app, (p, l))
        | Fun (ret, l) -> "fun", BranchTo (!! bij_fun, (ret, l))
        | Forall ty -> "all", BranchTo(!! bij_forall, ty))
      ~extract:(function
        | "v" -> BranchFrom (int_, var)
        | "bv" -> BranchFrom (int_, bvar)
        | "at" -> BranchFrom (!! bij_app, fun (s,l) -> app s l)
        | "fun" -> BranchFrom (!! bij_fun, fun (ret,l) -> mk_fun ret l)
        | "all" -> BranchFrom (!! bij_forall, fun ty -> __forall ty)
        | _ -> raise (DecodingError "expected Type"))))
*)

(** {2 Conversions} *)

module Conv = struct
  module PT = PrologTerm

  exception LocalExit

  let of_prolog ~ctx t =
    let rec of_prolog t = match t.PT.term with
      | PT.Column ({PT.term=PT.Var name}, {PT.term=PT.Const (Symbol.Conn Symbol.TType)})
      | PT.Var name ->
        assert (name <> "");
        begin try var (Hashtbl.find ctx name)
        with Not_found ->
          let n = Hashtbl.length ctx in
          Hashtbl.add ctx name n;
          var n
        end
      | PT.Const (Symbol.Conn Symbol.Wildcard) ->
        (* fresh var that will never occur again *)
        let n = Hashtbl.length ctx in
        Hashtbl.add ctx "" n;  (* increases length, but not reachable *)
        var n
      | PT.Int _
      | PT.Rat _ -> raise LocalExit
      | PT.Const s -> const s
      | PT.App ({PT.term=PT.Const (Symbol.Conn Symbol.Arrow)}, ret::l) ->
        let ret = of_prolog ret in
        let l = List.map of_prolog l in
        mk_fun ret l
      | PT.App ({PT.term=PT.Const hd}, l) ->
        let l = List.map of_prolog l in
        app hd l
      | PT.Bind (Symbol.Conn Symbol.ForallTy, vars, t') ->
        let vars = List.map of_prolog vars in
        let t' = of_prolog t' in
        forall vars t'
      | PT.Record (l, rest) ->
        let rest = Monad.Opt.map rest of_prolog in
        let l = List.map (fun (n,t) -> n, of_prolog t) l in
        record l ~rest
      | PT.Bind _
      | PT.App _
      | PT.Column _
      | PT.List _ -> raise LocalExit
    in
    try Some (of_prolog t)
    with LocalExit -> None

  let to_prolog ?(depth=0) t =
    let rec to_prolog depth t = match view t with
    | Var i -> PT.var (Util.sprintf "A%d" i)
    | BVar i -> PT.var (Util.sprintf "B%d" (depth-i-1))
    | App (s,l) -> PT.app (PT.const s) (List.map (to_prolog depth) l)
    | Fun (ret, l) ->
      PT.app (PT.const Symbol.Base.arrow)
        (to_prolog depth ret :: List.map (to_prolog depth) l)
    | Record (l, rest) ->
      let rest = Monad.Opt.map rest (to_prolog depth) in
      PT.record (List.map (fun (n,ty) -> n, to_prolog depth ty) l) ~rest
    | Forall t' ->
      PT.bind Symbol.Base.forall_ty
        [PT.var (Util.sprintf "B%d" depth)]
        (to_prolog depth t')
    in
    to_prolog depth t
end

(** {2 Misc} *)

let __var i =
  T.var ~kind ~ty:tType i
