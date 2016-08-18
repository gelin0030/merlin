(* {{{ COPYING *(

  This file is part of Merlin, an helper for ocaml editors

  Copyright (C) 2013 - 2015  Frédéric Bour  <frederic.bour(_)lakaban.net>
                             Thomas Refis  <refis.thomas(_)gmail.com>
                             Simon Castellan  <simon.castellan(_)iuwt.fr>

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
  sell copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall
  the authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising
  from, out of or in connection with the software or the use or other dealings
  in the Software.

)* }}} *)

open Std
open Sturgeon_stub
open Misc
open Protocol
module Printtyp = Type_utils.Printtyp

type buffer = {
  mutable config : Mconfig.t;
  mutable source : Msource.t;
}

type state = {
  mutable buffer : buffer;
}

let normalize_document doc =
  doc.Context.path, doc.Context.dot_merlins

let new_buffer (path, dot_merlins) =
  let open Mconfig in
  let query = match path with
    | None -> initial.query
    | Some path -> {
        initial.query with
        filename = Filename.basename path;
        directory = Misc.canonicalize_filename (Filename.dirname path);
      }
  and merlin = {
    initial.merlin with dotmerlin_to_load =
      (Option.cons (Option.map ~f:Filename.dirname path) (Option.value ~default:[] dot_merlins))
  }
  in
  { config = {initial with query; merlin};
    source = Msource.make ~filename:"<buffer>" ~text:""
  }

let new_state document =
  { buffer = new_buffer document }

let checkout_buffer_cache = ref []
let checkout_buffer =
  let cache_size = 8 in
  fun document ->
    let document = normalize_document document in
    try List.assoc document !checkout_buffer_cache
    with Not_found ->
      let buffer = new_buffer document in
      begin match document with
        | Some path, _ ->
          checkout_buffer_cache :=
            (document, buffer) :: List.take_n cache_size !checkout_buffer_cache
        | None, _ -> ()
      end;
      buffer

