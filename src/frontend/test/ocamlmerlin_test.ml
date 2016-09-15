open Std

(* Poor man's test framework *)
type name = string

type test =
  | Single of name * (unit -> unit)
  | Group of name * test list

let test name f = Single (name, f)

let group name tests = Group (name, tests)

exception Detail of exn * string
let () = Printexc.register_printer (function
    | (Detail (exn, msg)) ->
      Some (Printexc.to_string exn ^ "\nAdditional information:\n" ^ msg)
    | _ -> None
  )

(* Setting up merlin *)
module M = Mpipeline

let from_source ?(with_config=fun x -> x) ~filename text =
  let config = with_config Mconfig.initial in
  let config = Mconfig.({config with query = {config.query with filename}}) in
  (config, Msource.make config text)

let process ?with_config ?for_completion filename text =
  let config, source = from_source ?with_config ~filename text in
  M.make ?for_completion (Trace.start ()) config source

(* All tests *)

let assert_errors ?with_config
    filename ?(lexer=false) ?(parser=false) ?(typer=false) ?(config=false) source =
  test filename (fun () ->
      let m = process ?with_config filename source in
      let lexer_errors  = M.reader_lexer_errors m in
      let parser_errors = M.reader_parser_errors m in
      let failures, typer_errors  =
        Mtyper.with_typer (M.typer_result m) @@ fun () ->
        Mconfig.((M.final_config m).merlin.failures),
        M.typer_errors m
      in
      let fmt_msg exn =
        match Location.error_of_exn exn with
        | None -> Printexc.to_string exn
        | Some err -> err.Location.msg
      in
      let expect_or_not b str =
        (if b then "expecting " else "unexpected ") ^ str ^ "\n" ^
        String.concat "\n- " ("Errors: " :: List.map_end fmt_msg
                                (lexer_errors @ parser_errors @ typer_errors)
                                failures)
      in
      if (lexer_errors <> []) <> lexer then
        failwith (expect_or_not lexer "lexer errors");
      if (parser_errors <> []) <> parser then
        failwith (expect_or_not parser "parser errors");
      if (typer_errors <> []) <> typer then
        failwith (expect_or_not typer "typer errors");
      if (failures <> []) <> config then
        failwith (expect_or_not config "configuration failures");
    )

let assertf b fmt =
  if b then
    Printf.ikfprintf ignore () fmt
  else
    Printf.ksprintf failwith fmt

let validate_output ?with_config filename source query pred =
  test filename (fun () ->
      let config, source = from_source ?with_config ~filename source in
      let result =
        Query_commands.dispatch (Trace.start (), config, source) query in
      try pred result
      with exn ->
        let info = `Assoc [
            "query", Query_json.dump query;
            "result", Query_json.json_of_response query result;
          ] in
        raise (Detail (exn, Json.pretty_to_string info))
    )

(* FIXME: this sucks. improve. *)
let validate_failure ?with_config filename source query pred =
  test filename (fun () ->
      let config, source = from_source ?with_config ~filename source in
      let for_info, wrapped =
        match Query_commands.dispatch (Trace.start (), config, source) query with
        | exception e -> ("failure", `String (Printexc.to_string e)), `Error e
        | res -> ("result", Query_json.json_of_response query res), `Ok res
      in
      try pred wrapped
      with exn ->
        let info = `Assoc [ "query", Query_json.dump query; for_info ] in
        raise (Detail (exn, Json.pretty_to_string info))
    )

let tests = [

  group "no-escape" (
    [
      (* These tests ensure that all type errors are caught by the kernel,
         no exception should reach top-level *)

      assert_errors "incorrect_gadt.ml"
        ~parser:true ~typer:true
        "type p = P : 'a -> 'a -> p";

      assert_errors "unkown_constr.ml"
        ~typer:true
        "let error : unknown_type_constructor = assert false";

      assert_errors "unkown_constr.mli"
        ~typer:true
        "val error : unknown_type_constructor";

      assert_errors "ml_in_mli.mli"
        ~parser:true
        "let x = 4 val x : int";

      assert_errors "mli_in_ml.ml"
        ~typer:true (* vals are no allowed in ml files and detected
                       during semantic analysis *)
        "val x : int";
    ]
  );

  group "ocaml-flags" (
    let assert_errors ?lexer ?parser ?typer ?(flags=[]) filename source =
      assert_errors ?lexer ?parser ?typer
        ~with_config:(fun config ->
            let flags = {
              Mconfig.
              flag_cwd = None;
              flag_list = flags;
            } in
            Mconfig.({config with merlin = {config.merlin with
                                            flags_to_apply = [flags]}}))
        filename
        source
    in
    [

      (* -unsafe and array desugaring *)

      assert_errors "array_good.ml"
        "let x = [|0|].(0)";

      assert_errors "array_bad.ml"
        ~typer:true
        "module Array = struct end\n\
         let x = [|0|].(0)";

      assert_errors "array_fake_good.ml"
        "module Array = struct let get _ _ = () end\n\
         let x = [|0|].(0)";

      assert_errors ~flags:["-unsafe"] "unsafe_array_good.ml"
        "let x = [|0|].(0)";

      assert_errors ~flags:["-unsafe"] "unsafe_array_bad.ml"
        ~typer:true
        "module Array = struct end\n\
         let x = [|0|].(0)";

      assert_errors ~flags:["-unsafe"] "unsafe_array_fake_good.ml"
        "module Array = struct let unsafe_get _ _ = () end\n\
         let x = [|0|].(0)";

      (* classic and labels *)

      assert_errors "labels_ok_1.ml"
        "let f ~x = () in f ~x:(); f ()";

      assert_errors ~flags:["-nolabels"] "classic_ko_1.ml"
        "let f ~x = () in f ~x:(); f ()";
    ]
  );

  group "path-expansion" (
    let test_ppx_path name flag_list ?cwd item =
      test name (fun () ->
          let open Mconfig in
          let m = process ~with_config:(fun cfg ->
              let merlin = {cfg.merlin with
                            flags_to_apply = [{flag_cwd = cwd; flag_list}]} in
              {cfg with merlin}
            ) "relative_path.ml" ""
          in
          let config = Mpipeline.reader_config m in
          let dump () cfg = Json.pretty_to_string (Mconfig.dump cfg) in
          assertf
            (List.mem item config.ocaml.ppx)
            "Expecting %s in config.\nConfig:\n%a"
            item dump config;
        )
    in
    [
      (* Simple name is not expanded *)
      test_ppx_path "simple_name" ["-ppx"; "test1"] "test1";

      (* Absolute name is not expanded *)
      test_ppx_path "absolute_path" ["-ppx"; "/test2"] "/test2";

      (* Relative name is expanded *)
      test_ppx_path "relative_path" ~cwd:"/tmp"
        ["-ppx"; "./test3"] "/tmp/test3";

      (* Quoted flags inherit path *)
      test_ppx_path "quoted_path" ~cwd:"/tmp"
        ["-flags"; "-ppx ./test4"] "/tmp/test4";
    ]

  );

  group "destruct" (
    [
      (* TODO: test all error cases. *)

      validate_failure "nothing_to_do.ml"
        "let _ = match (None : unit option) with None -> () | Some () -> ()"
        (Query_protocol.Case_analysis (`Offset 58, `Offset 60))
        (function
          | `Error Destruct.Nothing_to_do -> ()
          | _  -> assertf false "expected Nothing_to_do exception");

      (* TODO: at some point properly check locations as well. *)

      validate_output "make_exhaustive.ml"
        "let _ = match (None : unit option) with None -> ()"
        (Query_protocol.Case_analysis (`Offset 40, `Offset 44))
        (fun (_loc, s) ->
           let expected = "\n| Some _ -> (??)" in
           assertf (s = expected) "expected %S" expected);

      validate_output "refine_pattern.ml"
        "let _ = match (None : unit option) with None -> ()\n| Some _ -> (??)"
        (Query_protocol.Case_analysis (`Offset 59, `Offset 60))
        (fun (_loc, s) ->
           let expected = "()" in
           assertf (s = expected) "expected %S" expected);

      validate_output "unpack_module.ml"
        "module type S = sig end\n\nlet g (x : (module S)) =\n  x"
        (Query_protocol.Case_analysis (`Offset 52, `Offset 53))
        (fun (_loc, s) ->
           let expected = "let module M = (val x) in (??)" in
           assertf (s = expected) "expected %S" expected);

      validate_output "record_exp.ml"
        "let f (x : int ref) =\n  x"
        (Query_protocol.Case_analysis (`Offset 24, `Offset 25))
        (fun (_loc, s) ->
           let expected = "match x with | { contents } -> (??)" in
           assertf (s = expected) "expected %S" expected);

      validate_output "variant_exp.ml"
        "let f (x : int option) =\n  x"
        (Query_protocol.Case_analysis (`Offset 27, `Offset 28))
        (fun (_loc, s) ->
           let expected = "match x with | None -> (??) | Some _ -> (??)" in
           assertf (s = expected) "expected %S" expected);

    ]
  );

  group "misc" (
    [
      assert_errors "relaxed_external.ml"
        "external test : unit = \"bs\"";

      validate_output "occurrences.ml"
        "let foo _ = ()\nlet () = foo 4\n"
        (Query_protocol.Occurrences (`Ident_at (`Offset 5)))
        (fun locations ->
           assertf (List.length locations = 2) "expected two locations");

      validate_output "locate.ml"
        "let foo _ = ()\nlet () = foo 4\n"
        (Query_protocol.Locate (None, `ML, `Offset 26))
        (function
          | `Found (Some "locate.ml", pos)
            when Lexing.split_pos pos = (1, 4) -> ()
          | _ -> assertf false "Expecting match at position (1, 4)");

      assert_errors "invalid_flag.ml" ~config:true
        ~with_config:(fun cfg ->
            let open Mconfig in
            let flags_to_apply = [{
                flag_cwd = None;
                flag_list = ["-lalala"]
              }] in
            Mconfig.({cfg with merlin = {cfg.merlin with flags_to_apply}}))
         ""
      ;
    ]
  );

]

(* Driver *)

let passed = ref 0
let failed = ref 0

let rec run_tests indent = function
  | [] -> ()
  | x :: xs ->
    run_test indent x;
    run_tests indent xs

and run_test indent = function
  | Single (name, f) ->
    Printf.printf "%s%s:\t%!" indent name;
    begin match f () with
      | () ->
        incr passed;
        Printf.printf "OK\n%!"
      | exception exn ->
        incr failed;
        Printf.printf "KO\n%!";
        Printf.eprintf "%sTest %s failed with error:\n%s%s\n%!"
          indent name
          indent
          (match exn with Failure str -> str | exn -> Printexc.to_string exn)
    end
  | Group (name, tests) ->
    Printf.printf "%s-> %s\n" indent name;
    run_tests (indent ^ "  ") tests

let () =
  run_tests "  " tests;
  Printf.printf "Passed %d, failed %d\n" !passed !failed;
  if !failed > 0 then exit 1