(*s: parse_php.ml *)
(*s: Facebook copyright *)
(* Yoann Padioleau
 * 
 * Copyright (C) 2009-2011 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
(*e: Facebook copyright *)

open Common 

(*s: parse_php module aliases *)
module Ast  = Ast_php
module Flag = Flag_parsing_php
module TH   = Token_helpers_php
module T = Parser_php

open Ast_php
(*e: parse_php module aliases *)

module PI = Parse_info

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type program_with_comments = Ast_php.program * Parser_php.token list

(*****************************************************************************)
(* Wrappers *)
(*****************************************************************************)
let pr2_err, pr2_once = Common2.mk_pr2_wrappers Flag.verbose_parsing 

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)
(*s: parse_php helpers *)
let lexbuf_to_strpos lexbuf     = 
  (Lexing.lexeme lexbuf, Lexing.lexeme_start lexbuf)    

let token_to_strpos tok = 
  (TH.str_of_tok tok, TH.pos_of_tok tok)
(*x: parse_php helpers *)
(*x: parse_php helpers *)
(* on very huge file, this function was previously segmentation fault
 * in native mode because span was not tail call
 *)
(*e: parse_php helpers *)

(*****************************************************************************)
(* Error diagnostic  *)
(*****************************************************************************)
(*s: parse_php error diagnostic *)
let error_msg_tok tok = 
  PI.error_message_info (TH.info_of_tok tok)
(*e: parse_php error diagnostic *)

(*****************************************************************************)
(* Stat *)
(*****************************************************************************)

(*****************************************************************************)
(* Lexing only *)
(*****************************************************************************)
(*s: function tokens *)
let tokens_from_changen ?(init_state=Lexer_php.INITIAL) changen =
  let table     = PI.full_charpos_to_pos_large_from_changen changen in

  let (chan, _, file) = changen () in

  Common.finalize (fun () ->
    let lexbuf = Lexing.from_channel chan in

    Lexer_php.reset();
    Lexer_php._mode_stack := [init_state];

    try 
      (*s: function phptoken *)
      let phptoken lexbuf = 
        (*s: yyless trick in phptoken *)
          (* for yyless emulation *)
          match !Lexer_php._pending_tokens with
          | x::xs -> 
              Lexer_php._pending_tokens := xs; 
              x
          | [] ->
        (*e: yyless trick in phptoken *)
            (match Lexer_php.current_mode () with
            | Lexer_php.INITIAL -> 
                Lexer_php.initial lexbuf
            | Lexer_php.ST_IN_SCRIPTING -> 
                Lexer_php.st_in_scripting lexbuf
            | Lexer_php.ST_IN_SCRIPTING2 -> 
                Lexer_php.st_in_scripting lexbuf
            | Lexer_php.ST_DOUBLE_QUOTES -> 
                Lexer_php.st_double_quotes lexbuf
            | Lexer_php.ST_BACKQUOTE -> 
                Lexer_php.st_backquote lexbuf
            | Lexer_php.ST_LOOKING_FOR_PROPERTY -> 
                Lexer_php.st_looking_for_property lexbuf
            | Lexer_php.ST_LOOKING_FOR_VARNAME -> 
                Lexer_php.st_looking_for_varname lexbuf
            | Lexer_php.ST_VAR_OFFSET -> 
                Lexer_php.st_var_offset lexbuf
            | Lexer_php.ST_START_HEREDOC s ->
                Lexer_php.st_start_heredoc s lexbuf
            | Lexer_php.ST_START_NOWDOC s ->
                Lexer_php.st_start_nowdoc s lexbuf

            (* xhp: *)
            | Lexer_php.ST_IN_XHP_TAG current_tag ->
                if not !Flag.xhp_builtin
                then raise Impossible;

                Lexer_php.st_in_xhp_tag current_tag lexbuf
            | Lexer_php.ST_IN_XHP_TEXT current_tag ->
                if not !Flag.xhp_builtin
                then raise Impossible;

                Lexer_php.st_in_xhp_text current_tag lexbuf
            )
      in
      (*e: function phptoken *)

      let rec tokens_aux acc = 
        let tok = phptoken lexbuf in

        if !Flag.debug_lexer then Common.pr2_gen tok;
        if not (TH.is_comment tok)
        then Lexer_php._last_non_whitespace_like_token := Some tok;

        (*s: fill in the line and col information for tok *)
        let tok = tok +> TH.visitor_info_of_tok (fun ii ->
        { ii with PI.token=
          (* could assert pinfo.filename = file ? *)
               match ii.PI.token with
               | PI.OriginTok pi ->
                          PI.OriginTok 
                            (PI.complete_token_location_large file table pi)
               | PI.FakeTokStr _
               | PI.Ab  
               | PI.ExpandedTok _
                        -> raise Impossible
                  })
        in
        (*e: fill in the line and col information for tok *)

        if TH.is_eof tok
        then List.rev (tok::acc)
        else tokens_aux (tok::acc)
    in
    tokens_aux []
  with
  | Lexer_php.Lexical s -> 
      failwith ("lexical error " ^ s ^ "\n =" ^ 
                   (PI.error_message file (lexbuf_to_strpos lexbuf)))
  | e -> raise e
 )
 (fun () -> close_in chan)

