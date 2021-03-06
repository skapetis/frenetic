open Packet
open NetCore_Types
open NetCore_Util
open Unix

module W = NetCore_Wildcard
module P = NetCore_Pattern

(* JNF: This function belongs somewhere else. *)
let map_option f = function
  | None -> None
  | Some x -> Some (f x)

(* The [Sat] module provides a representation of formulas in
   first-order logic, a representation of packets, and a function for
   testing their satisfiability. *)
module Sat = struct

  type zVar = string
  let zvar (s : string) : zVar = s

  type zSort = 
    | SPacket
    | SInt
    | SFunction of zSort * zSort
    | SRelation of zSort list

  type zTerm = 
    | TVar of zVar
    | TInt of Int64.t
    | TPkt of switchId * portId * packet
    | TApp of zVar * zTerm

  type zFormula =
    | ZTrue
    | ZFalse 
    | ZNot of zFormula
    | ZAnd of zFormula list
    | ZOr of zFormula list
    | ZEquals of zTerm * zTerm
	| ZComment of string * zFormula

  type zDeclaration = 
    | ZVarDeclare of zVar * zSort
    | ZSortDeclare of zVar * (zVar * (zVar * zSort) list) list 
    | ZAssertDeclare of zFormula

  type zProgram = 
    | ZProgram of zDeclaration list

  let fresh_cell = ref []

  let fresh sort = 
    let l = !fresh_cell in  
    let n = List.length l in 
    let x = match sort with
      | SPacket -> zvar (Printf.sprintf "_pkt%d" n )
      | SInt -> zvar (Printf.sprintf "_n%d" n)
      | SFunction _ -> zvar (Printf.sprintf "_f%d" n)
      | SRelation _ -> zvar (Printf.sprintf "_R%d" n) in 
    fresh_cell := ZVarDeclare(x,sort)::l;
    x

  let serialize_located_packet (sw,pt,pkt) = 
    Printf.sprintf "(Packet %s %s %s %s)" 
      (Int64.to_string sw) 
      (Int32.to_string pt)
      (Int64.to_string pkt.dlSrc)
      (Int64.to_string pkt.dlDst)

  let rec serialize_sort = function
    | SPacket -> 
      "Packet"
    | SInt -> 
      "Int"
    | SFunction(sort1,sort2) -> 
      Printf.sprintf "(%s) %s" 
        (serialize_sort sort1) 
        (serialize_sort sort2)
    | SRelation(sorts) -> 
      Printf.sprintf "(%s)"
        (intercalate serialize_sort " " sorts)

  let rec serialize_var (v : zVar) : string = v

  let rec serialize_term term : string = 
	match term with 
      | TVar x -> 
		serialize_var x
      | TPkt (sw,pt,pkt) -> 
		serialize_located_packet (sw,pt,pkt)
      | TInt n -> 
		Printf.sprintf "%s" 
          (Int64.to_string n)
      | TApp (f, term) -> 
		Printf.sprintf "(%s %s)" (serialize_var f) (serialize_term term)

  let serialize_comment cmnt = 
	Printf.sprintf "%s" cmnt

  let rec serialize_formula = function
    | ZTrue -> 
      Printf.sprintf "true"
    | ZFalse -> 
      Printf.sprintf "false"
    | ZNot f1 -> 
      Printf.sprintf "(not %s)" (serialize_formula f1)
    | ZEquals (t1, t2) -> 
      Printf.sprintf "(equals %s %s)" (serialize_term t1) (serialize_term t2)
    | ZAnd([]) -> 
      Printf.sprintf "true"
    | ZAnd([f]) -> 
      Printf.sprintf "%s" (serialize_formula f)
    | ZAnd(f::fs) -> 
      Printf.sprintf "(and %s %s)" (serialize_formula f) (serialize_formula (ZAnd(fs)))
    | ZOr([]) -> 
      Printf.sprintf "false"
    | ZOr([f]) -> 
      Printf.sprintf "%s" (serialize_formula f)
    | ZOr(f::fs) -> 
      Printf.sprintf "(or %s %s)" (serialize_formula f) (serialize_formula (ZOr(fs)))
	| ZComment(cmnt, f) -> 
	  Printf.sprintf "\n;%s\n%s\n;%s\n" (serialize_comment cmnt) (serialize_formula f)
		(String.concat "" ["END "; serialize_comment cmnt])

