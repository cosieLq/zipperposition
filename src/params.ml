(*
Zipperposition: a functional superposition prover for prototyping
Copyright (C) 2012 Simon Cruanes

This is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.
*)

(** Parameters for the prover, the calculus, etc. *)

open Logtk

type t = {
  param_ord : Precedence.t -> Ordering.t;
  param_seed : int;
  param_steps : int;
  param_version : bool;
  param_calculus : string;
  param_timeout : float;
  param_files : string list;
  param_split : bool;             (** use splitting *)
  param_theories : bool;          (** detect theories *)
  param_precedence : bool;        (** use heuristic for precedence? *)
  param_select : string;          (** name of the selection function *)
  param_progress : bool;          (** print progress during search *)
  param_proof : string;           (** how to print proof? *)
  param_dot_file : string option; (** file to print the final state in *)
  param_plugins : string list;    (** plugins to load *)
  param_kb : string;              (** file to use for KB *)
  param_kb_where : bool;          (** print where is the KB? *)
  param_kb_load : string list;    (** theory files to read *)
  param_kb_clear : bool;          (** do we need to clear the KB? *)
  param_kb_print : bool;          (** print knowledge base and exit *)
  param_learn : bool;             (** try to learn from successful proofs? *)
  param_presaturate : bool;       (** initial interreduction of proof state? *)
  param_unary_depth : int;        (** Maximum successive levels of unary inferences *)
}

(** parse_args returns parameters *)
let parse_args () =
  let help_select = Util.sprintf "selection function (%a)"
    (Util.pp_list ~sep:"," Buffer.add_string)
    (Selection.available_selections ())
  in
  (* parameters *)
  let ord = ref "rpo6"
  and debug = ref 1
  and seed = ref 1928575
  and steps = ref 0
  and version = ref false
  and timeout = ref 0.
  and proof = ref "debug"
  and split = ref false
  and theories = ref true
  and calculus = ref "superposition"
  and presaturate = ref false
  and heuristic_precedence = ref true
  and dot_file = ref None
  and plugins = ref []
  and kb = ref (Filename.concat Const.home "kb")
  and kb_load = ref []
  and kb_clear = ref false
  and kb_print = ref false
  and kb_where = ref false
  and learn = ref false
  and select = ref "SelectComplex"
  and progress = ref false
  and unary_depth = ref 1
  and files = ref [] in
  (* special handlers *)
  let set_progress () =
    Util.need_cleanup := true;
    progress := true
  and add_plugin s = plugins := s :: !plugins
  and add_plugins s = plugins := (Util.str_split ~by:"," s) @ !plugins
  in
  (* options list *) 
  let options =
    [ ("-ord", Arg.Set_string ord, "choose ordering (rpo,kbo)");
      ("-debug", Arg.Set_int debug, "debug level");
      ("-version", Arg.Set version, "print version");
      ("-steps", Arg.Set_int steps, "maximal number of steps of given clause loop");
      ("-calculus", Arg.Set_string calculus, "set calculus ('superposition' or 'delayed' (default))");
      ("-timeout", Arg.Set_float timeout, "timeout (in seconds)");
      ("-select", Arg.Set_string select, help_select);
      ("-split", Arg.Set split, "enable splitting");
      ("-plugin", Arg.String add_plugin, "load given plugin (.cmxs)");
      ("-plugins", Arg.String add_plugins, "load given plugin(s), comma-separated");
      ("-kb", Arg.Set_string kb, "Knowledge Base (KB) file");
      ("-kb-load", Arg.String (fun f -> kb_load := f :: !kb_load), "load theory file into KB");
      ("-kb-clear", Arg.Set kb_clear, "clear content of KB and exit");
      ("-kb-print", Arg.Set kb_print, "print content of KB and exit");
      ("-kb-where", Arg.Set kb_where, "print default dir that is search for KB");
      ("-learning", Arg.Set learn, "enable lemma learning");
      (* ("-learning-limit", Arg.Set_int LemmaLearning.max_lemmas, "maximum number of lemma learnt at once"); *)
      ("-progress", Arg.Unit set_progress, "print progress");
      ("-profile", Arg.Set Util.enable_profiling, "enable profiling of code");
      ("-no-theories", Arg.Clear theories, "do not detect theories in input");
      ("-no-heuristic-precedence", Arg.Clear heuristic_precedence, "do not use heuristic to choose precedence");
      ("-proof", Arg.Set_string proof, "choose proof printing (none, debug, or tstp)");
      ("-presaturate", Arg.Set presaturate, "pre-saturate (interreduction of) the initial clause set");
      ("-dot", Arg.String (fun s -> dot_file := Some s) , "print final state to file in DOT");
      ("-seed", Arg.Set_int seed, "set random seed");
      ("-unary-depth", Arg.Set_int unary_depth, "maximum depth for successive unary inferences");
    ]
  in
  Arg.parse options (fun f -> files := f :: !files) "solve problems in files";
  (if !files = [] then files := ["stdin"]);
  let param_ord = Ordering.choose !ord in
  (* debug level *)
  Util.set_debug !debug;
  Util.debug 1 "set debug level to %d" !debug;
  (* return parameter structure *)
  { param_ord; param_seed = !seed; param_steps = !steps;
    param_version= !version; param_calculus= !calculus; param_timeout = !timeout;
    param_files = !files; param_select = !select; param_theories = !theories;
    param_progress = !progress;
    param_proof = !proof; param_split = !split;
    param_presaturate = !presaturate;
    param_dot_file = !dot_file; param_plugins= !plugins;
    param_kb = !kb; param_kb_load = !kb_load; param_kb_where = !kb_where;
    param_kb_clear = !kb_clear; param_unary_depth= !unary_depth;
    param_kb_print = !kb_print; param_learn = !learn;
    param_precedence= !heuristic_precedence;}
