type header =
  | Header of SDN_Types.field
  | Switch

type header_val = VInt.t

type pred = 
  | True
  | False
  | Test of header*header_val
  | And of pred*pred
  | Or of pred*pred
  | Neg of pred

type policy =
  | Filter of pred
  | Mod of header*header_val
  | Par of policy*policy
  | Seq of policy*policy
  | Star of policy

let id = Filter True
let drop = Filter False

module HeaderMap = Map.Make (struct
    type t = header
    let compare = Pervasives.compare
  end)

type header_val_map = header_val HeaderMap.t

type packet = {
  headers : header_val_map;
  payload : SDN_Types.payload
}

module PacketSet = Set.Make (struct
    type t = packet

    (* First compare by headers, then payload. The payload comparison is a
       little questionable. However, this is safe to use in eval, since
       all output packets have the same payload as the input packet. *)
    let compare x y =
      let cmp = HeaderMap.compare Pervasives.compare x.headers y.headers in
      if cmp != 0 then
        cmp
      else
        Pervasives.compare x.payload y.payload
  end)

let rec eval_pred (pkt:packet) (pr:pred) : bool = match pr with
  | True -> true
  | False -> false
  | Test (h, v) -> 
    if HeaderMap.find h pkt.headers = v then
      true
    else
      false
  | And (pr1, pr2) -> eval_pred pkt pr1 && eval_pred pkt pr2
  | Or (pr1, pr2) -> eval_pred pkt pr1 || eval_pred pkt pr2
  | Neg pr1 -> not (eval_pred pkt pr1)

let rec eval (pkt:packet) (pol:policy) : PacketSet.t = match pol with
  | Filter pr -> 
    if eval_pred pkt pr then 
      PacketSet.singleton pkt 
    else 
      PacketSet.empty
  | Mod (h, v) ->
    if HeaderMap.mem h pkt.headers then
      PacketSet.singleton { pkt with headers = HeaderMap.add h v pkt.headers }
    else
      raise Not_found (* for consistency with Test *)
  | Par (pol1, pol2) ->
    PacketSet.union (eval pkt pol1) (eval pkt pol2)
  | Seq (pol1, pol2) ->
    let f pkt' set = PacketSet.union (eval pkt' pol2) set in
    PacketSet.fold f (eval pkt pol1) PacketSet.empty
  | Star pol -> 
    let rec loop acc = 
      let f pkt' set = PacketSet.union (eval pkt' pol) set in 
      let acc' = PacketSet.fold f acc PacketSet.empty in 
      if PacketSet.equal acc acc' then acc else loop acc' in 
    loop (PacketSet.singleton pkt)

module Formatting = struct

  open Format

  let header (fmt : formatter) (h : header) : unit = match h with
    | Header h' -> SDN_Types.format_field fmt h'
    | Switch -> pp_print_string fmt "switch"

  (* The type of the immediately surrounding context, which guides parenthesis-
     intersion. *)
  (* JNF: YES. This is the Right Way to pretty print. *)
  type context = SEQ | PAR | STAR | NEG | PAREN

  let rec pred (cxt : context) (fmt : formatter) (pr : pred) : unit = 
    match pr with
    | True -> 
      fprintf fmt "@[true@]"
    | False -> 
      fprintf fmt "@[false@]"
    | (Test (h, v)) -> 
      fprintf fmt "@[%a = %a@]" header h VInt.format v
    | Neg p' -> 
      begin match cxt with
        | PAREN -> fprintf fmt "@[!%a@]" (pred NEG) p'
        | _ -> fprintf fmt "@[!@[(%a)@]@]" (pred PAREN) p'
      end
    | Or (p1, p2) -> 
      begin match cxt with
        | PAREN
        | PAR -> fprintf fmt "@[%a + %a@]" (pred PAR) p1 (pred PAR) p2
        | _ -> fprintf fmt "@[(@[%a + %a@])@]" (pred PAR) p1 (pred PAR) p2
      end
    | And (p1, p2) -> 
      begin match cxt with
        | PAREN
        | SEQ
        | PAR -> fprintf fmt "@[%a ; %a@]" (pred SEQ) p1 (pred SEQ) p2
        | _ -> fprintf fmt "@[(@[%a ; %a@])@]" (pred SEQ) p1 (pred SEQ) p2
       end

  let rec pol (cxt : context) (fmt : formatter) (p : policy) : unit =
    match p with
    | Filter pr -> 
      pred cxt fmt pr
    | Mod (h, v) -> 
      fprintf fmt "@[%a <- %a@]" header h VInt.format v
    | Star p' -> 
      begin match cxt with
        | PAREN 
	| STAR ->  fprintf fmt "@[%a*@]" (pol STAR) p' 
        | _ -> fprintf fmt "@[@[(%a)*@]@]" (pol PAREN) p'
      end
    | Par (p1, p2) -> 
      begin match cxt with
        | PAREN
        | PAR -> fprintf fmt "@[%a + %a@]" (pol PAR) p1 (pol PAR) p2
        | _ -> fprintf fmt "@[(@[%a + %a@])@]" (pol PAR) p1 (pol PAR) p2
      end
    | Seq (p1, p2) -> 
      begin match cxt with
        | PAREN
        | SEQ
        | PAR -> fprintf fmt "@[%a ; %a@]" (pol SEQ) p1 (pol SEQ) p2
        | _ -> fprintf fmt "@[(@[%a ; %a@])@]" (pol SEQ) p1 (pol SEQ) p2
       end
end

let make_string_of formatter x =
  let open Format in
  let buf = Buffer.create 100 in
  let fmt = formatter_of_buffer buf in
  pp_set_margin fmt 80;
  formatter fmt x;
  fprintf fmt "@?";
  Buffer.contents buf

let string_of_vint = make_string_of VInt.format 

let string_of_header = make_string_of Formatting.header

let format_policy = Formatting.pol Formatting.PAREN

let string_of_policy = make_string_of format_policy