let print_completion_entries config entries =
  let input_ref = ref [] and output_ref = ref [] in
  let preprocess entry =
    match Completion.raw_info_printer entry with
    | `String s -> `String s
    | `Print t ->
      let r = ref "" in
      input_ref := t :: !input_ref;
      output_ref := r :: !output_ref;
      `Print r
    | `Concat (s,t) ->
      let r = ref "" in
      input_ref := t :: !input_ref;
      output_ref := r :: !output_ref;
      `Concat (s,r)
  in
  let entries = List.map ~f:(Completion.map_entry preprocess) entries in
  let outcomes =
    Mreader.print_batch_outcome config !input_ref
  in
  List.iter2 (:=) !output_ref outcomes;
  let postprocess = function
    | `String s -> s
    | `Print r -> !r
    | `Concat (s,r) -> s ^ !r
  in
  List.rev_map ~f:(Completion.map_entry postprocess) entries

let make_pipeline buffer =
      Mpipeline.make (Trace.start ()) buffer.config buffer.source

let with_typer ?for_completion buffer f =
  let pipeline = match for_completion with
    | None -> Mpipeline.make (Trace.start ()) buffer.config buffer.source
    | Some pos -> Mpipeline.make_for_completion
                    (Trace.start ()) buffer.config buffer.source pos
  in
  let typer = Mpipeline.typer_result pipeline in
  Mtyper.with_typer typer @@ fun () -> f pipeline typer

let dispatch_query ~verbosity buffer (type a) : a query_command -> a = function
  | Type_expr (source, pos) ->
    with_typer buffer @@ fun pipeline typer ->
    let pos = Msource.get_lexing_pos (Mpipeline.input_source pipeline) pos in
    let env, _ = Mbrowse.leaf_node (Mtyper.node_at typer pos) in
    let ppf, to_string = Format.to_string () in
    ignore (Type_utils.type_in_env ~verbosity env ppf source : bool);
    to_string ()

  | Type_enclosing (expro, pos) ->
    let open Typedtree in
    let open Override in
    with_typer buffer @@ fun pipeline typer ->
    let structures = Mbrowse.of_typedtree (Mtyper.get_typedtree typer) in
    let pos = Msource.get_lexing_pos buffer.source pos in
    let env, path = match Mbrowse.enclosing pos [structures] with
      | None -> Mtyper.get_env typer, []
      | Some browse ->
         fst (Mbrowse.leaf_node browse),
         Browse_misc.annotate_tail_calls_from_leaf browse
    in
    let aux (node,tail) =
      let open Browse_raw in
      match node with
      | Expression {exp_type = t}
      | Pattern {pat_type = t}
      | Core_type {ctyp_type = t}
      | Value_description { val_desc = { ctyp_type = t } } ->
        let ppf, to_string = Format.to_string () in
        Printtyp.wrap_printing_env env ~verbosity
          (fun () -> Type_utils.print_type_with_decl ~verbosity env ppf t);
        Some (Mbrowse.node_loc node, to_string (), tail)

      | Type_declaration { typ_id = id; typ_type = t} ->
        let ppf, to_string = Format.to_string () in
        Printtyp.wrap_printing_env env ~verbosity
          (fun () -> Printtyp.type_declaration env id ppf t);
        Some (Mbrowse.node_loc node, to_string (), tail)

      | Module_expr {mod_type = m}
      | Module_type {mty_type = m}
      | Module_binding {mb_expr = {mod_type = m}}
      | Module_declaration {md_type = {mty_type = m}}
      | Module_type_declaration {mtd_type = Some {mty_type = m}}
      | Module_binding_name {mb_expr = {mod_type = m}}
      | Module_declaration_name {md_type = {mty_type = m}}
      | Module_type_declaration_name {mtd_type = Some {mty_type = m}} ->
        let ppf, to_string = Format.to_string () in
        Printtyp.wrap_printing_env env ~verbosity
          (fun () -> Printtyp.modtype env ppf m);
        Some (Mbrowse.node_loc node, to_string (), tail)

      | _ -> None
    in
    let result = List.filter_map ~f:aux path in
    (* enclosings of cursor in given expression *)
    let exprs =
      match expro with
      | None ->
        let path = Mreader_lexer.reconstruct_identifier buffer.source pos in
        let path = Mreader_lexer.identifier_suffix path in
        let reify dot =
          if dot = "" ||
             (dot.[0] >= 'a' && dot.[0] <= 'z') ||
             (dot.[0] >= 'A' && dot.[0] <= 'Z')
          then dot
          else "(" ^ dot ^ ")"
        in
        begin match path with
          | [] -> []
          | base :: tail ->
            let f {Location. txt=base; loc=bl} {Location. txt=dot; loc=dl} =
              let loc = Location_aux.union bl dl in
              let txt = base ^ "." ^ reify dot in
              Location.mkloc txt loc
            in
            [ List.fold_left tail ~init:base ~f ]
        end
      | Some (expr, offset) ->
        let loc_start =
          let l, c = Lexing.split_pos pos in
          Lexing.make_pos (l, c - offset)
        in
        let shift loc int =
          let l, c = Lexing.split_pos loc in
          Lexing.make_pos (l, c + int)
        in
        let add_loc source =
          let loc =
            { Location.
              loc_start ;
              loc_end = shift loc_start (String.length source) ;
              loc_ghost = false ;
            } in
          Location.mkloc source loc
        in
        let len = String.length expr in
        let rec aux acc i =
          if i >= len then
            List.rev_map ~f:add_loc (expr :: acc)
          else if expr.[i] = '.' then
            aux (String.sub expr ~pos:0 ~len:i :: acc) (succ i)
          else
            aux acc (succ i) in
        aux [] offset
    in
    let small_enclosings =
      let env, node = Mbrowse.leaf_node (Mtyper.node_at typer pos) in
      let open Browse_raw in
      let include_lident = match node with
        | Pattern _ -> false
        | _ -> true
      in
      let include_uident = match node with
        | Module_binding _
        | Module_binding_name _
        | Module_declaration _
        | Module_declaration_name _
        | Module_type_declaration _
        | Module_type_declaration_name _
          -> false
        | _ -> true
      in
      List.filter_map exprs ~f:(fun {Location. txt = source; loc} ->
          match source with
          | "" -> None
          | source when not include_lident && Char.is_lowercase source.[0] ->
            None
          | source when not include_uident && Char.is_uppercase source.[0] ->
            None
          | source ->
            try
              let ppf, to_string = Format.to_string () in
              if Type_utils.type_in_env ~verbosity env ppf source then
                Some (loc, to_string (), `No)
              else
                None
            with _ ->
              None
        )
    in
    let normalize ({Location. loc_start; loc_end}, text, _tail) =
        Lexing.split_pos loc_start, Lexing.split_pos loc_end, text in
    List.merge_cons
      ~f:(fun a b ->
          (* Tail position is computed only on result, and result comes last
             As an approximation, when two items are similar, we returns the
             rightmost one *)
          if normalize a = normalize b then Some b else None)
      (small_enclosings @ result)

  | Enclosing pos ->
    with_typer buffer @@ fun pipeline typer ->
    let structures = Mbrowse.of_typedtree (Mtyper.get_typedtree typer) in
    let pos = Msource.get_lexing_pos buffer.source pos in
    let path = match Mbrowse.enclosing pos [structures] with
      | None -> []
      | Some path -> List.map ~f:snd (List.Non_empty.to_list path)
    in
    List.map ~f:Mbrowse.node_loc path

  | Complete_prefix (prefix, pos, with_doc) ->
    with_typer buffer ~for_completion:pos @@ fun pipeline typer ->
    let config = Mpipeline.final_config pipeline in
    let no_labels = Mpipeline.reader_no_labels_for_completion pipeline in
    let pos = Msource.get_lexing_pos buffer.source pos in
    let path = Mtyper.node_at ~skip_recovered:true typer pos in
    let env, node = Mbrowse.leaf_node path in
    let target_type, context =
      Completion.application_context ~verbosity ~prefix path in
    let get_doc =
      if not with_doc then None else
        let local_defs = Mtyper.get_typedtree typer in
        Some (
          Track_definition.get_doc ~config:buffer.config ~env ~local_defs
            ~comments:(Mpipeline.reader_comments pipeline) ~pos
        )
    in
    let entries =
      Printtyp.wrap_printing_env env ~verbosity @@ fun () ->
      print_completion_entries config @@
      Completion.node_complete config ?get_doc ?target_type env node prefix
    and context = match context with
      | `Application context when no_labels ->
        `Application {context with Protocol.Compl.labels = []}
      | context -> context
    in
    {Compl. entries; context }

  | Expand_prefix (prefix, pos) ->
    with_typer buffer @@ fun pipeline typer ->
    let pos = Msource.get_lexing_pos (Mpipeline.input_source pipeline) pos in
    let env, _ = Mbrowse.leaf_node (Mtyper.node_at typer pos) in
    let config = Mpipeline.final_config pipeline in
    let global_modules = Mconfig.global_modules config in
    let entries = print_completion_entries config @@
      Completion.expand_prefix env ~global_modules prefix
    in
    { Compl. entries ; context = `Unknown }

  | Document (patho, pos) ->
    with_typer buffer @@ fun pipeline typer ->
    let local_defs = Mtyper.get_typedtree typer in
    let pos = Msource.get_lexing_pos (Mpipeline.input_source pipeline) pos in
    let comments = Mpipeline.reader_comments pipeline in
    let env, _ = Mbrowse.leaf_node (Mtyper.node_at typer pos) in
    let path =
      match patho with
      | Some p -> p
      | None ->
        let path = Mreader_lexer.reconstruct_identifier
            (Mpipeline.input_source pipeline) pos in
        let path = Mreader_lexer.identifier_suffix path in
        let path = List.map ~f:(fun {Location. txt} -> txt) path in
        String.concat ~sep:"." path
    in
    if path = "" then `Invalid_context else
      Track_definition.get_doc ~config:(Mpipeline.final_config pipeline)
        ~env ~local_defs ~comments ~pos (`User_input path)

  | Locate (patho, ml_or_mli, pos) ->
    with_typer buffer @@ fun pipeline typer ->
    let local_defs = Mtyper.get_typedtree typer in
    let pos = Msource.get_lexing_pos (Mpipeline.input_source pipeline) pos in
    let env, _ = Mbrowse.leaf_node (Mtyper.node_at typer pos) in
    let path =
      match patho with
      | Some p -> p
      | None ->
        let path = Mreader_lexer.reconstruct_identifier
            (Mpipeline.input_source pipeline) pos in
        let path = Mreader_lexer.identifier_suffix path in
        let path = List.map ~f:(fun {Location. txt} -> txt) path in
        String.concat ~sep:"." path
    in
    if path = "" then `Invalid_context else
    begin match
        Track_definition.from_string
          ~config:(Mpipeline.final_config pipeline)
          ~env ~local_defs ~pos ml_or_mli
    with
    | `Found (file, pos) ->
      Logger.log "track_definition" "Locate"
        (Option.value ~default:"<local buffer>" file);
      `Found (file, pos)
    | otherwise -> otherwise
    end

  | Jump (target, pos) ->
    with_typer buffer @@ fun pipeline typer ->
    let typedtree = Mtyper.get_typedtree typer in
    let pos = Msource.get_lexing_pos (Mpipeline.input_source pipeline) pos in
    Jump.get typedtree pos target

  | Case_analysis (pos_start, pos_end) ->
    with_typer buffer @@ fun pipeline typer ->
    let source = Mpipeline.input_source pipeline in
    let loc_start = Msource.get_lexing_pos source pos_start in
    let loc_end = Msource.get_lexing_pos source pos_end in
    let loc_mid = Msource.get_lexing_pos source
        (`Offset (Lexing.(loc_start.pos_cnum + loc_end.pos_cnum) / 2)) in
    let loc = {Location. loc_start; loc_end; loc_ghost = false} in
    let env = Mtyper.get_env typer in
    (*Mreader.with_reader (Buffer.reader buffer) @@ fun () -> FIXME*)
    Printtyp.wrap_printing_env env ~verbosity @@ fun () ->
    let nodes =
      Mtyper.node_at typer loc_mid
      |> List.Non_empty.to_list
      |> List.map ~f:snd
    in
    Logger.logj "destruct" "nodes before"
      (fun () -> `List (List.map nodes
          ~f:(fun node -> `String (Browse_raw.string_of_node node))));
    let nodes =
      nodes
      |> List.drop_while ~f:(fun t ->
          Lexing.compare_pos (Mbrowse.node_loc t).Location.loc_start loc_start > 0 &&
          Lexing.compare_pos (Mbrowse.node_loc t).Location.loc_end loc_end < 0)
    in
    Logger.logj "destruct" "nodes after"
      (fun () -> `List (List.map nodes
          ~f:(fun node -> `String (Browse_raw.string_of_node node))));
    begin match nodes with
      | [] -> failwith "No node at given range"
      | node :: parents ->
        Destruct.node (Mpipeline.final_config pipeline) ~loc node parents
    end

  | Outline ->
    with_typer buffer @@ fun pipeline typer ->
    let browse = Mbrowse.of_typedtree (Mtyper.get_typedtree typer) in
    Outline.get [Browse_tree.of_browse browse]

  | Shape pos ->
    with_typer buffer @@ fun pipeline typer ->
    let browse = Mbrowse.of_typedtree (Mtyper.get_typedtree typer) in
    let pos = Msource.get_lexing_pos (Mpipeline.input_source pipeline) pos in
    Outline.shape pos [Browse_tree.of_browse browse]

  | Errors ->
    with_typer buffer @@ fun pipeline typer ->
    Printtyp.wrap_printing_env (Mtyper.get_env typer) ~verbosity @@ fun () ->
    failwith "TODO"
    (* FIXME: reintroduce error filtering code
   begin
      try
        let err exns =
          List.filter
            ~f:(fun {Error_report. loc; where} ->
                not loc.Location.loc_ghost || where <> "warning")
            (List.sort_uniq ~cmp (List.map ~f:Error_report.of_exn exns))
        in
        let err_reader = err (Mreader.errors (Buffer.reader buffer)) in
        let err_typer  =
          (* When there is a cmi error, we will have a lot of meaningless errors,
           * there is no need to report them. *)
          let exns = Mtyper.errors typer @ Mtyper.checks typer in
          let exns =
            let cmi_error = function Cmi_format.Error _ -> true | _ -> false in
            try [ List.find exns ~f:cmi_error ]
            with Not_found -> exns
          in
          err exns
        in
        (* Return parsing warnings & first parsing error,
           or type errors if no parsing errors *)
        let rec extract_warnings acc = function
          | {Error_report. where = "warning"; _ } as err :: errs ->
            extract_warnings (err :: acc) errs
          | err :: _ ->
            List.rev (err :: acc),
            List.take_while err_typer ~f:(fun err' -> cmp err' err < 0)
          | [] ->
            List.rev acc, err_typer
        in
        (* Filter duplicate error messages *)
        let err_parser, err_typer = extract_warnings [] err_reader in
        let errors = List.merge ~cmp err_reader err_typer in
        Error_report.flood_barrier errors
      with exn -> match Error_report.strict_of_exn exn with
        | None -> raise exn
        | Some err -> [err]
      end *)

  | Dump args ->
    failwith "TODO"

  | Which_path xs ->
    let config = Mpipeline.final_config (make_pipeline buffer) in
    let rec aux = function
      | [] -> raise Not_found
      | x :: xs ->
        try
          find_in_path_uncap Mconfig.(config.merlin.source_path) x
        with Not_found -> try
            find_in_path_uncap Mconfig.(config.merlin.build_path) x
          with Not_found ->
            aux xs
    in
    aux xs

  | Which_with_ext exts ->
    let config = Mpipeline.final_config (make_pipeline buffer) in
    let with_ext ext = modules_in_path ~ext
        Mconfig.(config.merlin.source_path) in
    List.concat_map ~f:with_ext exts

  | Flags_get ->
    List.concat Mconfig.(buffer.config.merlin.flags_to_apply)

  | Project_get -> ([], `Ok)
  (*TODO
    let project = Buffer.project buffer in
    (Project.get_dot_merlins project,
     match Project.get_dot_merlins_failure project with
     | [] -> `Ok
     | failures -> `Failures failures)*)

  | Findlib_list ->
    Fl_package_base.list_packages ()

  | Extension_list kind ->
    let pipeline = make_pipeline buffer in
    let config = Mpipeline.final_config pipeline in
    let enabled = Mconfig.(config.merlin.extensions) in
    begin match kind with
    | `All -> Extension.all
    | `Enabled -> enabled
    | `Disabled ->
      List.fold_left ~f:(fun exts ext -> List.remove ext exts)
        ~init:Extension.all enabled
    end

  | Path_list `Build ->
    let pipeline = make_pipeline buffer in
    let config = Mpipeline.final_config pipeline in
    Mconfig.(config.merlin.build_path)

  | Path_list `Source ->
    let pipeline = make_pipeline buffer in
    let config = Mpipeline.final_config pipeline in
    Mconfig.(config.merlin.source_path)

  | Occurrences (`Ident_at pos) ->
    with_typer buffer @@ fun pipeline typer ->
    let str = Mbrowse.of_typedtree (Mtyper.get_typedtree typer) in
    let pos = Msource.get_lexing_pos (Mpipeline.input_source pipeline) pos in
    let tnode = match Mbrowse.enclosing pos [str] with
      | Some t -> Browse_tree.of_browse t
      | None -> Browse_tree.dummy
    in
    let str = Browse_tree.of_browse str in
    let get_loc {Location.txt = _; loc} = loc in
    let ident_occurrence () =
      let paths = Browse_raw.node_paths tnode.Browse_tree.t_node in
      let under_cursor p = Location_aux.compare_pos pos (get_loc p) = 0 in
      Logger.logj "occurrences" "Occurrences paths" (fun () ->
          let dump_path ({Location.txt; loc} as p) =
            let ppf, to_string = Format.to_string () in
            Printtyp.path ppf txt;
            `Assoc [
              "start", Lexing.json_of_position loc.Location.loc_start;
              "end", Lexing.json_of_position loc.Location.loc_end;
              "under_cursor", `Bool (under_cursor p);
              "path", `String (to_string ())
            ]
          in
          `List (List.map ~f:dump_path paths));
      match List.filter paths ~f:under_cursor with
      | [] -> []
      | (path :: _) ->
        let path = path.Location.txt in
        let ts = Browse_tree.all_occurrences path str in
        let loc (_t,paths) = List.map ~f:get_loc paths in
        List.concat_map ~f:loc ts

    and constructor_occurrence d =
      let ts = Browse_tree.all_constructor_occurrences (tnode,d) str in
      List.map ~f:get_loc ts

    in
    let locs = match Browse_raw.node_is_constructor tnode.Browse_tree.t_node with
      | Some d -> constructor_occurrence d.Location.txt
      | None -> ident_occurrence ()
    in
    let loc_start l = l.Location.loc_start in
    let cmp l1 l2 = Lexing.compare_pos (loc_start l1) (loc_start l2) in
    List.sort ~cmp locs

  | Version ->
    Printf.sprintf "The Merlin toolkit version %s, for Ocaml %s\n"
      My_config.version Sys.ocaml_version;

  | Idle_job -> false

let dispatch_sync state (type a) : a sync_command -> a = function
  | Tell (pos_start, pos_end, text) ->
    let source = Msource.substitute state.source pos_start pos_end text in
    state.source <- source

  | Refresh ->
    checkout_buffer_cache := [];
    Cmi_cache.flush ()

  | Flags_set flags ->
    let open Mconfig in
    let flags_to_apply = [flags] in
    let config = state.config in
    state.config <- {config with merlin = {config.merlin with flags_to_apply}};
    `Ok

  | Findlib_use packages ->
    let open Mconfig in
    let config = state.config in
    let packages_to_load =
      List.filter_dup (packages @ config.merlin.packages_to_load) in
    state.config <-
      {config with merlin = {config.merlin with packages_to_load}};
    `Ok

  | Extension_set (action,exts) ->
    let f l = match action with
      | `Enabled  -> List.filter_dup (exts @ l)
      | `Disabled -> List.filter l ~f:(fun x -> not (List.mem x ~set:exts))
    in
    let open Mconfig in
    let config = state.config in
    let extensions = f config.merlin.extensions in
    state.config <- {config with merlin = {config.merlin with extensions}};
    `Ok

  | Path (var,action,paths) ->
    let f l = match action with
      | `Add -> List.filter_dup (paths @ l)
      | `Rem -> List.filter l ~f:(fun x -> not (List.mem x ~set:paths))
    in
    let open Mconfig in
    let merlin = state.config.merlin in
    let merlin =
      match var with
      | `Build -> {merlin with build_path = f merlin.build_path}
      | `Source -> {merlin with source_path = f merlin.source_path}
    in
    state.config <- {state.config with merlin}

  | Path_reset ->
    let open Mconfig in
    let merlin = state.config.merlin in
    let merlin = {merlin with build_path = []; source_path = []} in
    state.config <- {state.config with merlin}

  | Protocol_version version ->
    begin match version with
      | None -> ()
      | Some 2 -> IO.current_version := `V2
      | Some 3 -> IO.current_version := `V3
      | Some _ -> ()
    end;
    (`Selected !IO.current_version,
     `Latest IO.latest_version,
     Printf.sprintf "The Merlin toolkit version %s, for Ocaml %s\n"
       My_config.version Sys.ocaml_version)

  | Checkout _ -> IO.invalid_arguments ()

let default_state = lazy (new_state (None, None))

let document_states
  : (string option * string list option, state) Hashtbl.t
  = Hashtbl.create 7

let dispatch (type a) (context : Context.t) (cmd : a command) =
  let open Context in
  (* Document selection *)
  let state = match context.document with
    | None -> Lazy.force default_state
    | Some document ->
      let document = normalize_document document in
      try Hashtbl.find document_states document
      with Not_found ->
        let state = new_state document in
        Hashtbl.add document_states document state;
        state
  in
  (* Printer verbosity *)
  let verbosity = Option.value ~default:0 context.printer_verbosity in
  (* Printer width *)
  Format.default_width := Option.value ~default:0 context.printer_width;
  (* Actual dispatch *)
  match cmd with
  | Query q ->
    (*Mreader.with_reader (Buffer.reader state.buffer) @@ fun () -> TODO*)
    dispatch_query ~verbosity state.buffer q
  | Sync (Checkout context) when state == Lazy.force default_state ->
    let buffer = checkout_buffer context in
    state.buffer <- buffer
  | Sync s -> dispatch_sync state.buffer s