(*ZSortDeclare of zVar * (zVar * (zVar * zSort) list) list *)
  let serialize_declaration = function
    | ZSortDeclare (name, constructorList) ->
	  let name  = serialize_var name in 
      let serialize_field (field,sort) = 
        Printf.sprintf "(%s %s)" (serialize_var field) 
		  (serialize_sort sort) in
      let serialize_constructor (name, fields) = 
        Printf.sprintf "(%s %s)" (serialize_var name) 
		  (intercalate serialize_field " " fields) in 
      Printf.sprintf "(declare-datatypes () ((%s %s)))" 
        name (intercalate serialize_constructor " " constructorList)
    | ZVarDeclare (x, sort) ->
	  let x = serialize_var x in
      let decl = match sort with 
        | SFunction _ -> "fun"
        | SRelation _ -> "rel"
        | _ -> "var" in 
      Printf.sprintf "(declare-%s %s %s)" decl x (serialize_sort sort)
    | ZAssertDeclare(f) -> 
      Printf.sprintf "(assert %s)" (serialize_formula f)


  let init_decls : zDeclaration list = 
    [ ZSortDeclare
        (zvar "Packet", [(zvar "packet", [ (zvar "Switch", SInt)
										 ; (zvar "EthDst", SInt)
										 ; (zvar "EthType", SInt)
										 ; (zvar "Vlan", SInt)
										 ; (zvar "VlanPcp", SInt)
										 ; (zvar "IPProto", SInt)
										 ; (zvar "IP4Src", SInt)
										 ; (zvar "IP4Dst", SInt)
										 ; (zvar "TCPSrcPort", SInt)
										 ; (zvar "TCPDstPort", SInt)
										 ; (zvar "EthSrc", SInt)
										 ; (zvar "InPort", SInt)
										 ])])
    ]

  let serialize_program (ZProgram (decls)) global= 
    Printf.sprintf 
      "%s\n%s\n%s\n%s\n(check-sat)"
      (intercalate serialize_declaration "\n" init_decls)
      (intercalate serialize_declaration "\n" (!fresh_cell))
      (intercalate serialize_declaration "\n" decls)
      (intercalate serialize_declaration "\n" global)

  let solve prog global : bool = 
    let s = serialize_program prog global in 
    let z3_out,z3_in = open_process "z3 -in -smt2 -nw" in 
    let _ = output_string z3_in s in
    let _ = flush z3_in in 
    let _ = close_out z3_in in 
    let b = Buffer.create 17 in 
    (try
       while true do
         Buffer.add_string b (input_line z3_out);
         Buffer.add_char b '\n';
       done
     with End_of_file -> ());
	(*Printf.eprintf "%s" s;*)
    Buffer.contents b = "sat\n"
end