let tokens2 ?init_state =
  PI.file_wrap_changen (tokens_from_changen ?init_state)

(*x: function tokens *)
let tokens ?init_state a = 
  Common.profile_code "Parse_php.tokens" (fun () -> tokens2 ?init_state a)
(*e: function tokens *)

(*****************************************************************************)
(* Helper for main entry point *)
(*****************************************************************************)
(*s: parse tokens_state helper *)
(*x: parse tokens_state helper *)
(*x: parse tokens_state helper *)
(* Hacked lex. This function use refs passed by parse.
 * 'tr' means 'token refs'.
 *)
let rec lexer_function tr = fun lexbuf ->
  match tr.PI.rest with
  | [] -> (pr2 "LEXER: ALREADY AT END"; tr.PI.current)
  | v::xs -> 
      tr.PI.rest <- xs;
      tr.PI.current <- v;
      tr.PI.passed <- v::tr.PI.passed;

      if TH.is_comment v ||
        (* TODO a little bit specific to FB ? *)
        (match v with
        | Parser_php.T_OPEN_TAG _ -> true
        | Parser_php.T_CLOSE_TAG _ -> true
        | _ -> false
        )
      then lexer_function (*~pass*) tr lexbuf
      else v

(*e: parse tokens_state helper *)

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)
(*s: Parse_php.parse *)

(* could move that in h_program-lang/, but maybe clearer to put it closer
 * to the parsing function.
 *)
exception Parse_error of PI.info

