open L

(* Types and exceptions *)

module HoleCoeffs = struct
  type t = int list

  let zero len = List.init len (fun _ -> 0)

  (* let is_zero hole_coeffs =
   *   List.find_opt (( <> ) 0) hole_coeffs |> Option.is_none *)

  (** TODO: Implement *)
  let can_be_zero _ = true

  (** TODO: Implement *)
  let can_be_nonzero _ = true

  let rec make ~index ~k ~hole_cnt =
    assert (index >= 0 && hole_cnt >= 0 && index <= hole_cnt);
    if index = 0 then k :: zero hole_cnt
    else 0 :: make ~index:(index - 1) ~k ~hole_cnt:(hole_cnt - 1)

  let length = List.length

  let ( +! ) h1 h2 =
    let open Monads.List in
    let+ k1 = h1 and+ k2 = h2 in
    k1 + k2

  let ( ~-! ) h =
    let open Monads.List in
    let+ k = h in
    -k
end

type value =
  | VNum of HoleCoeffs.t
  | VPair of value * value

let rec value_of_plain_value v ~hole_cnt =
  match v with
  | `Num n -> VNum HoleCoeffs.(make ~index:0 ~k:n ~hole_cnt)
  | `Pair (h1, h2) ->
      VPair
        (value_of_plain_value h1 ~hole_cnt, value_of_plain_value h2 ~hole_cnt)

let failTypeVariableFound () =
  failwith "hole_type contains a type variable: This is a programming error!"

(** Count the number of the leaves in the hole type inferred by Shape_analyzer *)
let rec count_holes : Shape_analyzer.ty -> number = function
  | TyInt | TyVar _ -> 1
  | TyPair (t1, t2) -> count_holes t1 + count_holes t2

(** Convert the type of the hole inferred by Shape_analyzer into value. *)
let value_of_hole_type (t : Shape_analyzer.ty) : value =
  let hole_cnt = count_holes t in
  let hole_id = ref 0 in

  let open Shape_analyzer in
  let rec inner = function
    | TyInt ->
        incr hole_id;
        VNum (HoleCoeffs.make ~index:!hole_id ~k:1 ~hole_cnt)
    | TyVar _ ->
        incr hole_id;
        VNum (HoleCoeffs.make ~index:!hole_id ~k:987654321 ~hole_cnt)
    | TyPair (t1, t2) -> VPair (inner t1, inner t2)
  in
  inner t

let rec string_of_value = function
  | VNum hole_coeffs -> (
      match hole_coeffs with
      | [] -> failwith "Empty HoleCoeffs: This is a programming error!"
      | [ n ] -> string_of_int n
      | n :: ks ->
          string_of_int n
          ^
          let rec string_of index = function
            | [] -> ""
            | k :: ks when k <> 0 ->
                " + "
                ^ (if k <> 1 then string_of_int k else "")
                ^ "[" ^ string_of_int index ^ "]"
                ^ if ks <> [] then " + " ^ string_of (index + 1) ks else ""
            | _ :: ks -> string_of (index + 1) ks
          in
          string_of 1 ks)
  | VPair (h1, h2) -> "(" ^ string_of_value h1 ^ ", " ^ string_of_value h2 ^ ")"

type id = string
type env = id -> value

(* type comp_op =
 *   | Eq (\* =0 *\)
 *   | Ne (\* ≠0 *\)
 *   | Lt (\* <0 *\)
 *   | Gt (\* >0 *\)
 *   | Le (\* ≤0 *\)
 *   | Ge (\* ≥0 *\)
 * 
 * type cond_eqn = HoleCoeffs.t * comp_op *)

exception TypeError of string
exception RunError of string

exception PathError of string
(** Use PathError when the path guided by Shape_analyzer is impossible *)

let raiseTypeError expected op =
  let expected, current =
    let n, p = ("number", "pair") in
    match expected with `Num -> (n, p) | `Pair -> (p, n)
  in
  let msg = Printf.sprintf "%s: %s expected, not a %s" op expected current in
  raise (TypeError msg)

let empty_env (_ : id) : value = raise (RunError "undefined variable")

(** Environment augmentation. Use @: to bind (x, v) to f *)
let ( @: ) (x, v) e y = if y = x then v else e y

let eval env expr guide_path hole_type =
  let hole = value_of_hole_type hole_type in
  let hole_cnt = count_holes hole_type in

  let rec inner env expr (guide_path : Path.path) =
    match (expr, guide_path) with
    | Hole, PtNil -> hole
    | Num n, PtNil -> VNum HoleCoeffs.(make ~index:0 ~k:n ~hole_cnt)
    | Pair (e1, e2), PtPair (p1, p2) ->
        let v1 = inner env e1 p1 in
        let v2 = inner env e2 p2 in
        VPair (v1, v2)
    | Fst e, p -> (
        match inner env e p with
        | VPair (fst, _) -> fst
        | VNum _ -> raiseTypeError `Pair "FIRST")
    | Snd e, p -> (
        match inner env e p with
        | VPair (_, snd) -> snd
        | VNum _ -> raiseTypeError `Pair "SECOND")
    | Add (e1, e2), PtAdd (p1, p2) -> (
        match inner env e1 p1 with
        | VNum lhs_n -> (
            match inner env e2 p2 with
            | VNum rhs_n -> VNum HoleCoeffs.(lhs_n +! rhs_n)
            | VPair _ -> raiseTypeError `Num "ADD")
        | VPair _ -> raiseTypeError `Num "ADD")
    | Neg e, p -> (
        match inner env e p with
        | VNum n -> VNum HoleCoeffs.(~-!n)
        | VPair _ -> raiseTypeError `Num "NEGATE")
    | Case (x, y, z, e1, _), PtCaseP (x_p_p, e1_p) -> (
        let v = inner env x x_p_p in
        match v with
        | VPair (v1, v2) ->
            let env' = (y, v1) @: (z, v2) @: env in
            inner env' e1 e1_p
        | VNum _ ->
            failwith
              "VNum found when guide_path expected VPair: This is a \
               programming error. 'Well typed' program cannot go wrong!")
    | Case (x, _, _, _, e2), PtCaseN (x_n_p, e2_p) -> (
        let v = inner env x x_n_p in
        match v with
        | VPair _ ->
            failwith
              "VPair found when guide_path expected VNum: This is a \
               programming error. 'Well typed' program cannot go wrong!"
        | VNum _ -> inner env e2 e2_p)
    | If (pred, true_e, _), PtIfTru (e_p_p, e_t_p) -> (
        let v = inner env pred e_p_p in
        match v with
        | VNum n when HoleCoeffs.can_be_nonzero n -> inner env true_e e_t_p
        | VNum _ ->
            raise
              (PathError
                 "Falsy value found when guide_path expected a truthy value")
        | VPair _ -> raiseTypeError `Num "IF")
    | If (pred, _, false_e), PtIfFls (e_p_p, e_f_p) -> (
        let v = inner env pred e_p_p in
        match v with
        | VNum n when HoleCoeffs.can_be_zero n -> inner env false_e e_f_p
        | VNum _ ->
            raise
              (PathError
                 "Falsy value found when guide_path expected a truthy value")
        | VPair _ -> raiseTypeError `Num "IF")
    | Let (x, exp, body), PtLet (v_p, e_p) ->
        let v = inner env exp v_p in
        inner ((x, v) @: env) body e_p
    | Var x, PtNil -> env x
    | e, p ->
        failwith
          (Printf.sprintf
             "Path mismatch: This is a programming error\nexpr: %s\npath: %s\n"
             (string_of_exp e) (Path.string_of_path p))
  in
  inner env expr guide_path
