(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
module Request = CodeNavigationServer.Testing.Request
module Response = CodeNavigationServer.Testing.Response

let position line column = { Ast.Location.line; column }

let range start_line start_column stop_line stop_column =
  { Ast.Location.start = position start_line start_column; stop = position stop_line stop_column }


let assert_type_error_count ?overlay_id ~client ~expected module_name =
  let%lwt raw_response =
    ScratchProject.Client.send_request
      client
      Request.(GetTypeErrors { module_ = Module.OfName module_name; overlay_id })
  in
  match Yojson.Safe.from_string raw_response with
  | `List [`String "TypeErrors"; `List errors] ->
      assert_equal
        ~ctxt:(ScratchProject.Client.get_context client)
        ~cmp:Int.equal
        ~printer:Int.to_string
        expected
        (List.length errors);
      Lwt.return_unit
  | _ as json ->
      let message =
        Format.sprintf "Expected type error response but got: `%s`" (Yojson.Safe.to_string json)
      in
      assert_failure message


let test_no_op_server context =
  ScratchProject.setup ~context ~include_typeshed_stubs:false []
  |> ScratchProject.test_server_with ~f:(fun _ -> Lwt.return_unit)


let test_invalid_request context =
  let test_invalid_request client =
    let%lwt raw_response = ScratchProject.Client.send_raw_request client "derp" in
    match Yojson.Safe.from_string raw_response with
    | `List [`String "Error"; `List (`String "InvalidRequest" :: _)] -> Lwt.return_unit
    | _ as json ->
        let message =
          Format.sprintf "Expected error response but got: `%s`" (Yojson.Safe.to_string json)
        in
        assert_failure message
  in
  ScratchProject.setup ~context ~include_typeshed_stubs:false []
  |> ScratchProject.test_server_with ~f:test_invalid_request


let test_stop_request context =
  let test_stop_request client =
    let%lwt _ = ScratchProject.Client.send_request client Request.Stop in
    (* Consuming the stop request would make the server terminate itself immeidately, bypassing this
       eternal-wait. *)
    let wait_forever, _ = Lwt.wait () in
    wait_forever
  in
  ScratchProject.setup ~context ~include_typeshed_stubs:false []
  |> ScratchProject.test_server_with ~f:test_stop_request


let test_get_type_errors_request context =
  let test_get_type_errors_request client =
    let root = ScratchProject.Client.get_source_root client in
    let test_path = PyrePath.create_relative ~root ~relative:"test.py" in
    let expected_error =
      Analysis.AnalysisError.Instantiated.of_yojson
        (`Assoc
          [
            "line", `Int 1;
            "column", `Int 0;
            "stop_line", `Int 1;
            "stop_column", `Int 11;
            "path", `String (PyrePath.absolute test_path);
            "code", `Int (-1);
            "name", `String "Revealed type";
            ( "description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            ( "long_description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            ( "concise_description",
              `String
                "Revealed type [-1]: Revealed type for `42` is `typing_extensions.Literal[42]`." );
            "define", `String "test.$toplevel";
          ])
      |> Result.ok_or_failwith
    in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:Request.(GetTypeErrors { overlay_id = None; module_ = Module.OfName "test" })
        ~expected:(Response.TypeErrors [expected_error])
    in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            GetTypeErrors
              { overlay_id = None; module_ = Module.OfPath (PyrePath.absolute test_path) })
        ~expected:(Response.TypeErrors [expected_error])
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(GetTypeErrors { overlay_id = None; module_ = Module.OfName "doesnotexist" })
        ~kind:"ModuleNotTracked"
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(GetTypeErrors { overlay_id = None; module_ = Module.OfPath "/doesnotexist.py" })
        ~kind:"ModuleNotTracked"
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            GetTypeErrors { overlay_id = Some "doesnotexist"; module_ = Module.OfName "test" })
        ~kind:"OverlayNotFound"
    in
    Lwt.return_unit
  in
  ScratchProject.setup ~context ~include_typeshed_stubs:false ["test.py", "reveal_type(42)"]
  |> ScratchProject.test_server_with ~f:test_get_type_errors_request


let test_local_update_request context =
  let test_local_update_request client =
    let%lwt () = assert_type_error_count "test" ~client ~expected:1 in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            LocalUpdate
              {
                module_ = Module.OfName "test";
                content = "reveal_type(43)\nreveal_type(44)";
                overlay_id = "foo";
              })
        ~expected:Response.Ok
    in
    let%lwt () = assert_type_error_count "test" ~client ~overlay_id:"foo" ~expected:2 in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            LocalUpdate { module_ = Module.OfName "doesnotexist"; content = ""; overlay_id = "foo" })
        ~kind:"ModuleNotTracked"
    in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            LocalUpdate
              {
                module_ = Module.OfName "test";
                content = "reveal_type(43)\nreveal_type(44)\nreveal_type(45)";
                overlay_id = "bar";
              })
        ~expected:Response.Ok
    in
    let%lwt () = assert_type_error_count "test" ~client ~overlay_id:"bar" ~expected:3 in
    let%lwt () = assert_type_error_count "test" ~client ~overlay_id:"foo" ~expected:2 in
    let%lwt () = assert_type_error_count "test" ~client ~expected:1 in
    Lwt.return_unit
  in
  ScratchProject.setup ~context ~include_typeshed_stubs:false ["test.py", "reveal_type(42)"]
  |> ScratchProject.test_server_with ~f:test_local_update_request


let test_hover_request context =
  let test_hover_request client =
    let root = ScratchProject.Client.get_source_root client in
    let test_path = PyrePath.create_relative ~root ~relative:"test.py" in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            (* This location point to empty space. *)
            Hover { overlay_id = None; module_ = Module.OfName "test"; position = position 1 2 })
        ~expected:Response.(Hover { contents = [] })
    in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            Hover { overlay_id = None; module_ = Module.OfName "test"; position = position 1 0 })
        ~expected:
          Response.(
            Hover { contents = HoverContent.[{ kind = Kind.PlainText; value = "`float`" }] })
    in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            Hover
              {
                overlay_id = None;
                module_ = Module.OfPath (PyrePath.absolute test_path);
                position = position 1 0;
              })
        ~expected:
          Response.(
            Hover { contents = HoverContent.[{ kind = Kind.PlainText; value = "`float`" }] })
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            Hover
              { overlay_id = None; module_ = Module.OfName "doesnotexist"; position = position 1 0 })
        ~kind:"ModuleNotTracked"
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            Hover
              {
                overlay_id = None;
                module_ = Module.OfPath "/doesnotexist.py";
                position = position 1 0;
              })
        ~kind:"ModuleNotTracked"
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            Hover
              {
                overlay_id = Some "doesnotexist";
                module_ = Module.OfName "test";
                position = position 1 0;
              })
        ~kind:"OverlayNotFound"
    in
    Lwt.return_unit
  in
  ScratchProject.setup ~context ~include_typeshed_stubs:false ["test.py", "x: float = 4.2"]
  |> ScratchProject.test_server_with ~f:test_hover_request


let test_location_of_definition_request context =
  let test_location_of_definition_request client =
    let root = ScratchProject.Client.get_source_root client in
    let test_path = PyrePath.create_relative ~root ~relative:"test.py" in
    let test2_path = PyrePath.create_relative ~root ~relative:"test2.py" in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            (* This location points to an empty space *)
            LocationOfDefinition
              { overlay_id = None; module_ = Module.OfName "test2"; position = position 2 8 })
        ~expected:Response.(LocationOfDefinition [])
    in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            (* This location points to `test.x` *)
            LocationOfDefinition
              { overlay_id = None; module_ = Module.OfName "test2"; position = position 2 14 })
        ~expected:
          Response.(
            LocationOfDefinition
              [{ DefinitionLocation.path = PyrePath.absolute test_path; range = range 1 0 1 1 }])
    in
    let%lwt () =
      ScratchProject.Client.assert_response
        client
        ~request:
          Request.(
            LocationOfDefinition
              {
                overlay_id = None;
                module_ = Module.OfPath (PyrePath.absolute test2_path);
                position = position 2 14;
              })
        ~expected:
          Response.(
            LocationOfDefinition
              [{ DefinitionLocation.path = PyrePath.absolute test_path; range = range 1 0 1 1 }])
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            LocationOfDefinition
              { overlay_id = None; module_ = Module.OfName "doesnotexist"; position = position 1 0 })
        ~kind:"ModuleNotTracked"
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            LocationOfDefinition
              {
                overlay_id = None;
                module_ = Module.OfPath "/doesnotexist.py";
                position = position 1 0;
              })
        ~kind:"ModuleNotTracked"
    in
    let%lwt () =
      ScratchProject.Client.assert_error_response
        client
        ~request:
          Request.(
            LocationOfDefinition
              {
                overlay_id = Some "doesnotexist";
                module_ = Module.OfName "test";
                position = position 1 0;
              })
        ~kind:"OverlayNotFound"
    in
    Lwt.return_unit
  in
  ScratchProject.setup
    ~context
    ~include_typeshed_stubs:false
    ["test.py", "x: int = 42"; "test2.py", "import test\ny: int = test.x"]
  |> ScratchProject.test_server_with ~f:test_location_of_definition_request


let () =
  "basic_test"
  >::: [
         "no_op_server" >:: OUnitLwt.lwt_wrapper test_no_op_server;
         "invalid_request" >:: OUnitLwt.lwt_wrapper test_invalid_request;
         "stop_request" >:: OUnitLwt.lwt_wrapper test_stop_request;
         "get_type_errors_request" >:: OUnitLwt.lwt_wrapper test_get_type_errors_request;
         "local_update_request" >:: OUnitLwt.lwt_wrapper test_local_update_request;
         "hover_request" >:: OUnitLwt.lwt_wrapper test_hover_request;
         "location_of_definition_request"
         >:: OUnitLwt.lwt_wrapper test_location_of_definition_request;
       ]
  |> Test.run
