(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(* This file defines a set of rules that can be used to
   generating programs. This serves as a sample ruleset
   which demonstrates how to use the engine to generate
   programs that exposes type rule unsoundness
*)

module S = Ast.Statement;;
module E = Ast.Expression;;
module T = Ast.Type;;
module P = Ast.Pattern;;
module Utils = Flowtestgen_utils;;
module FRandom = Utils.FRandom;;

(* ESSENTIAL: Syntax type and related functions *)
module Syntax = Syntax_base;;


(* ESSENTIAL: environment type and its element type. *)
type env_elt_t =
  | Expr of Loc.t E.t' * Loc.t T.t'
  | Type of Loc.t T.t'
  | Int of int
type env_t = env_elt_t list

(* string of functions *)
let str_of_env_elt (elt : env_elt_t) : string = match elt with
  | Expr (e, t) ->
    Printf.sprintf
      "%s : %s"
      (Utils.string_of_expr e)
      (Utils.string_of_type t)
  | Type t ->
    Printf.sprintf
      "%s"
      (Utils.string_of_type t)
  | Int i -> string_of_int i

let str_of_env (env : env_t) : string =
  "\n/*\nEnv:\n" ^
  (List.fold_left (fun acc e -> (str_of_env_elt e) ^ "\n" ^ acc) "" env) ^
  "*/\n\n"

let print_env (env : env_t) : unit =
  Printf.printf "%s\n" (str_of_env env)

(* This is a sample ruleset that has unsound type rules.
   This also serves as an example to use the engine for generating
   code using the framework.

   Depth is used to control the level of recursion when we generate
   body for inner statements such as function definitions. This might
   change in the future when we have better strategy.
 *)
class ruleset_base = object(self)


  (* ESSENTIAL: Users have to inherit from the engine type and
     implement the get_all_rules method *)
  inherit [env_elt_t, env_t, Syntax.t] Engine.engine

  method print_stack () : unit =
    Printf.printf "Stack: ============\n";
    for i = size - 1 downto 0 do
      List.iter (fun elt -> Printf.printf "%s\t" (str_of_env_elt elt)) stack.(i);
      Printf.printf "\n----------------\n";
    done

  method print_env (env : env_t) : unit = print_env env

  method print_syntax (s : Syntax.t) : unit = Printf.printf "%s\n" (Syntax.str_of_syntax s)

  (* We have a small chance to bypass this assertion *)
  method weak_assert b =
    if (not b) && ((FRandom.rint 20) > 0) then raise Engine.Fail

  (* check t1 <: t2 *)
  method is_subtype (t1 : Loc.t T.t') (t2 : Loc.t T.t') : bool =
    match t1, t2 with
    | (T.Union ((_, tu1), (_, tu2), tlist), t) ->
      List.mem t (tu1 :: tu2 :: (List.map snd tlist))
    | T.Object o1, T.Object o2 -> self#is_subtype_obj o1 o2
    | T.Function f1, T.Function f2 -> self#is_subtype_func f1 f2
    | _ when t1 = t2 -> true
    | _ -> false

  method is_subtype_func
      (f1 : Loc.t T.Function.t)
      (f2 : Loc.t T.Function.t) : bool =
    let open T.Function in
    let get_type_list (f : Loc.t T.Function.t) : Loc.t T.t' list =
      let open T.Function.Param in
      let (_, { T.Function.Params.params; rest = _ }) = f.params in
      List.map
        (fun param -> (snd param).typeAnnotation |> snd)
        params @ [f.returnType |> snd] in

    let rec func_subtype_helper l1 l2 = match l1, l2 with
      | [], [] -> true
      (* checking the return type *)
      | hd1 :: [], hd2 :: [] -> self#is_subtype hd1 hd2
      (* checking the param type *)
      | hd1 :: tl1, hd2 :: tl2 ->
      if self#is_subtype hd2 hd1 then
        func_subtype_helper tl1 tl2
      else
        false
      | _ -> false in

    let p1_list = get_type_list f1 in
    let p2_list = get_type_list f2 in
    if (not ((List.length p1_list) = (List.length p2_list))) then false
    else func_subtype_helper p1_list p2_list

  method is_subtype_obj (o1 : Loc.t T.Object.t) (o2 : Loc.t T.Object.t) =
    let get_prop_set (o : Loc.t T.Object.t) =
      let tbl = Hashtbl.create 1000 in

      (* hash table for storing optional properties *)
      let opt_tbl = Hashtbl.create 1000 in
      let open T.Object.Property in
      List.iter (fun p -> match p with
          | T.Object.Property (_, {key = E.Object.Property.Identifier (_, name);
                                   value = Init (_, t);
                                   optional = o;
                                   static = _;
                                   _method = _;
                                   variance = _;}) ->
            if o then Hashtbl.add opt_tbl name t
            else Hashtbl.add tbl name t
          | _ -> ()) T.Object.(o.properties);
      tbl, opt_tbl in
    let s1, opt1 = get_prop_set o1 in
    let s2, opt2 = get_prop_set o2 in
    let subtype = ref true in
    (* check non optional properties *)
    Hashtbl.iter (fun n t ->
      if (not (Hashtbl.mem s1 n)) || (not ((Hashtbl.find s1 n) = t)) then
          subtype := false) s2;

    (* check optional properties *)
    Hashtbl.iter (fun n t ->
        if (((Hashtbl.mem s1 n) && ((Hashtbl.find s1 n) != t)) ||
            ((Hashtbl.mem opt1 n) && ((Hashtbl.find opt1 n) != t)))
        then subtype := false) opt2;
    !subtype

  (* A user custom function for populating the env. *)
  method add_binding
      (env : env_t)
      (elt : env_elt_t) : env_t =

    let rec helper lst acc = match lst with
      | [] -> List.rev (elt :: acc)
      | hd :: tl -> (match elt, hd with
          | Type t1, Type t2 when t1 = t2 -> lst @ acc
          | Expr (e1, t1), Expr (e2, _) when e1 = e2 ->
            ((Expr (e1, t1) :: tl)) @ acc
          | _ -> helper tl (hd :: acc)) in
    helper env []

  (* get the type of an expression from the environment assuming
     we have the expression *)
  method get_type_from_expr
      (expr : Loc.t E.t')
      (env : env_t) : Loc.t T.t' =
    let rec helper lst = match lst with
      | [] -> raise Not_found
      | Expr (e, t) :: _ when expr = e -> t
      | _ :: tl -> helper tl in
    helper env

  (* Some require functions for checking preconditions
     and getting things from the environment *)
  method require_expr (env : env_t) : env_elt_t list =
    List.fold_right (fun elt acc -> match elt with
        | Expr _ -> elt :: acc
        | _ -> acc) env []

  method require_var (env : env_t) : env_elt_t list =
    List.fold_right (fun elt acc -> match elt with
        | Expr (E.Identifier _, _) -> elt :: acc
        | _ -> acc) env []

  method require_type (env : env_t) : env_elt_t list =
    List.fold_right (fun elt acc -> match elt with
        | Type _ -> elt :: acc
        | _ -> acc) env []

  (* Requiring the object has some properties *)
  method require_prop (ot : Loc.t T.t') (take_opt : bool): env_elt_t list =
    let open T.Object.Property in
    let props = match ot with
      | T.Object o ->
        List.fold_right (fun p acc -> match p with
            | T.Object.Property (_, {key = E.Object.Property.Identifier (_, name);
                                     value = Init (_, t);
                                     optional = o;
                                     static = _;
                                     _method = _;
                                     variance = _;}) ->
              if take_opt || (not o) then
                Expr (E.Identifier (Loc.none, name), t) :: acc
              else
                acc
            | _ -> failwith "Unsupported property") T.Object.(o.properties) []
      | _ -> failwith "Input type is not an object type" in
      props

  (* ESSENTIAL: rules *)
  (* Property read rule *)
  method rule_prop_read (env : env_t) : (Syntax.t * env_t) =
    (* we require we have an object *)
    let obj = self#choose 0 (fun () -> self#require_expr env) in
    self#backtrack_on_false (match obj with
        (* we ensure we are getting an object variable *)
        | Expr (E.Identifier _, T.Object _) -> true
        | _ -> false);
    let oexpr, otype = match obj with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    let prop = self#choose 1 (fun () -> self#require_prop otype false) in
    let pexpr, ptype = match prop with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    let read =
      Syntax.mk_prop_read (Utils.string_of_expr oexpr) (Utils.string_of_expr pexpr) in

    let ret_type = ptype in
    let new_env =
      self#add_binding
        env
        (match read with
         | Syntax.Expr e -> Expr (e, ret_type)
         | _ -> failwith "has to be an expr") in
    let new_env =
      self#add_binding new_env (Type ret_type) in
    (read, new_env)

  (* property update rule *)
  method rule_prop_update (env : env_t) : (Syntax.t * env_t) =
    (* get an object variable *)
    let obj = self#choose 0 (fun () -> self#require_expr env) in
    self#backtrack_on_false (match obj with
        | Expr (E.Identifier _, T.Object _) -> true
        | _ -> false);
    let oexpr, otype = match obj with
      | Expr (e, t) -> e, t
      | _ -> failwith "This has to be an expression" in

    let prop = self#choose 1 (fun () -> self#require_prop otype true) in
    let pexpr, ptype = match prop with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* get the expression on the rhs of the update *)
    let rhs = self#choose 2 (fun () -> self#require_expr env) in
    let rhs_expr, rhs_type = match rhs with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* assert that type(rhs) <: type(prop) *)
    self#weak_assert (self#is_subtype rhs_type ptype);

    (* produce a write syntax *)
    let write =
      Syntax.mk_prop_write
        (Utils.string_of_expr oexpr)
        (Utils.string_of_expr pexpr)
        rhs_expr in

    (* update the type of the object *)
    let ret_type =
      let o_type = match otype with
        | T.Object o -> o
        | _ -> failwith "Has to be an object type" in
      if pexpr = E.Identifier (Loc.none, "_number_prop_") then
        let new_prop = let open T.Object.Property in
          {key = E.Object.Property.Identifier (Loc.none, (Utils.string_of_expr pexpr));
           value = Init (Loc.none, T.Number);
           optional = false;
           static = false;
           _method = false;
           variance = None} in
        let open T.Object in
        T.Object {exact = o_type.exact;
                  properties = Property (Loc.none, new_prop) :: o_type.properties}
      else
        T.Object o_type in
    Printf.printf "[prop_update]       putting %s : %s\n" (Utils.string_of_expr oexpr) (Utils.string_of_type ret_type);

    let new_env = self#add_binding env (Expr (oexpr, ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    (write, new_env)

  (* rule for variable declaration with initialization *)
  method rule_vardecl (env : env_t) : (Syntax.t * env_t) =
    (* get the init expression *)
    let init = self#choose 0 (fun () -> self#require_expr env) in
    let init_expr, init_type = match init with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    let vname = Utils.mk_var () in
    let var_decl = Syntax.mk_vardecl vname init_expr in
    let new_env =
      self#add_binding
        env
        (Expr ((E.Identifier (Loc.none, vname)), init_type)) in
    let new_env = self#add_binding new_env (Type init_type) in
    var_decl, new_env


  (* Rule for declaring a variable with init and type annotation *)
  method rule_vardecl_with_type (env : env_t) : (Syntax.t * env_t) =
    (* require an expression from the environment *)
    let rhs = self#choose 0 (fun () -> self#require_expr env) in
    let rhs_expr, rhs_type = match rhs with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* require a type from the environment.*)
    let vtype = self#choose 1 (fun () -> self#require_type env) in
    let vtype = match vtype with
      | Type t -> t
      | _ -> failwith "This has to a type" in

    (* assert the subtyping relationhips between the rhs and lhs *)
    self#weak_assert (self#is_subtype rhs_type vtype);
    let vname = Utils.mk_var () in
    let var_decl = Syntax.mk_vardecl ~etype:vtype vname rhs_expr in
    let new_env =
      self#add_binding
        env
        (Expr ((E.Identifier (Loc.none, vname)), vtype)) in
    let new_env = self#add_binding new_env (Type vtype) in
    var_decl, new_env

  (* A rule for generating object literals *)
  method rule_obj_lit (env : env_t) : (Syntax.t * env_t) =

    (* a helper function for generating expression for object
       properties *)
    let rec gen_expr_list
        (count : int)
        (limit : int)
        (result : (Loc.t E.t' * Loc.t T.t') list) : (Loc.t E.t' * Loc.t T.t') list =
      if count = limit then result
      else
        let expr = self#choose count (fun () -> self#require_expr env) in
        let ep = match expr with
          | Expr (e, t) -> (e, t)
          | _ -> failwith "This has to be an expression" in
        gen_expr_list (count + 1) limit (ep :: result) in

    (* We are getting at most 2 properties *)
    let elist = gen_expr_list 0 ((FRandom.rint 2) + 1) [] in
    let props =
      let count = ref 0 in
      let mk_prop () =
        let r = "p_" ^ (string_of_int !count) in
        count := !count + 1;
        r in
      List.map (fun e -> mk_prop (), e) elist in

    (* get the literal syntax and its type *)
    let lit = Syntax.mk_obj_lit props in
    let lit_expr = (match lit with
         | Syntax.Expr e -> e
         | _ -> failwith "[rule_obj_lit] Literal has to be an expr") in
    let ret_type =
      let prop_types =
        List.map (fun e ->
            let open T.Object.Property in
            T.Object.Property (Loc.none, {key = E.Object.Property.Identifier (Loc.none, fst e);
                                          value = Init (Loc.none, snd (snd e));
                                          optional = false;
                                          static = false;
                                          _method = false;
                                          variance = None})) props in
      let open T.Object in
      T.Object {exact = false; properties = prop_types} in

    let new_env =
      self#add_binding
        env
        (Expr (lit_expr, ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    Syntax.Empty, new_env

  (* A rule for generating number literals *)
  method rule_num_lit (env : env_t) : (Syntax.t * env_t) =
    let lit = Syntax.mk_literal T.Number in
    let ret_type = T.Number in
    let new_env =
      self#add_binding
        env
        (Expr ((match lit with
         | Syntax.Expr e -> e
         | _ -> failwith "[rule_num_list] Literal has to be an expr"),
        ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    Syntax.Empty, new_env

  (* A rule for generating number literals *)
  method rule_str_lit (env : env_t) : (Syntax.t * env_t) =
    let lit = Syntax.mk_literal T.String in
    let ret_type = T.String in
    let new_env =
      self#add_binding
        env
        (Expr ((match lit with
         | Syntax.Expr e -> e
         | _ -> failwith "Literal has to be an expr"),
        ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    Syntax.Empty, new_env

  (* A rule for generating function definitions *)
  method rule_funcdef (env : env_t) : (Syntax.t * env_t) =
    let mk_func_type (ptype : Loc.t T.t') (rtype : Loc.t T.t') : Loc.t T.t' =
      let param_type =
        (Loc.none, T.Function.Param.({name = None;
                                      typeAnnotation = (Loc.none, ptype);
                                      optional = false})) in
      let ret_type = (Loc.none, rtype) in

      T.Function.(T.Function {params = (Loc.none, { Params.params = [param_type]; rest = None });
                              returnType = ret_type;
                              typeParameters = None}) in

    (* parameter type *)
    let param_type =
      match self#choose 0 (fun () -> self#require_type env) with
      | Type t -> t
      | _ -> failwith "has to be a type" in

    (* We are assuming we only have one parameter for now *)
    let pname = "param" in

    (* We don't support recursion at this point, since in the syntax
       there's no way to stop recursion *)
    let fenv = (Expr (E.Identifier (Loc.none, pname), param_type)) :: env in

    (* return expression and its type *)
    let func_return_type =
      match self#choose 1 (fun () -> self#require_type fenv) with
      | Type t -> t
      | _ -> failwith "Has to be a type" in
    self#backtrack_on_false (match func_return_type with
        | T.Object _ -> true
        | _ -> false);

    let fname = Utils.mk_func () in

    (* This is the code for building function body recursively, but
       we are not doing it at the moment *)
    (*
    let body, _ = if (FRandom.rint 10) > 7 then begin
        let new_engine = new ruleset_base (depth + 1) in
        new_engine#gen_prog fenv 2
      end else [], fenv in
       *)


    (* return expression and its type *)
    let ret_expr = self#choose 2 (fun () -> self#require_expr fenv) in
    let ret_expr_expr, ret_expr_type = match ret_expr with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in
    self#backtrack_on_false (self#is_subtype ret_expr_type func_return_type);
    let ret_stmt = Syntax.mk_ret_stmt ret_expr_expr in

    let func_def =
      Syntax.mk_func_def
        fname
        pname
        param_type
        [ret_stmt]
        func_return_type in

    let ret_type = mk_func_type param_type func_return_type in
    let new_env =
      self#add_binding
        env
        (Expr ((E.Identifier (Loc.none, fname)), ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    func_def, new_env

  (* A rule for generating function definitions *)
  method rule_func_mutate (env : env_t) : (Syntax.t * env_t) =
    let mk_func_type (ptype : Loc.t T.t') (rtype : Loc.t T.t') : Loc.t T.t' =
      let param_type =
        (Loc.none, T.Function.Param.({name = None;
                                      typeAnnotation = (Loc.none, ptype);
                                      optional = false})) in
      let ret_type = (Loc.none, rtype) in

      T.Function.(T.Function {params = (Loc.none, { Params.params = [param_type]; rest = None });
                              returnType = ret_type;
                              typeParameters = None}) in

    (* parameter type *)
    let param_type =
      match self#choose 0 (fun () -> self#require_type env) with
      | Type t -> t
      | _ -> failwith "has to be a type" in

    (* We need to ensure the parameter is an object for mutation *)
    self#backtrack_on_false (match param_type with
        | T.Object _ -> true
        | _ -> false);

    (* We are assuming we only have one parameter for now *)
    let pname = "param" in

    let prop = self#choose 1 (fun () -> self#require_prop param_type true) in
    let pexpr, ptype = match prop with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* get the expression on the rhs of the update *)
    let rhs = self#choose 2 (fun () -> self#require_expr env) in
    let rhs_expr, rhs_type = match rhs with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in

    (* assert that type(rhs) <: type(prop) *)
    self#weak_assert (self#is_subtype rhs_type ptype);

    (* produce a write syntax *)
    let write =
      Syntax.mk_prop_write
        (Utils.string_of_expr (E.Identifier (Loc.none, pname)))
        (Utils.string_of_expr pexpr)
        rhs_expr in

    (* return expression and its type *)
    let func_return_type = T.Void in

    let fname = Utils.mk_func () in

    let func_def =
      Syntax.mk_func_def
        fname
        pname
        param_type
        [write]
        func_return_type in

    let ret_type = mk_func_type param_type func_return_type in
    let new_env =
      self#add_binding
        env
        (Expr ((E.Identifier (Loc.none, fname)), ret_type)) in
    let new_env = self#add_binding new_env (Type ret_type) in
    func_def, new_env

  (* A rule for generating function calls *)
  method rule_func_call (env : env_t) : (Syntax.t * env_t) =
    (* require a function from the environment.*)
    let func = self#choose 0 (fun () -> self#require_expr env) in
    let func_expr, func_type = match func with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in
    self#backtrack_on_false (match func_type with
        | T.Function _ -> true
        | _ -> false);

    (* get the type of the parameter assuming we only have one param *)
    let f_ptype =
      let open T.Function in
      match func_type with
      | T.Function {params = (_, { Params.params = plist; rest = _ });
                    returnType = _;
                    typeParameters = _} ->
        T.Function.Param.((plist |> List.hd |> snd).typeAnnotation)
      | _ -> failwith "This has to a function type" in

    (* parameter *)
    let param = self#choose 1 (fun () -> self#require_expr env) in
    let param_expr, param_type = match param with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in
    self#weak_assert (self#is_subtype param_type (snd f_ptype));

    let func_call = Syntax.mk_func_call func_expr param_expr in

    let ret_type = T.Function.(match func_type with
        | T.Function {params = _;
                      returnType = (_, rt);
                      typeParameters =_} -> rt
        | _ -> failwith "This has to be a function type") in
    let new_env =
      self#add_binding
        env
        (Expr ((match func_call with
             | Syntax.Expr e -> e
             | _ -> failwith "This has to be an expression"),
               ret_type)) in

    let new_env = self#add_binding new_env (Type ret_type) in
    func_call, new_env

  (* A rule for adding primitive types *)
  method rule_prim_type (env : env_t) : (Syntax.t * env_t) =
    let new_env =
      self#add_binding
        (self#add_binding env (Type T.Number))
        (Type T.String) in
    Syntax.Empty, new_env

  (* A rule for adding object types *)
  method rule_obj_type (env : env_t) : (Syntax.t * env_t) =
    (* a helper function for generating object property types *)
    let rec gen_type_list
        (count : int)
        (limit : int)
        (result : Loc.t T.t' list) : Loc.t T.t' list =
      if count = limit then result
      else
        let ptype = self#choose count (fun () -> self#require_type env) in
        let ptype = match ptype with
          | Type t -> t
          | _ -> failwith "This has to be a type" in
        gen_type_list (count + 1) limit (ptype :: result) in

    let prop_types = gen_type_list 0 ((FRandom.rint 2) + 1) [] in
    let props =
      let count = ref 0 in
      let mk_prop () =
        let r = "p_" ^ (string_of_int !count) in
        count := !count + 1;
        r in
      List.map (fun t -> mk_prop (), t) prop_types in

    let ret_type =
      let prop_types =
        List.map (fun p ->
            let open T.Object.Property in
            T.Object.Property (Loc.none, {key = E.Object.Property.Identifier (Loc.none, fst p);
                                          value = Init (Loc.none, snd p);
                                          optional = FRandom.rbool ();
                                          static = false;
                                          _method = false;
                                          variance = None})) props in
      let open T.Object in
      T.Object {exact = false; properties = prop_types} in
    let new_env =
      self#add_binding env (Type ret_type) in
    Syntax.Empty, new_env

  (* A rule for adding function types *)
  method rule_func_type (env : env_t) : (Syntax.t * env_t) =
    (* parameter type *)
    let param_type =
      match self#choose 0 (fun () -> self#require_type env) with
      | Type t -> t
      | _ -> failwith "has to be a type" in

    (* return expression and its type *)
    let func_ret_type =
      match self#choose 1 (fun () -> self#require_type env) with
      | Type t -> t
      | _ -> failwith "Has to be a type" in

    let ret_type =
      let param = T.Function.Param.({name = None;
                                     typeAnnotation = (Loc.none, param_type);
                                     optional = false}) in
      T.Function.(T.Function {
        params = (Loc.none, { Params.
          params = [(Loc.none, param)];
          rest = None;
        });
        returnType = (Loc.none, func_ret_type);
        typeParameters = None;
      }) in
    let new_env =
      self#add_binding env (Type ret_type) in
    Syntax.Empty, new_env

  (* A rule for adding primitive types *)
  method rule_union_type (env : env_t) : (Syntax.t * env_t) =
    (* a helper function for generating object property types *)
    let rec gen_type_list
        (count : int)
        (limit : int)
        (result : Loc.t T.t' list) : Loc.t T.t' list =
      if count = limit then result
      else
        let ptype = self#choose count (fun () -> self#require_type env) in
        let ptype = match ptype with
          | Type t -> t
          | _ -> failwith "This has to be a type" in

        gen_type_list (count + 1) limit (ptype :: result) in

    let ret_type =
      let open Array in
      let tarray = (gen_type_list 0 ((FRandom.rint 1) + 2) []) |> of_list in
      T.Union ((Loc.none, get tarray 0),
               (Loc.none, get tarray 1),
               (List.map
                  (fun (s) -> (Loc.none, s))
                  (to_list (sub tarray 2 ((length tarray) - 2))))) in
    let new_env =
      self#add_binding env (Type ret_type) in
    Syntax.Empty, new_env

  (* A rule for adding runtime checks *)
  method rule_runtime_check (env : env_t) : (Syntax.t * env_t) =
    let mk_prop_read (obj : Loc.t E.t') (prop : Loc.t E.t') : Loc.t E.t' =
      let open E.Member in
      E.Member {_object = (Loc.none, obj);
                property = PropertyExpression (Loc.none, prop);
                computed = false} in

    let rec get_prop (oname : Loc.t E.t') (ot : Loc.t T.Object.t) (depth : int) : env_elt_t =
      let prop = self#choose depth (fun () -> self#require_prop (T.Object ot) true) in
      let pexpr, ptype = match prop with
        | Expr (e, t) -> e, t
        | _ -> failwith "This has to be an expression" in
      let prop_elt = match ptype with
      | T.Object t -> get_prop pexpr t (depth + 1)
      | _ -> Expr (pexpr, ptype) in
      match prop_elt with
      | Expr (e, t) -> Expr (mk_prop_read oname e, t)
      | _ -> failwith "This has to be an expression." in

    let var = self#choose 0 (fun () -> self#require_var env) in
    let vexpr, vtype = match var with
      | Expr (e, t) -> e, t
      | _ -> failwith "This has to be an expression." in
    self#backtrack_on_false (match vtype with
        | T.Function _ -> false
        | T.Union _ -> false
        | _ -> true);

    let final_expr = match vtype with
      | T.Object ot -> get_prop vexpr ot 1
      | _ -> var in
    let fexpr, ftype = match final_expr with
      | Expr (e, t) -> e, t
      | _ -> failwith "This has to be an expression." in
    self#backtrack_on_false (match ftype with
        | T.Function _ -> false
        | T.Union _ -> false
        | _ -> true);

    Syntax.mk_runtime_check fexpr ftype, env

  method get_all_rules () =
    let all_rules = [|self#rule_num_lit;
                      self#rule_str_lit;
                      self#rule_obj_lit;
                      self#rule_obj_type;
                      self#rule_vardecl;
                      self#rule_vardecl_with_type;
                      self#rule_func_type;
                      self#rule_union_type;
                      self#rule_prim_type;
                      self#rule_funcdef;
                      self#rule_func_call;
                      self#rule_prop_read;
                      self#rule_prop_update;|] in
    all_rules
end;;

class ruleset_random_base = object
  inherit ruleset_base
  method! weak_assert b =
    if (not b) && ((FRandom.rint 20) > 0) then raise Engine.Fail
end