let parse2 ?(pp=(!Flag.pp_default)) filename =

  let orig_filename = filename in
  let filename =
    (* note that now that pfff support XHP constructs directly, 
     * this code is not that needed.
     *)
    match pp with
    | None -> orig_filename
    | Some cmd ->
        Common.profile_code "Parse_php.pp_maybe" (fun () ->

          let pp_flag = if !Flag.verbose_pp then "-v" else "" in

          (* The following requires the preprocessor command to
           * support the -q command line flag.
           * 
           * Maybe a little bit specific to XHP and xhpize ... But
           * because I use as a convention that 0 means no_need_pp, if
           * the preprocessor does not support -q, it should return an
           * error code, in which case we will fall back to the regular
           * case. *)
          let cmd_need_pp = 
            spf "%s -q %s %s" cmd pp_flag filename in
          if !Flag.verbose_pp then pr2 (spf "executing %s" cmd_need_pp);
          let ret = Sys.command cmd_need_pp in
          if ret = 0 
          then orig_filename
          else begin
            Common.profile_code "Parse_php.pp" (fun () ->
            let tmpfile = Common.new_temp_file "pp" ".pphp" in
            let fullcmd = 
              spf "%s %s %s > %s" cmd pp_flag filename tmpfile in
            if !Flag.verbose_pp then pr2 (spf "executing %s" fullcmd);
            let ret = Sys.command fullcmd in
            if ret <> 0
            then failwith "The preprocessor command returned an error code";
            tmpfile
            )
          end
        )
  in

  let stat = PI.default_stat filename in
  let filelines = Common2.cat_array filename in

  let toks = tokens filename in
  (* note that now that pfff support XHP constructs directly, 
   * this code is not that needed.
   *)
  let toks = 
    if filename = orig_filename
    then toks
    else Pp_php.adapt_tokens_pp ~tokenizer:tokens ~orig_filename toks
  in

  let tr = PI.mk_tokens_state toks in

  let checkpoint = TH.line_of_tok tr.PI.current in

  let lexbuf_fake = Lexing.from_function (fun buf n -> raise Impossible) in
  let elems = 
    try (
      (* -------------------------------------------------- *)
      (* Call parser *)
      (* -------------------------------------------------- *)
      Left 
        (Common.profile_code "Parser_php.main" (fun () ->
          (Parser_php.main (lexer_function tr) lexbuf_fake)
        ))
    ) with e ->

      let line_error = TH.line_of_tok tr.PI.current in

      let _passed_before_error = tr.PI.passed in
      let current = tr.PI.current in

      (* no error recovery, the whole file is discarded *)
      tr.PI.passed <- List.rev toks;

      let info_of_bads = Common2.map_eff_rev TH.info_of_tok tr.PI.passed in 

      Right (info_of_bads, line_error, current, e)
  in

  match elems with
  | Left xs ->
      stat.PI.correct <- (Common.cat filename +> List.length);

      (xs, toks), 
      stat
  | Right (info_of_bads, line_error, cur, exn) ->

      if not !Flag.error_recovery 
      then raise (Parse_error (TH.info_of_tok cur));

      (match exn with
      | Lexer_php.Lexical _ 
      | Parsing.Parse_error 
          (*| Semantic_c.Semantic _  *)
        -> ()
      | e -> raise e
      );

      if !Flag.show_parsing_error
      then 
        (match exn with
        (* Lexical is not anymore launched I think *)
        | Lexer_php.Lexical s -> 
            pr2 ("lexical error " ^s^ "\n =" ^ error_msg_tok cur)
        | Parsing.Parse_error -> 
            pr2 ("parse error \n = " ^ error_msg_tok cur)
              (* | Semantic_java.Semantic (s, i) -> 
                 pr2 ("semantic error " ^s^ "\n ="^ error_msg_tok tr.current)
          *)
        | e -> raise Impossible
        );
      let checkpoint2 = Common.cat filename +> List.length in


      if !Flag.show_parsing_error_full
      then PI.print_bad line_error (checkpoint, checkpoint2) filelines;

      stat.PI.bad     <- Common.cat filename +> List.length;

      let info_item = (List.rev tr.PI.passed) in 
      ([Ast.NotParsedCorrectly info_of_bads], info_item), 
      stat
(*x: Parse_php.parse *)

let _hmemo_parse_php = Hashtbl.create 101

let parse_memo ?pp file = 
  if not !Flag.caching_parsing
  then parse2 ?pp file
  else
    Common.memoized _hmemo_parse_php file (fun () -> 
      Common.profile_code "Parse_php.parse_no_memo" (fun () ->
        parse2 ?pp file
      )
    )

let parse ?pp a = 
  Common.profile_code "Parse_php.parse" (fun () -> parse_memo ?pp a)
(*e: Parse_php.parse *)

let parse_program ?pp file = 
  let ((ast, toks), _stat) = parse ?pp file in
  ast

let ast_and_tokens file =
  let ((ast, toks), _stat) = parse file in
  (ast, toks)

(*****************************************************************************)
(* Sub parsers *)
(*****************************************************************************)