module Verify_Graph = struct
  open Topology
  open NetKAT_Types
  module S = SDN_Types

	
  let longest_shortest graph = 
	let vertices = Topology.get_vertices graph in
	let longest_shortest_lambda (best_guess : int) vertex : int = 
	  List.fold_left (fun (acc : int) ver2 -> 
		try
		  let verts = Topology.shortest_path graph vertex ver2 in
		  let length = List.length verts in
		  (if length > acc then length else acc)
		with _ -> 0
	  ) 0 vertices
	in
	List.fold_left longest_shortest_lambda 0 vertices

  let unfold_graph graph =
	let edges = Topology.get_edges graph in
	let src_port_vals h=
	  let swSrc =
	    (match Link.src h with
		  | Node.Switch (str, id) -> VInt.Int64 id
		  | _ -> failwith "Switch not in proper form" ) in
	  let swDst =
		(match Link.dst h with
		  | Node.Switch (str, id) -> VInt.Int64 id
		  | _ -> failwith"Switch not in proper form" ) in
	  let prtSrc = 
		let val64 = Int64.of_int32 (Link.srcport h) in
		VInt.Int64 val64
	  in
	  let prtDst = 
		let val64 = Int64.of_int32 (Link.dstport h) in
		VInt.Int64 val64 in
	  (swSrc, prtSrc, swDst, prtDst) in
	let rec create_pol edgeList =
	  match edgeList with
		| h::[] ->
		  let (swSrc, prtSrc, swDst, prtDst) = src_port_vals h in
		  Seq ( Seq (Filter (Test (Switch, swSrc)),
					 Filter (Test( Header S.InPort, prtSrc))),
				Seq (Mod (Switch, swDst), Mod (Header S.InPort, prtDst)))
		| h::t -> 
		  let (swSrc, prtSrc, swDst, prtDst) = src_port_vals h in
		  Seq ( Seq ( Seq (Filter (Test (Switch, swSrc)), 
						   Filter (Test (Header SDN_Types.InPort, prtSrc))),
					  Seq (Mod (Switch, swDst), Mod (Header S.InPort, prtDst))),
				create_pol t)
		| _ -> failwith "non-empty lists only for now."
 in
	create_pol edges

  let parse_graph ptstar = 
	(
	  let graph = Topology.empty in (
		let rec parse_links (graph: Topology.t) (pol: policy): Topology.t = 
		  let assemble switch1 port1 switch2 port2 : Topology.t =
			match port1, port2 with 
			  | VInt.Int64 port1, VInt.Int64 port2 -> 
				let (node1: Node.t) = Node.Switch ("fresh tag", VInt.get_int64 switch1) in
				let (node2: Node.t) = Node.Switch ("fresh tag", VInt.get_int64 switch2) in
				Topology.add_switch_edge graph node1 (Int64.to_int32 port1) node2 (Int64.to_int32 port2)
			  | _,_ -> failwith "need int64 people"
		  in
		  match pol with
			| Seq (Filter(And (Test (Switch, switch1), Test (Header SDN_Types.InPort, port1))),
				   Seq (Mod (Switch, switch2), Mod (Header S.InPort, port2)))
			  -> (assemble switch1 port1 switch2 port2)
			  
			| Par
				(Seq (Filter(And (Test (Switch, switch1), Test (Header SDN_Types.InPort, port1))),
					  Seq (Mod (Switch, switch2), Mod (Header S.InPort, port2))), t)
			  -> parse_links (assemble switch1 port1 switch2 port2) t
			| _ -> failwith (Printf.sprintf "unimplemented" )
		in
    match ptstar with
      | Star (Seq (p, t)) -> parse_links graph t
      | _ -> failwith "graph parsing assumes input is of the form (p;t)*"
	  ))
end
  