let parse_any_from_changen (changen : PI.changen) =
  let toks = tokens_from_changen ~init_state:Lexer_php.ST_IN_SCRIPTING changen  in

  let tr = PI.mk_tokens_state toks in
  let lexbuf_fake = Lexing.from_function (fun buf n -> raise Impossible) in

  try 
    Parser_php.sgrep_spatch_pattern (lexer_function tr) lexbuf_fake
  with exn ->
    let cur = tr.PI.current in
    if !Flag.show_parsing_error
    then 
    (match exn with
     (* Lexical is not anymore launched I think *)
     | Lexer_php.Lexical s -> 
         pr2 ("lexical error " ^s^ "\n =" ^ error_msg_tok cur)
     | Parsing.Parse_error -> 
         pr2 ("parse error \n = " ^ error_msg_tok cur)
    (* | Semantic_java.Semantic (s, i) -> 
         pr2 ("semantic error " ^s^ "\n ="^ error_msg_tok tr.current)
    *)
     | _ -> raise exn
    );
    raise exn

let parse_any = PI.file_wrap_changen parse_any_from_changen

(* any_of_string() allows small chunks of PHP to be parsed without
 * having to use the filesystem by leveraging the changen mechanism.
 * In order to supply a string as a channel we must create a socket
 * pair and write our string to it.  This is not ideal and may fail if
 * we try to parse too many short strings without closing the channel,
 * or if the string is so large that the OS blocks our socket. 
 *)
let any_of_string s =
  let len = String.length s in
  let changen = (fun () ->
    let (socket_a, socket_b) = Unix.(socketpair PF_UNIX SOCK_STREAM 0) in
    let fake_filename = "" in
    let (data_in, data_out) =
      Unix.(in_channel_of_descr socket_a, out_channel_of_descr socket_b) in
    output_string data_out s;
    flush data_out;
    close_out data_out;
    (data_in, len, fake_filename)) in
  (* disable showing parsing errors as there is no filename and
   * error_msg_tok() would throw a Sys_error exception
   *)
  Common.save_excursion Flag.show_parsing_error false (fun () ->
    parse_any_from_changen changen
  )

(* 
 * todo: obsolete now with parse_any ? just redirect to parse_any ?
 * 
 * This function is useful not only to test but also in our own code
 * as a shortcut to build complex expressions
 *)
let (expr_of_string: string -> Ast_php.expr) = fun s ->
  let tmpfile = Common.new_temp_file "pfff_expr_of_s" "php" in
  Common.write_file tmpfile ("<?php \n" ^ s ^ ";\n");

  let ast = parse_program tmpfile in

  let res = 
    (match ast with
    | [Ast.StmtList [Ast.ExprStmt (e, _tok)];Ast.FinalDef _] -> e
  | _ -> failwith "only expr pattern are supported for now"
  )
  in
  Common.erase_this_temp_file tmpfile;
  res

(* It is clearer for our testing code to programmatically build source files
 * so that all the information about a test is in the same
 * file. You don't have to open extra files to understand the test
 * data. This function is useful mostly for our unit tests 
*)
let (program_of_string: string -> Ast_php.program) = fun s -> 
  let tmpfile = Common.new_temp_file "pfff_expr_of_s" "php" in
  Common.write_file tmpfile ("<?php \n" ^ s ^ "\n");
  let ast = parse_program tmpfile in
  Common.erase_this_temp_file tmpfile;
  ast

(* use program_of_string when you can *)
let tmp_php_file_from_string s =
  let tmp_file = Common.new_temp_file "test" ".php" in
  Common.write_file ~file:tmp_file ("<?php\n" ^ s);
  tmp_file


(* this function is useful mostly for our unit tests *)
let (tokens_of_string: string -> Parser_php.token list) = fun s -> 
  let tmpfile = Common.new_temp_file "pfff_tokens_of_s" "php" in
  Common.write_file tmpfile ("<?php \n" ^ s ^ "\n");
  let toks = tokens tmpfile in
  Common.erase_this_temp_file tmpfile;
  toks
  

(* 
 * The regular lexer 'tokens' at the beginning of this file is quite
 * complicated because it has to maintain a state (for the HereDoc, 
 * interpolated string, HTML switching mode, etc) and it also takes 
 * a file not a string because it annotates tokens with file position.
 * Sometimes we need only a simple and faster lexer and one that can 
 * take a string hence this function.
 *)
let rec basic_lexer_skip_comments lexbuf = 
  let tok = Lexer_php.st_in_scripting lexbuf in
  if TH.is_comment tok 
  then basic_lexer_skip_comments lexbuf
  else tok

(* A fast-path parser of xdebug expressions in xdebug dumpfiles. 
 * See xdebug.ml *)
let (xdebug_expr_of_string: string -> Ast_php.expr) = fun s ->
(*
  let lexbuf = Lexing.from_string s in
  let expr = Parser_php.expr basic_lexer_skip_comments lexbuf in
  expr
*)
  raise Todo

(* The default PHP parser function stores position information for all tokens,
 * build some Parse_php.info_items for each toplevel entities, and
 * do other things which are most of the time useful for some analysis
 * but starts to really slow down parsing for huge (generated) PHP files.
 * Enters parse_fast() that disables most of those things.
 * Note that it may not parse correctly all PHP code, so use with
 * caution.
 *)
let parse_fast file =
  let chan = open_in file in
  let lexbuf = Lexing.from_channel chan in
  Lexer_php.reset();
  Lexer_php._mode_stack := [Lexer_php.INITIAL];

  let rec php_next_token lexbuf = 
    let tok =
    (* for yyless emulation *)
    match !Lexer_php._pending_tokens with
    | x::xs -> 
      Lexer_php._pending_tokens := xs; 
      x
    | [] ->
      (match Lexer_php.current_mode () with
      | Lexer_php.INITIAL -> 
        Lexer_php.initial lexbuf
      | Lexer_php.ST_IN_SCRIPTING -> 
        Lexer_php.st_in_scripting lexbuf
      | Lexer_php.ST_IN_SCRIPTING2 -> 
        Lexer_php.st_in_scripting lexbuf
      | Lexer_php.ST_DOUBLE_QUOTES -> 
        Lexer_php.st_double_quotes lexbuf
      | Lexer_php.ST_BACKQUOTE -> 
        Lexer_php.st_backquote lexbuf
      | Lexer_php.ST_LOOKING_FOR_PROPERTY -> 
        Lexer_php.st_looking_for_property lexbuf
      | Lexer_php.ST_LOOKING_FOR_VARNAME -> 
        Lexer_php.st_looking_for_varname lexbuf
      | Lexer_php.ST_VAR_OFFSET -> 
        Lexer_php.st_var_offset lexbuf
      | Lexer_php.ST_START_HEREDOC s ->
        Lexer_php.st_start_heredoc s lexbuf
      | Lexer_php.ST_START_NOWDOC s ->
        Lexer_php.st_start_nowdoc s lexbuf
      | Lexer_php.ST_IN_XHP_TAG current_tag ->
        Lexer_php.st_in_xhp_tag current_tag lexbuf
      | Lexer_php.ST_IN_XHP_TEXT current_tag ->
        Lexer_php.st_in_xhp_text current_tag lexbuf
      )
    in
    match tok with
    | Parser_php.T_COMMENT _ | Parser_php.T_DOC_COMMENT _
    | Parser_php.TSpaces _ | Parser_php.TNewline _
    | Parser_php.TCommentPP _
    | Parser_php.T_OPEN_TAG _
    | Parser_php.T_CLOSE_TAG _ ->
       php_next_token lexbuf
    | _ -> tok
  in
  try 
    let res = Parser_php.main php_next_token lexbuf in
    close_in chan;
    res
  with Parsing.Parse_error ->
    pr2 (spf "parsing error in php fast parser: %s" 
           (Lexing.lexeme lexbuf));
    raise Parsing.Parse_error