module Verify = struct
  open Sat
  open SDN_Types
  open NetKAT_Types

  let all_fields =
      [ Header InPort 
      ; Header EthType
      ; Header EthSrc
      ; Header EthDst
      ; Header Vlan
      ; Header VlanPcp
      ; Header IPProto
      ; Header IP4Src
      ; Header IP4Dst
      ; Header TCPSrcPort
      ; Header TCPDstPort
      ; Switch 
]

  (* Bring header field names inline with SDN types*)
  let encode_header (header: header) (pkt: zVar): zTerm =
    match header with
      | Header InPort -> TApp (zvar "InPort", TVar pkt)
      | Header EthType ->  TApp (zvar "EthType", TVar pkt)
      | Header EthSrc -> TApp (zvar "EthSrc", TVar pkt)
      | Header EthDst -> TApp (zvar "EthDst", TVar pkt)
      | Header Vlan ->  TApp (zvar "Vlan", TVar pkt)
      | Header VlanPcp ->  TApp (zvar "VlanPcp", TVar pkt)
      | Header IPProto ->  TApp (zvar "IPProto", TVar pkt)
      | Header IP4Src ->  TApp (zvar "IP4Src", TVar pkt)
      | Header IP4Dst ->  TApp (zvar "IP4Dst", TVar pkt)
      | Header TCPSrcPort ->  TApp (zvar "TCPSrcPort", TVar pkt)
      | Header TCPDstPort ->  TApp (zvar "TCPDstPort", TVar pkt)
      | Switch -> TApp (zvar "Switch", TVar pkt)

  let equal_field (pkt1: zVar) (pkt2: zVar) (except_fields:header list): zFormula =
    ZAnd (List.fold_left 
	    (fun acc hd -> 
	      if List.mem hd except_fields then 
		acc 
	      else
		ZEquals (encode_header hd pkt1, encode_header hd pkt2)::acc) 
	    [] all_fields )


  let packet_field (field:string) (pkt:zVar) (num:zTerm) : zFormula =
    ZEquals( TApp (field, TVar pkt), num)

  let equal_single_field (field:string) (pkts : zVar list) : zFormula =
    let num = TVar (fresh SInt) in
	let f elem = packet_field field elem num in
	ZAnd (List.map f pkts)
	  
  let encode_vint (v: VInt.t): zTerm = TInt (VInt.get_int64 v)

  let global_bindings = ref []


  let rec forwards_pred (pr : pred) (pkt : zVar) : zFormula = 
    match pr with
      | False -> 
		ZFalse
      | True -> 
		ZTrue
      | Test (hdr, v) -> 
		ZEquals (encode_header hdr pkt, encode_vint v)
      | Neg p ->
        ZNot (forwards_pred p pkt)
      | And (p1, p2) -> ZAnd [forwards_pred p1 pkt; 
                              forwards_pred p2 pkt]
      | Or (p1, p2) -> ZOr [forwards_pred p1 pkt;
                            forwards_pred p2 pkt]
	

  let forwards_pred_bind (pr:pred) (pkt1:zVar) (pkt2: zVar): zFormula =
	global_bindings := (ZEquals (TVar pkt1, TVar pkt2))::!global_bindings;
	(*pkt2 := !pkt1;*)
	forwards_pred pr pkt1
		
  let rec forwards (pol:policy) (pkt1:zVar) (pkt2: zVar): zFormula =
    match pol with
      | Filter pr -> ZComment ("Filter", (forwards_pred_bind pr pkt1 pkt2))
      | Mod (hdr, v) -> 
		ZComment ("Mod", ZAnd [ZEquals (encode_header hdr pkt2, encode_vint v);
			  equal_field pkt1 pkt2 [hdr]])
      | Par (p1, p2) -> 
		ZComment ("Par", ZOr [forwards p1 pkt1 pkt2;
			 forwards p2 pkt1 pkt2])
      | Seq (p1, p2) -> 
		let pkt' = fresh SPacket in
		ZComment ("Seq", ZAnd [forwards p1 pkt1 pkt';
			  forwards p2 pkt' pkt2])
	  | Star p1 -> failwith "NetKAT program not in form (p;t)*"
		
let noop_expr = 
  let ret history = 
	Sat.ZTrue
  in
  ret

  let forwards_star_history expect_dup expr k p_t_star pkt1 pkt2 : zFormula = 
  let rec forwards_star_history (k:int) p_t_star (pkt1:zVar) (pkt2:zVar) : zFormula list  =
    if k = 0 then
      [ZAnd [ZEquals (TVar pkt1, TVar pkt2); expr [pkt1]]]
    else
      let rec inner_forwards k p_t_star pkt1 pkt2 : zFormula * (zVar list) =
		let pol,topo = (match p_t_star with 
		  | (Star (Seq (Seq (pol, topo), (*TODO: dup*) dup))) -> if expect_dup then pol,topo else failwith "dup present, but not expecting dup"
		  | (Star (Seq (pol,topo))) -> if expect_dup then failwith "in form (p;t)*, expected form dup;(p;t;dup)*" else pol,topo
		  | _ -> failwith "not in form pt* with or without dup (maybe you forgot to make Seqs left-aligned?)") in
        if k = 0 then
          ZEquals (TVar pkt1, TVar pkt2), [pkt2]
        else
          let pkt' = fresh SPacket in
          let pkt'' = fresh SPacket in
		  let formula, histr = inner_forwards (k-1) (Star (Seq (pol, topo))) pkt'' pkt2 in
		  let new_history = pkt1 :: histr in
          ZAnd [ forwards pol pkt1 pkt';
                 forwards topo pkt' pkt'';
                 formula ], new_history
      in
	  let form, hist = inner_forwards k p_t_star pkt1 pkt2 in
      (ZAnd [form; expr hist])::(forwards_star_history (k-1) p_t_star pkt1 pkt2)
  in
  let p_t_star = if expect_dup then (
	match p_t_star with
	  | _ (* when there is a dup, we'll make sure that it is present as the first term here *)
		-> p_t_star ) else p_t_star in 
  ZOr (forwards_star_history k p_t_star pkt1 pkt2)


  let forwards_star  = forwards_star_history false noop_expr
end

let generate_program expect_dup expr inp p_t_star outp k x y= 
  let prog = 
    Sat.ZProgram [ Sat.ZAssertDeclare (Verify.forwards_pred inp x)
                 ; Sat.ZAssertDeclare (Verify.forwards_star_history expect_dup expr k p_t_star x y )
                 ; Sat.ZAssertDeclare (Verify.forwards_pred outp y) ] in prog

let run_solve oko prog str = 
  let global_eq =
	match !Verify.global_bindings with
	  | [] -> []
	  | _ -> [Sat.ZAssertDeclare (Sat.ZAnd !Verify.global_bindings)] in
  let run_result = (
	match oko, Sat.solve prog global_eq with 
	  | Some ok, sat -> 
		if ok = sat then 
		  true
		else
		  (Printf.printf "[Verify.check %s: expected %b got %b]\n%!" str ok sat; false)
	  | None, sat -> 
		(Printf.printf "[Verify.check %s: %b]\n%!" str sat; false)) in
  Sat.fresh_cell := []; Verify.global_bindings := []; run_result
	
let combine_programs progs = 
  Sat.ZProgram (List.flatten (List.map (fun prog -> match prog with 
	| Sat.ZProgram (asserts) -> asserts) progs))

let make_vint v = VInt.Int64 (Int64.of_int v)

let check_equivalent pt1 pt2 str = 
  	(*global_bindings := (ZEquals (TVar pkt1, TVar pkt2))::!global_bindings;*)
  let graph1, graph2 = Verify_Graph.parse_graph pt1, Verify_Graph.parse_graph pt2 in
  let length1, length2 = Verify_Graph.longest_shortest graph1, Verify_Graph.longest_shortest graph2 in
  let k = if length1 > length2 then length1 else length2 in
  let k_z3 = Sat.fresh Sat.SInt in
  let x = Sat.fresh Sat.SPacket in
  let y1 = Sat.fresh Sat.SPacket in
  let y2 = Sat.fresh Sat.SPacket in
  let fix_k = (fun n -> Sat.ZEquals (Sat.TVar k_z3, Verify.encode_vint (make_vint (List.length n)))) in
  let prog1 = generate_program false fix_k NetKAT_Types.True pt1 NetKAT_Types.True k x y1 in
  let prog2 = generate_program false fix_k  NetKAT_Types.True pt2 NetKAT_Types.True k x y2 in
  let prog = combine_programs 
	[Sat.ZProgram [Sat.ZAssertDeclare (Sat.ZEquals (Sat.TVar x, Sat.TVar x)); 
				   Sat.ZAssertDeclare (Sat.ZNot (Sat.ZEquals (Sat.TVar y1, Sat.TVar y2)))]; 
	 prog1; 
	 prog2] in
  run_solve (Some false) prog str

let check_specific_k_history expect_dup expr str inp p_t_star outp oko (k : int) : bool = 
  let x = Sat.fresh Sat.SPacket in 
  let y = Sat.fresh Sat.SPacket in 
  let prog = generate_program expect_dup expr inp p_t_star outp k x y in
  run_solve oko prog str

let check_maybe_dup expect_dup expr str inp p_t_star outp (oko : bool option) : bool = 
  let res_graph = Verify_Graph.parse_graph p_t_star in
  (*Printf.eprintf "%s" (NetCore_Topology.Topology.to_dot res_graph);*)
  let longest_shortest_path = Verify_Graph.longest_shortest
	res_graph in
  check_specific_k_history expect_dup expr str inp p_t_star outp oko longest_shortest_path


let check_with_history  = check_maybe_dup (*TODO: add dup support when I find it in the code*) false
  
(* str: name of your test (unique ID)  
   inp: initial packet
   pol: policy to test
   outp: fully-transformed packet 
   oko: bool option.  has to be Some.  True if you think it should be satisfiable.
*)
let check_specific_k = check_specific_k_history false Verify.noop_expr

let check  = check_maybe_dup false Verify.noop_expr