(*****************************************************************************)
(* Fuzzy parsing *)
(*****************************************************************************)

(* todo: factorize with parse_ml.ml, put in matcher/lib_fuzzy_parser.ml? *)

let is_lbrace = function
  | T.TOBRACE _ -> true  | _ -> false
let is_rbrace = function
  | T.TCBRACE _ -> true  | _ -> false

let is_lparen = function
  | T.TOPAR _ -> true  | _ -> false
let is_rparen = function
  | T.TCPAR _ -> true  | _ -> false


let tokf tok =
  TH.info_of_tok tok

(* 
 * less: check that it's consistent with the indentation? 
 * less: more fault tolerance? if col == 0 and { then reset?
 * 
 * Assumes work on a list of tokens without comments.
 * 
 * todo: make this mode independent of ocaml so that we can reuse
 * this code for other languages. I should also factorize with
 * Parse_cpp.parse_fuzzy.
 *)
let mk_trees xs =

  let rec consume x xs =
    match x with
    | tok when is_lbrace tok -> 
        let body, closing, rest = look_close_brace x [] xs in
        Ast_fuzzy.Braces (tokf x, body, tokf closing), rest
    | tok when is_lparen tok ->
        let body, closing, rest = look_close_paren x [] xs in
        let body' = split_comma body in
        Ast_fuzzy.Parens (tokf x, body', tokf closing), rest
    | tok -> 
      Ast_fuzzy.Tok (TH.str_of_tok tok, tokf x), xs
(*
    (match Ast.str_of_info (tokext tok) with
    | "..." -> Ast_fuzzy.Dots (tokext tok)
    | s when Ast_fuzzy.is_metavar s -> Ast_fuzzy.Metavar (s, tokext tok)
    | s -> Ast_fuzzy.Tok (s, tokext tok)
*)
  
  and aux xs =
  match xs with
  | [] -> []
  | x::xs ->
      let x', xs' = consume x xs in
      x'::aux xs'

  and look_close_brace tok_start accbody xs =
    match xs with
    | [] -> 
        failwith (spf "PB look_close_brace (started at %d)" 
                    (TH.line_of_tok tok_start))
    | x::xs -> 
        (match x with
        | tok when is_rbrace tok-> 
          List.rev accbody, x, xs

        | _ -> let (x', xs') = consume x xs in
               look_close_brace tok_start (x'::accbody) xs'
        )

  and look_close_paren tok_start accbody xs =
    match xs with
    | [] -> 
        failwith (spf "PB look_close_paren (started at %d)" 
                     (TH.line_of_tok tok_start))
    | x::xs -> 
        (match x with
        | tok when is_rparen tok -> 
            List.rev accbody, x, xs
        | _ -> 
            let (x', xs') = consume x xs in
            look_close_paren tok_start (x'::accbody) xs'
        )

  and split_comma xs =
     let rec aux acc xs =
       match xs with
       | [] ->
         if null acc
         then []
         else [Left (acc +> List.rev)]
       | x::xs ->
         (match x with
         | Ast_fuzzy.Tok (",", info) ->
           let before = acc +> List.rev in
           if null before
           then aux [] xs
           else (Left before)::(Right (info))::aux [] xs
         | _ ->
           aux (x::acc) xs
         )
     in
     aux [] xs
  in
  aux xs

(* This is similar to what I did for OPA. This is also similar
 * to what I do for parsing hacks forC++, but this fuzzy AST can be useful
 * on its own, e.g. for a not too bad sgrep/spatch.
 *)
let parse_fuzzy file =
  let toks_orig = tokens file in
  let toks = 
    toks_orig +> Common.exclude (fun x ->
      Token_helpers_php.is_comment x ||
      Token_helpers_php.is_eof x
    )
  in
  let trees = mk_trees toks in
  trees, toks_orig

(*e: parse_php.ml *)
