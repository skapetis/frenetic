open Frenetic_Bit
open Packet
open Format

exception Unparsable of string
exception Ignored of string

(* TODO(cole): find a better place for these. *)
type switchId = int64
type priority = int16
type bufferId = int32
type table_id = int8

let string_of_switchId = Int64.to_string
let string_of_priority p = Printf.sprintf "%d" p
let string_of_bufferId = Int32.to_string
let string_of_table_id id = Printf.sprintf "%d" id

let string_of_portId = portId_to_string
let string_of_dlAddr = dlAddr_to_string

let sum (lst : int list) = List.fold_left (fun x y -> x + y) 0 lst

cenum ofp_stats_types {
  OFPST_DESC;
  OFPST_FLOW;
  OFPST_AGGREGATE;
  OFPST_TABLE;
  OFPST_PORT;
  OFPST_QUEUE;
  OFPST_VENDOR = 0xffff
} as uint16_t

(** Internal module, only used to parse the wildcards bitfield *)
module Wildcards = struct

  type t = {
    in_port: bool;
    dl_vlan: bool;
    dl_src: bool;
    dl_dst: bool;
    dl_type: bool;
    nw_proto: bool;
    tp_src: bool;
    tp_dst: bool;
    nw_src: int; (* XXX *)
    nw_dst: int; (* XXX *)
    dl_vlan_pcp: bool;
    nw_tos: bool;
  }

  let set_nw_mask (f:int32) (off : int) (v : int) : int32 =
    let value = (0x3f land v) lsl off in
    (Int32.logor f (Int32.of_int value))

  (* TODO(arjun): this is different from mirage *)
  let get_nw_mask (f : int32) (off : int) : int =
    (Int32.to_int (Int32.shift_right f off)) land 0x3f

  let marshal m =
    let ret = Int32.zero in
    let ret = bit ret 0 m.in_port in
    let ret = bit ret 1 m.dl_vlan in
    let ret = bit ret 2 m.dl_src in
    let ret = bit ret 3 m.dl_dst in
    let ret = bit ret 4 m.dl_type in
    let ret = bit ret 5 m.nw_proto in
    let ret = bit ret 6 m.tp_src in
    let ret = bit ret 7 m.tp_dst in
    let ret = set_nw_mask ret 8 m.nw_src in
    let ret = set_nw_mask ret 14 m.nw_dst in
    let ret = bit ret 20 m.dl_vlan_pcp in
    let ret = bit ret 21 m.nw_tos in
    ret

  let to_string h =
    Format.sprintf
      "in_port:%s,dl_vlan:%s,dl_src:%s,dl_dst:%s,dl_type:%s,\
       nw_proto:%s,tp_src:%s,tp_dst:%s,nw_src:%d,nw_dst:%d,\
       dl_vlan_pcp:%s,nw_tos:%s"
      (string_of_bool h.in_port)
      (string_of_bool h.dl_vlan) (string_of_bool h.dl_src)
      (string_of_bool h.dl_dst) (string_of_bool h.dl_type)
      (string_of_bool h.nw_proto) (string_of_bool h.tp_src)
      (string_of_bool h.tp_dst) h.nw_src
      h.nw_dst (string_of_bool h.dl_vlan_pcp)
      (string_of_bool h.nw_tos)

  let parse bits =
    { nw_tos = test_bit 21 bits;
      dl_vlan_pcp = test_bit 20 bits;
      nw_dst = get_nw_mask bits 14;
      nw_src = get_nw_mask bits 8;
      tp_dst = test_bit 7 bits;
      tp_src = test_bit 6 bits;
      nw_proto = test_bit 5 bits;
      dl_type = test_bit 4 bits;
      dl_dst = test_bit 3 bits;
      dl_src = test_bit 2 bits;
      dl_vlan = test_bit 1 bits;
      in_port = test_bit 0 bits;
    }
end

module Match = struct

  type t = {
    dlSrc : dlAddr option;
    dlDst : dlAddr option;
    dlTyp : dlTyp option;
    dlVlan : dlVlan option;
    dlVlanPcp : dlVlanPcp option;
    nwSrc : nwAddr option;
    nwDst : nwAddr option;
    nwProto : nwProto option;
    nwTos : nwTos option;
    tpSrc : tpPort option;
    tpDst : tpPort option;
    inPort : portId option
  }

  cstruct ofp_match {
    uint32_t wildcards;
    uint16_t in_port;
    uint8_t dl_src[6];
    uint8_t dl_dst[6];
    uint16_t dl_vlan;
    uint8_t dl_vlan_pcp;
    uint8_t pad1[1];
    uint16_t dl_type;
    uint8_t nw_tos;
    uint8_t nw_proto;
    uint8_t pad2[2];
    uint32_t nw_src;
    uint32_t nw_dst;
    uint16_t tp_src;
    uint16_t tp_dst
  } as big_endian

  let size_of _ = sizeof_ofp_match

  let all = {
    dlSrc = None;
    dlDst = None;
    dlTyp = None;
    dlVlan = None;
    dlVlanPcp = None;
    nwSrc = None;
    nwDst = None;
    nwProto = None;
    nwTos = None;
    tpSrc = None;
    tpDst = None;
    inPort = None
  }
  let is_none x = match x with
    | None -> true
    | Some _ -> false

  let wildcards_of_match (m : t) : Wildcards.t =
    { Wildcards.in_port = is_none m.inPort;
      Wildcards.dl_vlan = is_none m.dlVlan;
      Wildcards.dl_src = is_none m.dlSrc;
      Wildcards.dl_dst = is_none m.dlDst;
      Wildcards.dl_type = is_none m.dlTyp;
      Wildcards.nw_proto = is_none m.nwProto;
      Wildcards.tp_src = is_none m.tpSrc;
      Wildcards.tp_dst = is_none m.tpDst;
      (* TODO(arjun): support IP prefixes *)
      Wildcards.nw_src = if is_none m.nwSrc then 32 else 0x0;
      Wildcards.nw_dst = if is_none m.nwDst then 32 else 0x0;
      Wildcards.dl_vlan_pcp = is_none m.dlVlanPcp;
      Wildcards.nw_tos = is_none m.nwTos;
  }

  let if_some16 x = match x with
    | Some n -> n
    | None -> 0

  let if_some8 x = match x with
    | Some n -> n
    | None -> 0

  let if_some32 x = match x with
    | Some n -> n
    | None -> 0l

  let if_word48 x = match x with
    | Some n -> n
    | None -> Int64.zero

  let marshal m bits =
    set_ofp_match_wildcards bits (Wildcards.marshal (wildcards_of_match m));
    set_ofp_match_in_port bits (if_some16 m.inPort);
    set_ofp_match_dl_src (bytes_of_mac (if_word48 m.dlSrc)) 0 bits;
    set_ofp_match_dl_dst (bytes_of_mac (if_word48 m.dlDst)) 0 bits;
    let vlan =
      match m.dlVlan with
      | Some (Some v) -> v
      | Some None -> Packet.vlan_none
      | None -> 0 in
    set_ofp_match_dl_vlan bits (vlan);
    set_ofp_match_dl_vlan_pcp bits (if_some8 m.dlVlanPcp);
    set_ofp_match_dl_type bits (if_some16 m.dlTyp);
    set_ofp_match_nw_tos bits (if_some8 m.nwTos);
    set_ofp_match_nw_proto bits (if_some8 m.nwProto);
    set_ofp_match_nw_src bits (if_some32 m.nwSrc);
    set_ofp_match_nw_dst bits (if_some32 m.nwDst);
    set_ofp_match_tp_src bits (if_some16 m.tpSrc);
    set_ofp_match_tp_dst bits (if_some16 m.tpDst);
    sizeof_ofp_match

  let parse bits =
    let w = Wildcards.parse (get_ofp_match_wildcards bits) in
    { dlSrc =
        if w.Wildcards.dl_src then
          None
        else
          Some (mac_of_bytes
                  (Cstruct.to_string (get_ofp_match_dl_src bits)));
      dlDst =
        if w.Wildcards.dl_dst then
          None
        else
          Some (mac_of_bytes
                  (Cstruct.to_string (get_ofp_match_dl_dst bits)));
      dlVlan =
        if w.Wildcards.dl_vlan then
          None
        else
          begin
            let vlan = get_ofp_match_dl_vlan bits in
            if vlan = Packet.vlan_none then
              Some None
            else
              Some (Some vlan)
          end;
      dlVlanPcp =
        if w.Wildcards.dl_vlan_pcp then
          None
        else
          Some (get_ofp_match_dl_vlan_pcp bits);
      dlTyp =
        if w.Wildcards.dl_type then
          None
        else
          Some (get_ofp_match_dl_type bits);
      nwSrc =
        if w.Wildcards.nw_src >= 32 then (* TODO(arjun): prefixes *)
          None
        else
          Some (get_ofp_match_nw_src bits);
      nwDst =
        if w.Wildcards.nw_dst >= 32 then (* TODO(arjun): prefixes *)
          None
        else
          Some (get_ofp_match_nw_dst bits);
      nwProto =
        if w.Wildcards.nw_proto then
          None
        else
          Some (get_ofp_match_nw_proto bits);
      nwTos =
        if w.Wildcards.nw_tos then
          None
        else
          Some (get_ofp_match_nw_tos bits);
      tpSrc =
        if w.Wildcards.tp_src then
          None
        else
          Some (get_ofp_match_tp_src bits);
      tpDst =
        if w.Wildcards.tp_dst then
          None
        else
          Some (get_ofp_match_tp_dst bits);
      inPort =
        if w.Wildcards.in_port then
          None
        else
          Some (get_ofp_match_in_port bits);
    }

  (* Helper for to_string *)
  let fld_str (lbl : string) (pr : 'a -> string) (v : 'a option)
      : string option =
    match v with
      | None -> None
      | Some a -> Some (sprintf "%s = %s" lbl (pr a))

  let to_string (x : t) : string =
    let all_fields =
      [ fld_str "dlSrc" string_of_mac x.dlSrc;
        fld_str "dlDst" string_of_mac x.dlDst;
        fld_str "dlTyp" string_of_int x.dlTyp;
        (match x.dlVlan with
          | None -> None
          | Some None -> Some "dlVlan = none"
          | Some (Some vlan) -> fld_str "dlVlan" string_of_int (Some vlan));
        fld_str "dlVlanPcp" string_of_int x.dlVlanPcp;
        fld_str "nwSrc" Int32.to_string x.nwSrc;
        fld_str "nwDst" Int32.to_string x.nwDst;
        fld_str "nwProto" string_of_int x.nwProto;
        fld_str "nwTos" string_of_int x.nwTos;
        fld_str "tpSrc" string_of_int x.tpSrc;
        fld_str "tpDst" string_of_int x.tpDst;
        fld_str "inPort" string_of_int x.inPort ] in
    let set_fields =
      List.fold_right
        (fun fo acc -> match fo with None -> acc | Some f -> f :: acc)
        all_fields [] in
    match set_fields with
      | [] -> "{*}"
      | _ ->  "{" ^ (String.concat ", " set_fields) ^ "}"

end

module PseudoPort = struct

  type t =
    | PhysicalPort of portId
    | InPort
    | Flood
    | AllPorts
    | Controller of int

  cenum ofp_port {
    (* Maximum number of physical switch ports. *)
    OFPP_MAX = 0xff00;

    (*Fake output "ports". *)
    OFPP_IN_PORT = 0xfff8;  (* Send the packet out the input port.  This
                             virtual port must be explicitly used
                             in order to send back out of the input
                             port. *)

    OFPP_TABLE = 0xfff9; (* Perform actions in flow table.
                          NB: This can only be the destination
                          port for packet-out messages. *)
    OFPP_NORMAL = 0xfffa; (* Process with normal L2/L3 switching. *)
    OFPP_FLOOD = 0xfffb; (* All physical porbts except input port and
                            those disabled by STP. *)
    OFPP_ALL = 0xfffc; (* All physical ports except input port. *)
    OFPP_CONTROLLER = 0xfffd; (* Send to controller. *)
    OFPP_LOCAL = 0xfffe; (* Local openflow "port". *)
    OFPP_NONE = 0xffff  (* Not associated with a physical port. *)
  } as uint16_t

  let size_of _ = 2

  let marshal (t : t) : int = match t with
    | PhysicalPort p -> p
    | InPort -> ofp_port_to_int OFPP_IN_PORT
    | Flood -> ofp_port_to_int OFPP_FLOOD
    | AllPorts -> ofp_port_to_int OFPP_ALL
    (* TODO(arjun): what happened to the byte count? *)
    | Controller _ -> ofp_port_to_int OFPP_CONTROLLER

  let marshal_optional (t : t option) : int = match t with
    | None -> ofp_port_to_int OFPP_NONE
    | Some x -> marshal x

  let to_string (t : t) : string = match t with
    | PhysicalPort p -> string_of_int p
    | InPort -> "InPort"
    | Flood -> "Flood"
    | AllPorts -> "AllPorts"
    | Controller n -> sprintf "Controller<%d bytes>" n

  let make ofp_port_code len =
    match int_to_ofp_port ofp_port_code with
    | Some OFPP_IN_PORT -> InPort
    | Some OFPP_FLOOD -> Flood
    | Some OFPP_ALL -> AllPorts
    | Some OFPP_CONTROLLER -> Controller len
    | _ ->
      if ofp_port_code <= (ofp_port_to_int OFPP_MAX) then
        PhysicalPort ofp_port_code
      else
        raise
          (Unparsable (sprintf "unsupported port number (%d)" ofp_port_code))

  let parse _ = failwith "NYI: PseudoPort.parse"

end

module Action = struct

  type t =
    | Output of PseudoPort.t
    | SetDlVlan of dlVlan
    | SetDlVlanPcp of dlVlanPcp
    | StripVlan
    | SetDlSrc of dlAddr
    | SetDlDst of dlAddr
    | SetNwSrc of nwAddr
    | SetNwDst of nwAddr
    | SetNwTos of nwTos
    | SetTpSrc of tpPort
    | SetTpDst of tpPort

  type sequence = t list

  cstruct ofp_action_header {
    uint16_t typ;
    uint16_t len
  } as big_endian

  cstruct ofp_action_output {
    uint16_t port;
    uint16_t max_len
  } as big_endian

  cstruct ofp_action_vlan_vid {
    uint16_t vlan_vid;
    uint8_t pad[2]
  } as big_endian

  cstruct ofp_action_vlan_pcp {
    uint8_t vlan_pcp;
    uint8_t pad[3]
  } as big_endian

  cstruct ofp_action_strip_vlan {
    uint8_t pad[2]
  } as big_endian

  cstruct ofp_action_dl_addr {
    uint8_t dl_addr[6];
    uint8_t pad[6]
  } as big_endian

  cstruct ofp_action_nw_addr {
    uint32_t nw_addr
  } as big_endian

  cstruct ofp_action_tp_port {
    uint16_t tp_port;
    uint8_t pad[2]
  } as big_endian

  cstruct ofp_action_nw_tos {
    uint8_t nw_tos;
    uint8_t pad[3]
  } as big_endian

  cstruct ofp_action_enqueue {
    uint16_t port;
    uint8_t pad[6];
    uint32_t queue_id
  } as big_endian

  cenum ofp_action_type {
    OFPAT_OUTPUT;
    OFPAT_SET_VLAN_VID;
    OFPAT_SET_VLAN_PCP;
    OFPAT_STRIP_VLAN;
    OFPAT_SET_DL_SRC;
    OFPAT_SET_DL_DST;
    OFPAT_SET_NW_SRC;
    OFPAT_SET_NW_DST;
    OFPAT_SET_NW_TOS;
    OFPAT_SET_TP_SRC;
    OFPAT_SET_TP_DST;
    OFPAT_ENQUEUE
  } as uint16_t

  let type_code (a : t) = match a with
    | Output _ -> OFPAT_OUTPUT
    | SetDlVlan _ -> OFPAT_SET_VLAN_VID
    | SetDlVlanPcp _ -> OFPAT_SET_VLAN_PCP
    | StripVlan -> OFPAT_STRIP_VLAN
    | SetDlSrc _ -> OFPAT_SET_DL_SRC
    | SetDlDst _ -> OFPAT_SET_DL_DST
    | SetNwSrc _ -> OFPAT_SET_NW_SRC
    | SetNwDst _ -> OFPAT_SET_NW_DST
    | SetNwTos _ -> OFPAT_SET_NW_TOS
    | SetTpSrc _ -> OFPAT_SET_TP_SRC
    | SetTpDst _ -> OFPAT_SET_TP_DST

  let size_of (a : t) =
    let h = sizeof_ofp_action_header in
    match a with
    | Output _ -> h + sizeof_ofp_action_output
    | SetDlVlan _ -> h + sizeof_ofp_action_vlan_vid
    | SetDlVlanPcp _ -> h + sizeof_ofp_action_vlan_pcp
    | StripVlan -> h + sizeof_ofp_action_strip_vlan
    | SetDlSrc _
    | SetDlDst _ -> h + sizeof_ofp_action_dl_addr
    | SetNwSrc _
    | SetNwDst _ -> h + sizeof_ofp_action_nw_addr
    | SetNwTos _ -> h + sizeof_ofp_action_nw_tos
    | SetTpSrc _
    | SetTpDst _ -> h + sizeof_ofp_action_tp_port

  let size_of_sequence acts = List.fold_left (+) 0 (List.map size_of acts)

  let marshal a bits =
    set_ofp_action_header_typ bits (ofp_action_type_to_int (type_code a));
    set_ofp_action_header_len bits (size_of a);
    let bits' = Cstruct.shift bits sizeof_ofp_action_header in
    begin
      match a with
        | Output pp ->
          set_ofp_action_output_port bits' (PseudoPort.marshal pp);
          set_ofp_action_output_max_len bits'
            (match pp with
              | PseudoPort.Controller w -> w
              | _ -> 0)
        | SetNwSrc addr
        | SetNwDst addr ->
          set_ofp_action_nw_addr_nw_addr bits' addr
        | SetTpSrc pt
        | SetTpDst pt ->
          set_ofp_action_tp_port_tp_port bits' pt
              | _ ->
                failwith "NYI: Action.marshal"
    end;
    size_of a

  let marshal_sequence acts out = failwith "NYI: Action.marshal_sequence"

  let is_to_controller (act : t) : bool = match act with
    | Output (PseudoPort.Controller _) -> true
    | _ -> false

  let move_controller_last (lst : sequence) : sequence =
    let (to_ctrl, not_to_ctrl) = List.partition is_to_controller lst in
    not_to_ctrl @ to_ctrl

  let to_string (t : t) : string = match t with
    | Output p -> "Output " ^ PseudoPort.to_string p
    | SetDlVlan None -> "SetDlVlan None"
    | SetDlVlan (Some n) -> sprintf "SetDlVlan %d" n
    | SetDlVlanPcp n -> sprintf "SetDlVlanPcp n"
    | StripVlan -> "StripDlVlan"
    | SetDlSrc mac -> "SetDlSrc " ^ string_of_mac mac
    | SetDlDst mac -> "SetDlDst " ^ string_of_mac mac
    | SetNwSrc ip -> "SetNwSrc " ^ string_of_ip ip
    | SetNwDst ip -> "SetNwDst " ^ string_of_ip ip
    | SetNwTos d -> sprintf "SetNwTos %x" d
    | SetTpSrc n -> sprintf "SetTpSrc %d" n
    | SetTpDst n -> sprintf "SetTpDst %d" n

  let sequence_to_string (lst : sequence) : string =
    "[" ^ (String.concat "; " (List.map to_string lst)) ^ "]"

  let _parse bits =
    let length = get_ofp_action_header_len bits in
    let ofp_action_code = get_ofp_action_header_typ bits in
    let bits' = Cstruct.shift bits sizeof_ofp_action_header in
    let act = match int_to_ofp_action_type ofp_action_code with
    | Some OFPAT_OUTPUT ->
      let ofp_port_code = get_ofp_action_output_port bits' in
      let len = get_ofp_action_output_max_len bits' in
      Output (PseudoPort.make ofp_port_code len)
    | Some OFPAT_SET_VLAN_VID ->
      let vid = get_ofp_action_vlan_vid_vlan_vid bits' in
      if vid = Packet.vlan_none then
        StripVlan
      else
        SetDlVlan (Some vid)
    | Some OFPAT_SET_VLAN_PCP ->
      SetDlVlanPcp (get_ofp_action_vlan_pcp_vlan_pcp bits')
    | Some OFPAT_STRIP_VLAN -> StripVlan
    | Some OFPAT_SET_DL_SRC ->
      let dl =
        mac_of_bytes
          (Cstruct.to_string (get_ofp_action_dl_addr_dl_addr bits')) in
      SetDlSrc dl
    | Some OFPAT_SET_DL_DST ->
      let dl =
        mac_of_bytes
          (Cstruct.to_string (get_ofp_action_dl_addr_dl_addr bits')) in
      SetDlDst dl
    | Some OFPAT_SET_NW_SRC ->
      SetNwSrc (get_ofp_action_nw_addr_nw_addr bits')
    | Some OFPAT_SET_NW_DST ->
      SetNwDst (get_ofp_action_nw_addr_nw_addr bits')
    | Some OFPAT_SET_NW_TOS ->
      SetNwTos (get_ofp_action_nw_tos_nw_tos bits')
    | Some OFPAT_SET_TP_SRC ->
      SetTpSrc (get_ofp_action_tp_port_tp_port bits')
    | Some OFPAT_SET_TP_DST ->
      SetTpDst (get_ofp_action_tp_port_tp_port bits')
    | Some OFPAT_ENQUEUE
    | None ->
      raise (Unparsable
        (sprintf "unrecognized ofpat_action_type (%d)" ofp_action_code))
    in
    (Cstruct.shift bits length, act)

  let parse bits = snd (_parse bits)

  let rec parse_sequence bits : sequence =
    if Cstruct.len bits = 0 then
      []
    else
      let bits', act = _parse bits in
      act::(parse_sequence bits')

end

module PortDescription = struct

  module PortConfig = struct

    type t =
      { down : bool (* Port is administratively down. *)
      ; no_stp : bool (* Disable 802.1D spanning tree on port. *)
      ; no_recv : bool (* Drop all packets except 802.1D spanning
                                 * tree packets. *)
      ; no_recv_stp : bool (* Drop received 802.1D STP packets. *)
      ; no_flood : bool (* Do not include this port when flooding. *)
      ; no_fwd : bool (* Drop packets forwarded to port. *)
      ; no_packet_in : bool (* Do not send packet-in msgs for port. *)
      }

    let to_string c = Printf.sprintf
      "{ down = %B; \
         no_stp = %B; \
         no_recv = %B; \
         no_recv_stp = %B; \
         no_flood = %B; \
         no_fwd = %B; \
         no_packet_in = %B }"
      c.down
      c.no_stp
      c.no_recv
      c.no_recv_stp
      c.no_flood
      c.no_fwd
      c.no_packet_in

    let of_int d =
      { down = test_bit 0 d;
        no_stp = test_bit 1 d;
        no_recv = test_bit 2 d;
        no_recv_stp = test_bit 3 d;
        no_flood = test_bit 4 d;
        no_fwd = test_bit 5 d;
        no_packet_in = test_bit 6 d
      }

    let size_of _ = 4
    let to_int _ = failwith "NYI: PortConfig.to_int"

  end

  module PortState = struct

    type t =
      { down : bool  (* No physical link present. *)
      ; stp_listen : bool
      ; stp_forward : bool
      ; stp_block : bool
      ; stp_mask : bool }

    let to_string p = Printf.sprintf
      "{ down = %B; \
         stp_listen = %B; \
         stp_forward = %B; \
         stp_block = %B; \
         stp_mask = %B }"
      p.down
      p.stp_listen
      p.stp_forward
      p.stp_block
      p.stp_mask

    (* MJR: GAH, the enum values from OF1.0 make NO SENSE AT ALL. Two of
       them have the SAME value, and the rest make no sense as bit
       vectors. Only portStateDown is parsed correctly ATM *)
    let of_int d =
      { down = test_bit 0 d
      ; stp_listen = false
      ; stp_forward = false
      ; stp_block = false
      ; stp_mask = false }

    let to_int _ = failwith "NYI: PortState.to_int"
    let size_of _ = 4

  end

  module PortFeatures = struct

    type t =
      { f_10MBHD : bool (* 10 Mb half-duplex rate support. *)
      ; f_10MBFD : bool (* 10 Mb full-duplex rate support. *)
      ; f_100MBHD : bool (* 100 Mb half-duplex rate support. *)
      ; f_100MBFD : bool (* 100 Mb full-duplex rate support. *)
      ; f_1GBHD : bool (* 1 Gb half-duplex rate support. *)
      ; f_1GBFD : bool (* 1 Gb full-duplex rate support. *)
      ; f_10GBFD : bool (* 10 Gb full-duplex rate support. *)
      ; copper : bool (* Copper medium. *)
      ; fiber : bool (* Fiber medium. *)
      ; autoneg : bool (* Auto-negotiation. *)
      ; pause : bool (* Pause. *)
      ; pause_asym : bool (* Asymmetric pause. *)
      }

    let to_string p = Printf.sprintf
      "{ f_10MBHD = %B; \
         f_10MBFD = %B; \
         f_100MBHD = %B; \
         f_100MBFD = %B; \
         f_1GBHD = %B; \
         f_1GBFD = %B; \
         f_10GBFD = %B; \
         copper = %B; \
         fiber = %B; \
         autoneg = %B; \
         pause = %B; \
         pause_asym = %B }"
      p.f_10MBHD
      p.f_10MBFD
      p.f_100MBHD
      p.f_100MBFD
      p.f_1GBHD
      p.f_1GBFD
      p.f_10GBFD
      p.copper
      p.fiber
      p.autoneg
      p.pause
      p.pause_asym

    let size_of _ = 4
    let to_int _ = failwith "NYI: PortFeatures.to_int"

    let of_int bits =
      { f_10MBHD = test_bit 0 bits
      ; f_10MBFD = test_bit 1 bits
      ; f_100MBHD = test_bit 2 bits
      ; f_100MBFD = test_bit 3 bits
      ; f_1GBHD = test_bit 4 bits
      ; f_1GBFD = test_bit 5 bits
      ; f_10GBFD = test_bit 6 bits
      ; copper = test_bit 7 bits
      ; fiber = test_bit 8 bits
      ; autoneg = test_bit 9 bits
      ; pause = test_bit 10 bits
      ; pause_asym = test_bit 11 bits }

  end

  type t =
    { port_no : portId
    ; hw_addr : dlAddr
    ; name : string
    ; config : PortConfig.t
    ; state : PortState.t
    ; curr : PortFeatures.t
    ; advertised : PortFeatures.t
    ; supported : PortFeatures.t
    ; peer : PortFeatures.t }

  cstruct ofp_phy_port {
    uint16_t port_no;
    uint8_t hw_addr[6];
    uint8_t name[16]; (* OFP_MAX_PORT_NAME_LEN, Null-terminated *)
    uint32_t config; (* Bitmap of OFPPC_* flags. *)
    uint32_t state; (* Bitmap of OFPPS_* flags. *)
    (* Bitmaps of OFPPF_* that describe features. All bits zeroed if
     * unsupported or unavailable. *)
    uint32_t curr; (* Current features. *)
    uint32_t advertised; (* SwitchFeatures being advertised by the port. *)
    uint32_t supported; (* SwitchFeatures supported by the port. *)
    uint32_t peer (* SwitchFeatures advertised by peer. *)
  } as big_endian

  let to_string d = Printf.sprintf
    "{ port_no = %s; hw_addr = %s; name = %s; config = %s; state = %s; \
       curr = %s; advertised = %s; supported = %s; peer = %s }"
    (string_of_portId d.port_no)
    (string_of_dlAddr d.hw_addr)
    d.name
    (PortConfig.to_string d.config)
    (PortState.to_string d.state)
    (PortFeatures.to_string d.curr)
    (PortFeatures.to_string d.advertised)
    (PortFeatures.to_string d.supported)
    (PortFeatures.to_string d.peer)

  let parse (bits : Cstruct.t) : t =
    let portDescPortNo = get_ofp_phy_port_port_no bits in
    let hw_addr = Packet.mac_of_bytes (Cstruct.to_string (get_ofp_phy_port_hw_addr bits)) in
    let name = Cstruct.to_string (get_ofp_phy_port_name bits) in
    let config = PortConfig.of_int (get_ofp_phy_port_config bits) in
    let state = PortState.of_int (get_ofp_phy_port_state bits) in
    let curr = PortFeatures.of_int (get_ofp_phy_port_curr bits) in
    let advertised = PortFeatures.of_int (get_ofp_phy_port_advertised bits) in
    let supported = PortFeatures.of_int (get_ofp_phy_port_supported bits) in
    let peer = PortFeatures.of_int (get_ofp_phy_port_peer bits) in
    { port_no = portDescPortNo
    ; hw_addr = hw_addr
    ; name = name
    ; config = config
    ; state = state
    ; curr = curr
    ; advertised = advertised
    ; supported = supported
    ; peer = peer }

  let size_of _ = sizeof_ofp_phy_port

  let marshal _ _ = failwith "NYI: PortDescription.marshal"

end

module PortStatus = struct

  module ChangeReason = struct

    type t =
      | Add
      | Delete
      | Modify

    cenum ofp_port_reason {
      OFPPR_ADD;
      OFPPR_DELETE;
      OFPPR_MODIFY
    } as uint8_t

    let of_int d = 
      let reason_code = int_to_ofp_port_reason d in
      match reason_code with
      | Some OFPPR_ADD -> Add
      | Some OFPPR_DELETE -> Delete
      | Some OFPPR_MODIFY -> Modify
      | None ->
        raise (Unparsable
          (Printf.sprintf "unexpected ofp_port_reason %d" d))

    let to_int reason = 
      let reason_code = match reason with
        | Add -> OFPPR_ADD
        | Delete -> OFPPR_DELETE
        | Modify -> OFPPR_MODIFY
        in
      ofp_port_reason_to_int reason_code

    let to_string reason = match reason with
        | Add -> "Add"
        | Delete -> "Delete"
        | Modify -> "Modify"

    let size_of _ = 1

  end

  type t =
    { reason : ChangeReason.t
    ; desc : PortDescription.t }

  cstruct ofp_port_status {
      uint8_t reason;               (* One of OFPPR_* *)
      uint8_t pad[7]
  } as big_endian

  let to_string status = Printf.sprintf
    "{ reason = %s; desc = %s }"
    (ChangeReason.to_string status.reason)
    (PortDescription.to_string status.desc)

  let parse bits =
    let reason = ChangeReason.of_int (get_ofp_port_status_reason bits) in
    let _ = Cstruct.shift bits sizeof_ofp_port_status in
    let description = PortDescription.parse bits in
    { reason = reason
    ; desc = description }

  let to_string ps =
    let {reason; desc} = ps in
    Printf.sprintf "PortStatus %s %d"
      (ChangeReason.to_string reason)
      desc.PortDescription.port_no

  let size_of status = 
    ChangeReason.size_of status.reason + PortDescription.size_of status.desc

  let marshal _ _ = failwith "NYI: PortStatus.marshal"

end

module SwitchFeatures = struct

  module Capabilities = struct

    type t =
      { flow_stats : bool
      ; table_stats : bool
      ; port_stats : bool
      ; stp : bool
      ; ip_reasm : bool
      ; queue_stats : bool
      ; arp_match_ip : bool }

    let size_of _ = 4

    let to_string c = Printf.sprintf
      "{ flow_stats = %B; \
         table_stats = %B; \
         port_stats = %B; \
         stp = %B; \
         ip_reasm = %B; \
         queue_stats = %B; \
         arp_mat_ip = %B }"
      c.flow_stats
      c.table_stats
      c.port_stats
      c.stp
      c.ip_reasm
      c.queue_stats
      c.arp_match_ip

    let of_int d =
      { arp_match_ip = test_bit 7 d
      ; queue_stats = test_bit 6 d
      ; ip_reasm = test_bit 5 d
      ; stp = test_bit 3 d
      ; port_stats = test_bit 2 d
      ; table_stats = test_bit 1 d
      ; flow_stats = test_bit 0 d }

    let to_int c =
      let bits = Int32.zero in
      let bits = bit bits 7 c.arp_match_ip in
      let bits = bit bits 6 c.queue_stats in
      let bits = bit bits 5 c.ip_reasm in
      let bits = bit bits 3 c.stp in
      let bits = bit bits 2 c.port_stats in
      let bits = bit bits 1 c.table_stats in
      let bits = bit bits 0 c.flow_stats in
      bits

  end

  module SupportedActions = struct

    type t =
      { output : bool
      ; set_vlan_id : bool
      ; set_vlan_pcp : bool
      ; strip_vlan : bool
      ; set_dl_src : bool
      ; set_dl_dst : bool
      ; set_nw_src : bool
      ; set_nw_dst : bool
      ; set_nw_tos : bool
      ; set_tp_src : bool
      ; set_tp_dst : bool
      ; enqueue : bool
      ; vendor : bool }

    let size_of _ = 4

    let to_string a = Printf.sprintf
      "{ output = %B; \
         set_vlan_id = %B; \
         set_vlan_pcp = %B; \
         strip_vlan = %B; \
         set_dl_src = %B; \
         set_dl_dst = %B; \
         set_nw_src = %B; \
         set_nw_dst = %B; \
         set_nw_tos = %B; \
         set_tp_src = %B; \
         set_tp_dst = %B; \
         enqueue = %B; \
         vendor = %B }"
      a.output
      a.set_vlan_id
      a.set_vlan_pcp
      a.strip_vlan
      a.set_dl_src
      a.set_dl_dst
      a.set_nw_src
      a.set_nw_dst
      a.set_nw_tos
      a.set_tp_src
      a.set_tp_dst
      a.enqueue
      a.vendor

    let of_int d =
      { output = test_bit 0 d
      ; set_vlan_id = test_bit 1 d
      ; set_vlan_pcp = test_bit 2 d
      ; strip_vlan = test_bit 3 d
      ; set_dl_src = test_bit 4 d
      ; set_dl_dst = test_bit 5 d
      ; set_nw_src = test_bit 6 d
      ; set_nw_dst = test_bit 7 d
      ; set_nw_tos = test_bit 8 d
      ; set_tp_src = test_bit 9 d
      ; set_tp_dst = test_bit 10 d
      ; enqueue = test_bit 11 d
      ; vendor = test_bit 12 d }

    let to_int a =
      let bits = Int32.zero in
      let bits = bit bits 0 a.output in
      let bits = bit bits 1 a.set_vlan_id in
      let bits = bit bits 2 a.set_vlan_pcp in
      let bits = bit bits 3 a.strip_vlan in
      let bits = bit bits 4 a.set_dl_src in
      let bits = bit bits 5 a.set_dl_dst in
      let bits = bit bits 6 a.set_nw_src in
      let bits = bit bits 7 a.set_nw_dst in
      let bits = bit bits 8 a.set_nw_tos in
      let bits = bit bits 9 a.set_tp_src in
      let bits = bit bits 10 a.set_tp_dst in
      let bits = bit bits 11 a.enqueue in
      let bits = bit bits 12 a.vendor in
      bits

  end

  type t =
    { switch_id : int64
    ; num_buffers : int32
    ; num_tables : int8
    ; supported_capabilities : Capabilities.t
    ; supported_actions : SupportedActions.t
    ; ports : PortDescription.t list }

  cstruct ofp_switch_features {
    uint64_t datapath_id;
    uint32_t n_buffers;
    uint8_t n_tables;
    uint8_t pad[3];
    uint32_t capabilities;
    uint32_t action
  } as big_endian

  let to_string feats = Printf.sprintf
    "{ switch_id = %Ld; num_buffers = %s; num_tables = %d; \
       supported_capabilities = %s; supported_actions = %s; ports = %s }"
    feats.switch_id
    (Int32.to_string feats.num_buffers)
    feats.num_tables
    (Capabilities.to_string feats.supported_capabilities)
    (SupportedActions.to_string feats.supported_actions)
    (Frenetic_Misc.string_of_list PortDescription.to_string feats.ports)

  let parse (buf : Cstruct.t) : t =
    let switch_id = get_ofp_switch_features_datapath_id buf in
    let num_buffers = get_ofp_switch_features_n_buffers buf in
    let num_tables = get_ofp_switch_features_n_tables buf in
    let supported_capabilities = Capabilities.of_int
      (get_ofp_switch_features_capabilities buf) in
    let supported_actions = SupportedActions.of_int
      (get_ofp_switch_features_action buf) in
    let buf = Cstruct.shift buf sizeof_ofp_switch_features in
    let portIter =
      Cstruct.iter
        (fun buf -> Some PortDescription.sizeof_ofp_phy_port)
        PortDescription.parse
        buf in
    let ports = Cstruct.fold (fun acc bits -> bits :: acc) portIter [] in
    { switch_id
    ; num_buffers
    ; num_tables
    ; supported_capabilities
    ; supported_actions
    ; ports }

  let size_of feats = 
    sizeof_ofp_switch_features 
    + sum (List.map PortDescription.size_of feats.ports)

  let marshal _ _ = failwith "NYI: SwitchFeatures.marshal"

end

module FlowMod = struct

  module Command = struct

    type t =
      | AddFlow
      | ModFlow
      | ModStrictFlow
      | DeleteFlow
      | DeleteStrictFlow

    cenum ofp_flow_mod_command {
      OFPFC_ADD;
      OFPFC_MODIFY;
      OFPFC_MODIFY_STRICT;
      OFPFC_DELETE;
      OFPFC_DELETE_STRICT
    } as uint16_t

    let size_of _ = 2

    let to_string cmd = match cmd with
      | AddFlow -> "AddFlow"
      | ModFlow -> "ModFlow"
      | ModStrictFlow -> "ModStrictFlow"
      | DeleteFlow -> "DeleteFlow"
      | DeleteStrictFlow -> "DeleteStrictFlow"

    let to_int t = match t with
      | AddFlow -> ofp_flow_mod_command_to_int OFPFC_ADD
      | ModFlow -> ofp_flow_mod_command_to_int OFPFC_MODIFY
      | ModStrictFlow -> ofp_flow_mod_command_to_int OFPFC_MODIFY_STRICT
      | DeleteFlow -> ofp_flow_mod_command_to_int OFPFC_DELETE
      | DeleteStrictFlow -> ofp_flow_mod_command_to_int OFPFC_DELETE_STRICT

    let of_int d =
      let command_code = int_to_ofp_flow_mod_command d in
      match command_code with
      | Some OFPFC_ADD -> AddFlow
      | Some OFPFC_MODIFY -> ModFlow
      | Some OFPFC_MODIFY_STRICT -> ModStrictFlow
      | Some OFPFC_DELETE -> DeleteFlow
      | Some OFPFC_DELETE_STRICT -> DeleteStrictFlow
      | None -> raise 
        (Unparsable (Printf.sprintf "unexpected ofp_flow_mod_command %d" d))

  end

  module Timeout = struct

    type t =
      | Permanent
      | ExpiresAfter of int16

    let to_string t = match t with
      | Permanent -> "Permanent"
      | ExpiresAfter n -> Printf.sprintf "ExpiresAfter %d" n

    let size_of _ = 2

    let to_int x = match x with
      | Permanent -> 0
      | ExpiresAfter w -> w

    let of_int d = 
      if d = 0 then Permanent else ExpiresAfter d

  end

  type t =
    { mod_cmd : Command.t
    ; match_ : Match.t
    ; priority : priority
    ; actions : Action.sequence
    ; cookie : int64
    ; idle_timeout : Timeout.t
    ; hard_timeout : Timeout.t
    ; notify_when_removed : bool
    ; apply_to_packet : bufferId option
    ; out_port : PseudoPort.t option
    ; check_overlap : bool }

  cstruct ofp_flow_mod {
    uint64_t cookie;
    uint16_t command;
    uint16_t idle_timeout;
    uint16_t hard_timeout;
    uint16_t priority;
    uint32_t buffer_id;
    uint16_t out_port;
    uint16_t flags
  } as big_endian

  let to_string m = Printf.sprintf
    "{ mod_cmd = %s; match = %s; priority = %s; actions = %s; cookie = %Ld;\
       idle_timeout = %s; hard_timeout = %s; notify_when_removed = %B;\
       apply_to_packet = %s; out_port = %s; check_overlap = %B }"
    (Command.to_string m.mod_cmd)
    (Match.to_string m.match_)
    (string_of_priority m.priority)
    (Action.sequence_to_string m.actions)
    m.cookie
    (Timeout.to_string m.idle_timeout)
    (Timeout.to_string m.hard_timeout)
    m.notify_when_removed
    (Frenetic_Misc.string_of_option string_of_bufferId m.apply_to_packet)
    (Frenetic_Misc.string_of_option PseudoPort.to_string m.out_port)
    m.check_overlap

  let size_of msg =
    (Match.size_of msg.match_)
    + sizeof_ofp_flow_mod
    + (Action.size_of_sequence msg.actions)

  let parse _ = failwith "NYI: FlowMod.parse"

  let flags_to_int (check_overlap : bool) (notify_when_removed : bool) =
    (if check_overlap then 1 lsl 1 else 0) lor
      (if notify_when_removed then 1 lsl 0 else 0)

  let marshal m bits =
    let bits = Cstruct.shift bits (Match.marshal m.match_ bits) in
    set_ofp_flow_mod_cookie bits (m.cookie);
    set_ofp_flow_mod_command bits (Command.to_int m.mod_cmd);
    set_ofp_flow_mod_idle_timeout bits (Timeout.to_int m.idle_timeout);
    set_ofp_flow_mod_hard_timeout bits (Timeout.to_int m.hard_timeout);
    set_ofp_flow_mod_priority bits (m.priority);
    set_ofp_flow_mod_buffer_id bits
      (match m.apply_to_packet with
        | None -> -1l
        | Some bufId -> bufId);
    set_ofp_flow_mod_out_port bits (PseudoPort.marshal_optional m.out_port);
    set_ofp_flow_mod_flags bits
      (flags_to_int m.check_overlap m.notify_when_removed);
    let bits = Cstruct.shift bits sizeof_ofp_flow_mod in
    let _ = List.fold_left
      (fun bits act ->
        Cstruct.shift bits (Action.marshal act bits))
      bits
      (Action.move_controller_last m.actions) in
    size_of m

end

module PacketIn = struct

  module Reason = struct

    type t =
      | NoMatch
      | ExplicitSend

    cenum ofp_reason {
      NO_MATCH = 0;
      ACTION = 1
    } as uint8_t

    let to_string r = match r with
      | NoMatch -> "NoMatch"
      | ExplicitSend -> "ExplicitSend"

    let of_int d = match int_to_ofp_reason d with
      | Some NO_MATCH -> NoMatch
      | Some ACTION -> ExplicitSend
      | None -> raise (Unparsable (sprintf "bad reason in packet_in (%d)" d))

    let to_int r = match r with
      | NoMatch -> ofp_reason_to_int NO_MATCH
      | ExplicitSend -> ofp_reason_to_int ACTION

    let size_of _ = 1

  end

  type t =
    { buffer_id : bufferId option
    ; total_len : int16
    ; port : portId
    ; reason : Reason.t
    ; packet :  bytes }

  cstruct ofp_packet_in {
    uint32_t buffer_id;
    uint16_t total_len;
    uint16_t in_port;
    uint8_t reason;
    uint8_t pad
  } as big_endian

  let to_string pin = Printf.sprintf
    "{ buffer_id = %s; total_len = %d; port = %s; reason = %s; \
       packet = <bytes> }"
    (Frenetic_Misc.string_of_option string_of_bufferId pin.buffer_id)
    pin.total_len
    (string_of_portId pin.port)
    (Reason.to_string pin.reason)

  let parse bits =
    let buf_id = match get_ofp_packet_in_buffer_id bits with
      | -1l -> None
      | n -> Some n in
    let total_len = get_ofp_packet_in_total_len bits in
    let in_port = get_ofp_packet_in_in_port bits in
    let reason = Reason.of_int (get_ofp_packet_in_reason bits) in
    { buffer_id = buf_id
    ; total_len = total_len
    ; port = in_port
    ; reason = reason
    ; packet = Cstruct.shift bits sizeof_ofp_packet_in }

  let size_of pin = sizeof_ofp_packet_in + Cstruct.len pin.packet

  let marshal _ _ = failwith "NYI: PacketIn.marshal"

end

module PacketOut = struct

  module Payload = struct

    type t =
      | Buffer of bufferId
      | Packet of bytes

    let to_string p = match p with
      | Buffer id -> Printf.sprintf "Buffer %s" (string_of_bufferId id)
      | Packet _ -> "Packet <bytes>"

    let size_of p = match p with
      | Buffer _ -> 0
      | Packet bytes -> Cstruct.len bytes

    let marshal p out = 
      let _ = match p with
        | Buffer n -> ()
        | Packet bytes -> Cstruct.blit bytes 0 out 0 (Cstruct.len bytes)
        in
      size_of p

    let parse _ = failwith "NYI: PacketOut.Payload.parse"

  end

  type t =
    { buf_or_bytes : Payload.t
    ; port_id : portId option
    ; actions : Action.sequence }

  cstruct ofp_packet_out {
    uint32_t buffer_id;
    uint16_t in_port;
    uint16_t actions_len
  } as big_endian

  let to_string out = Printf.sprintf
    "{ buf_or_bytes = %s; port_id = %s; actions = %s }"
    (Payload.to_string out.buf_or_bytes)
    (Frenetic_Misc.string_of_option string_of_portId out.port_id)
    (Action.sequence_to_string out.actions)

  let size_of (pkt_out : t) : int =
    sizeof_ofp_packet_out +
      (Action.size_of_sequence pkt_out.actions) +
      (Payload.size_of pkt_out.buf_or_bytes)

  let marshal (pkt_out : t) (buf : Cstruct.t) : int =
    set_ofp_packet_out_buffer_id buf
      (match pkt_out.buf_or_bytes with
        | Payload.Buffer n -> n
        | _ -> -1l);
    set_ofp_packet_out_in_port buf
      (PseudoPort.marshal_optional
        (match pkt_out.port_id with
          | Some id -> Some (PseudoPort.PhysicalPort id)
          | None -> None));
    set_ofp_packet_out_actions_len buf
      (Action.size_of_sequence pkt_out.actions);
    let buf = List.fold_left
      (fun buf act -> Cstruct.shift buf (Action.marshal act buf))
      (Cstruct.shift buf sizeof_ofp_packet_out)
      (Action.move_controller_last pkt_out.actions) in
    let _ = Payload.marshal pkt_out.buf_or_bytes buf in
    size_of pkt_out

  let parse _ = failwith "NYI: PacketOut.parse"

end

module StatsRequest = struct

  module IndividualFlowRequest = struct

    type t =
      { of_match : Match.t
      ; table_id : table_id
      ; port : PseudoPort.t option }

    cstruct ofp_flow_stats_request {
      uint8_t of_match[40];
      uint8_t table_id;
      uint8_t pad;
      uint16_t out_port
    } as big_endian

    let size_of _ = sizeof_ofp_flow_stats_request

    let to_string req =
      Printf.sprintf "{of_match = %s; table_id = %d; port = %s}"
        (Match.to_string req.of_match)
        req.table_id
        (Frenetic_Misc.string_of_option PseudoPort.to_string req.port)

    let marshal req out =
      let _ = Match.marshal req.of_match out in
      set_ofp_flow_stats_request_table_id out req.table_id;
      begin match req.port with
      | Some port ->
        set_ofp_flow_stats_request_out_port out (PseudoPort.marshal port);
      | None ->
        let open PseudoPort in
        let port_code = ofp_port_to_int OFPP_NONE in
        set_ofp_flow_stats_request_out_port out port_code
      end;
      size_of req

    let parse _ = failwith "NYI: IndividualFlowRequest.parse"

  end

  module AggregateFlowRequest = struct

    type t = { of_match : Match.t
             ; table_id : table_id
             ; port : PseudoPort.t option }

    cstruct ofp_aggregate_stats_request {
      uint8_t of_match[40];
      uint8_t table_id;
      uint8_t pad;
      uint16_t out_port
    } as big_endian

    let to_string req =
      Printf.sprintf "{of_match = %s; table_id = %d; port = %s}"
        (Match.to_string req.of_match)
        req.table_id
        (Frenetic_Misc.string_of_option PseudoPort.to_string req.port)

    let size_of _ = sizeof_ofp_aggregate_stats_request

    let marshal req out =
      let _ = Match.marshal req.of_match out in
      set_ofp_aggregate_stats_request_table_id out req.table_id;
      begin match req.port with
      | Some port ->
        set_ofp_aggregate_stats_request_out_port out (PseudoPort.marshal port);
      | None ->
        let open PseudoPort in
        let port_code = ofp_port_to_int OFPP_NONE in
        set_ofp_aggregate_stats_request_out_port out port_code
      end;
      size_of req

    let parse _ = failwith "NYI: AggregateFlowRequest.parse"

  end

  type t =
  | DescriptionReq
  | IndividualFlowReq of IndividualFlowRequest.t
  | AggregateFlowReq of AggregateFlowRequest.t
  | TableReq
  | PortReq of PseudoPort.t
  (* TODO(cole): queue and vendor stats requests. *)

  cstruct ofp_stats_request {
    uint16_t req_type;
    uint16_t flags
  } as big_endian

  let to_string msg = match msg with
    | DescriptionReq -> "DescriptionReq"
    | IndividualFlowReq req ->
      "IndividualFlowReq " ^ (IndividualFlowRequest.to_string req)
    | AggregateFlowReq req ->
      "AggregateFlowReq " ^ (AggregateFlowRequest.to_string req)
    | TableReq -> "TableReq"
    | PortReq p -> "PortReq " ^ (PseudoPort.to_string p)

  let size_of msg =
    let header_size = sizeof_ofp_stats_request in
    match msg with
    | DescriptionReq -> header_size
    | IndividualFlowReq req ->
      header_size + (IndividualFlowRequest.size_of req)
    | _ ->
      (* CNS: Please implement me!! *)
      failwith (Printf.sprintf "NYI: StatsRequest.size_of %s" (to_string msg))

  let ofp_stats_type_of_request req = match req with
    | DescriptionReq -> OFPST_DESC
    | IndividualFlowReq _ -> OFPST_FLOW
    | AggregateFlowReq _ -> OFPST_AGGREGATE
    | TableReq -> OFPST_TABLE
    | PortReq _ -> OFPST_PORT

  let marshal msg out =
    let req_type = ofp_stats_type_of_request msg in
    let flags = 0x0 in
    set_ofp_stats_request_req_type out (ofp_stats_types_to_int req_type);
    set_ofp_stats_request_flags out flags;
    let out' = Cstruct.shift out sizeof_ofp_stats_request in
    match msg with
    | DescriptionReq -> sizeof_ofp_stats_request
    | IndividualFlowReq req -> IndividualFlowRequest.marshal req out'
    | AggregateFlowReq req -> AggregateFlowRequest.marshal req out'
    | _ ->
      failwith (Printf.sprintf "NYI: StatsRequest.marshal %s" (to_string msg))

  let parse _ = failwith "NYI: StatsRequest.parse"

end

module StatsReply = struct

  module DescriptionStats = struct

    type t =
      { manufacturer : string
      ; hardware : string
      ; software : string
      ; serial_number : string
      ; datapath : string }

    let desc_str_len = 256
    let serial_num_len = 32

    cstruct ofp_desc_stats {
      uint8_t mfr_desc[256];
      uint8_t hw_desc[256];
      uint8_t sw_desc[256];
      uint8_t serial_num[32];
      uint8_t dp_desc[256]
    } as big_endian

    let mkString bits size =
      let new_string = String.create size in
      Cstruct.blit_to_string bits 0 new_string 0 size;
      new_string

    let parse bits =
      let mfr_desc = mkString (get_ofp_desc_stats_mfr_desc bits) desc_str_len in
      let hw_desc = mkString (get_ofp_desc_stats_hw_desc bits) desc_str_len in
      let sw_desc = mkString (get_ofp_desc_stats_sw_desc bits) desc_str_len in
      let serial_num =
        mkString (get_ofp_desc_stats_serial_num bits) serial_num_len in
      let dp_desc = mkString (get_ofp_desc_stats_dp_desc bits) desc_str_len in
      { manufacturer = mfr_desc
      ; hardware = hw_desc
      ; software = sw_desc
      ; serial_number = serial_num
      ; datapath = dp_desc }

    let size_of _ = sizeof_ofp_desc_stats

    let to_string desc = Printf.sprintf
      "{ manufacturer = %s; hardware = %s; software = %s;\
         serial_number = %s; datapath = %s}"
      desc.manufacturer desc.hardware desc.software
      desc.serial_number desc.datapath

    let marshal _ _ = failwith "NYI: DescriptionStats.marshal"

  end

  module IndividualFlowStats = struct

    type t =
      { table_id : table_id
      ; of_match : Match.t
      ; duration_sec : int
      ; duration_nsec : int
      ; priority : priority
      ; idle_timeout : int
      ; hard_timeout : int
      ; cookie : Int64.t
      ; packet_count : Int64.t
      ; byte_count : Int64.t
      ; actions : Action.sequence }

    cstruct ofp_flow_stats {
      uint16_t length;
      uint8_t table_id;
      uint8_t pad;
      uint8_t of_match[40]; (* Size of struct ofp_match. *)
      uint32_t duration_sec;
      uint32_t duration_nsec;
      uint16_t priority;
      uint16_t idle_timeout;
      uint16_t hard_timeout;
      uint8_t pad2[6];
      uint64_t cookie;
      uint64_t packet_count;
      uint64_t byte_count
    } as big_endian

    let size_of _ = failwith "NYI: IndividualFlowStats.size_of"
    let marshal _ _ = failwith "NYI: IndividualFlowStats.marshal"

    let to_string stats = Printf.sprintf
      "{ table_id = %d; of_match = %s; duration_sec = %d; duration_nsec = %d\
         priority = %d; idle_timeout = %d; hard_timeout = %d; cookie = %Ld\
         packet_count = %Ld; byte_count = %Ld; actions = %s }"
      stats.table_id
      (Match.to_string stats.of_match)
      stats.duration_sec
      stats.duration_nsec
      stats.priority
      stats.idle_timeout
      stats.hard_timeout
      stats.cookie
      stats.packet_count
      stats.byte_count
      (Action.sequence_to_string stats.actions)

    let sequence_to_string = Frenetic_Misc.string_of_list to_string

    let _parse bits =
      (* length = flow stats + actions *)
      let length = get_ofp_flow_stats_length bits in
      let flow_stats_size = sizeof_ofp_flow_stats in
      let actions_size = length - flow_stats_size in

      (* get fields *)
      let table_id = get_ofp_flow_stats_table_id bits in
      let of_match = Match.parse (get_ofp_flow_stats_of_match bits) in
      let duration_sec = get_ofp_flow_stats_duration_sec bits in
      let duration_nsec = get_ofp_flow_stats_duration_nsec bits in
      let priority = get_ofp_flow_stats_priority bits in
      let idle_timeout = get_ofp_flow_stats_idle_timeout bits in
      let hard_timeout = get_ofp_flow_stats_hard_timeout bits in
      let cookie = get_ofp_flow_stats_cookie bits in
      let packet_count = get_ofp_flow_stats_packet_count bits in
      let byte_count = get_ofp_flow_stats_byte_count bits in

      (* get actions *)
      let bits_after_flow_stats = Cstruct.shift bits sizeof_ofp_flow_stats in
      let action_bits, rest =
        Cstruct.split bits_after_flow_stats actions_size in
      let actions = Action.parse_sequence action_bits in

      ( { table_id = table_id
        ; of_match = of_match
        ; duration_sec = Int32.to_int duration_sec
        ; duration_nsec = Int32.to_int duration_nsec
        ; priority = priority
        ; idle_timeout = idle_timeout
        ; hard_timeout = hard_timeout
        ; cookie = cookie
        ; packet_count = packet_count
        ; byte_count = byte_count
        ; actions = actions }
      , rest)

    let parse bits = fst (_parse bits)

    let rec parse_sequence bits =
      if Cstruct.len bits <= 0 then
        []
      else
        let (v, bits') = _parse bits in
        v :: parse_sequence bits'

  end

  module AggregateFlowStats = struct

    type t =
      { packet_count : Int64.t
      ; byte_count : Int64.t
      ; flow_count : int }

    let to_string stats = Printf.sprintf
      "{ packet_count = %Ld; byte_count = %Ld; flow_count = %d }"
      stats.packet_count
      stats.byte_count
      stats.flow_count

    let size_of _ = failwith "NYI: AggregateFlowStats.size_of"
    let parse _ = failwith "NYI: AggregateFlowStats.parse"
    let marshal _ _ = failwith "NYI: AggregateFlowStats.marshal"

  end

  module TableStats = struct

    type t =
      { table_id : table_id
      ; name : string
      ; wildcards : int32
      ; max_entries : int
      ; active_count : int
      ; lookup_count : int
      ; matched_count : int }

    let to_string stats = failwith "NYI: TableStats.to_string"
    let size_of _ = failwith "NYI: TableStats.size_of"
    let parse _ = failwith "NYI: TableStats.parse"
    let marshal _ _ = failwith "NYI: TableStats.marshal"

  end

  module PortStats = struct

    type t =
      { port_no : PseudoPort.t
      ; rx_packets : int
      ; tx_packets : int
      ; rx_bytes : int
      ; tx_bytes : int
      ; rx_dropped : int
      ; tx_dropped : int
      ; rx_errors : int
      ; tx_errors : int
      ; rx_frame_err : int
      ; rx_over_err : int
      ; rx_crc_err : int
      ; collisions : int }

    let to_string stats = failwith "NYI: PortStats.to_string"
    let size_of _ = failwith "NYI: PortStats.size_of"
    let parse _ = failwith "NYI: PortStats.parse"
    let marshal _ _ = failwith "NYI: PortStats.marshal"

  end

  type t =
    | DescriptionRep of DescriptionStats.t
    | IndividualFlowRep of IndividualFlowStats.t list
    | AggregateFlowRep of AggregateFlowStats.t
    | TableRep of TableStats.t
    | PortRep of PortStats.t

  cstruct ofp_stats_reply {
    uint16_t stats_type;
    uint16_t flags
  } as big_endian

  let to_string rep = match rep with
    | DescriptionRep stats -> DescriptionStats.to_string stats
    | IndividualFlowRep stats ->
      Frenetic_Misc.string_of_list IndividualFlowStats.to_string stats
    | AggregateFlowRep stats -> AggregateFlowStats.to_string stats
    | TableRep stats -> TableStats.to_string stats
    | PortRep stats -> PortStats.to_string stats

  let size_of _ = failwith "NYI: StatsReply.size_of"
  let marshal _ _ = failwith "NYI: StatsReply.marshal"

  let parse bits =
    let stats_type_code = get_ofp_stats_reply_stats_type bits in
    let body = Cstruct.shift bits sizeof_ofp_stats_reply in
    match int_to_ofp_stats_types stats_type_code with
    | Some OFPST_DESC -> DescriptionRep (DescriptionStats.parse body)
    | Some OFPST_FLOW ->
      IndividualFlowRep (IndividualFlowStats.parse_sequence body)
    | Some OFPST_AGGREGATE ->
      AggregateFlowRep (AggregateFlowStats.parse body)
    | Some OFPST_TABLE -> TableRep (TableStats.parse body)
    | Some OFPST_PORT -> PortRep (PortStats.parse body)
    | Some OFPST_QUEUE ->
      let msg = "NYI: OFPST_QUEUE ofp_stats_type in stats_reply" in
      raise (Unparsable msg)
    | Some OFPST_VENDOR ->
      let msg = "NYI: OFPST_VENDOR ofp_stats_type in stats_reply" in
      raise (Unparsable msg)
    | None ->
      let msg =
        sprintf "bad ofp_stats_type in stats_reply (%d)" stats_type_code in
      raise (Unparsable msg)

end

module Error = struct

  cstruct ofp_error_msg {
    uint16_t error_type;
    uint16_t error_code
  } as big_endian

  cenum ofp_error_type {
    OFPET_HELLO_FAILED;
    OFPET_BAD_REQUEST;
    OFPET_BAD_ACTION;
    OFPET_FLOW_MOD_FAILED;
    OFPET_PORT_MOD_FAILED;
    OFPET_QUEUE_OP_FAILED
  } as uint16_t

  module HelloFailed = struct

    type t =
      | Incompatible
      | Eperm

    cenum ofp_hello_failed_code {
      OFPHFC_INCOMPATIBLE;
      OFPHFC_EPERM
    } as uint16_t

    let of_int error_code =
      match int_to_ofp_hello_failed_code error_code with
      | Some OFPHFC_INCOMPATIBLE -> Incompatible
      | Some OFPHFC_EPERM -> Eperm
      | None ->
        let msg = "NYI: ofp_hello_failed_code in error" in
              raise (Unparsable msg)

    let to_string e = match e with
      | Incompatible -> "Incompatible"
      | Eperm -> "Eperm"

  end

  module BadRequest = struct

    type t =
      | BadVersion
      | BadType
      | BadStat
      | BadVendor
      | BadSubType
      | Eperm
      | BadLen
      | BufferEmpty
      | BufferUnknown

    cenum ofp_bad_request_code {
      OFPBRC_BAD_VERSION;
      OFPBRC_BAD_TYPE;
      OFPBRC_BAD_STAT;
      OFPBRC_BAD_VENDOR;
      OFPBRC_BAD_SUBTYPE;
      OFPBRC_EPERM;
      OFPBRC_BAD_LEN;
      OFPBRC_BUFFER_EMPTY;
      OFPBRC_BUFFER_UNKNOWN
    } as uint16_t

    let of_int error_code =
      match int_to_ofp_bad_request_code error_code with
      | Some OFPBRC_BAD_VERSION -> BadVersion
      | Some OFPBRC_BAD_TYPE -> BadType
      | Some OFPBRC_BAD_STAT -> BadStat
      | Some OFPBRC_BAD_VENDOR -> BadVendor
      | Some OFPBRC_BAD_SUBTYPE -> BadSubType
      | Some OFPBRC_EPERM -> Eperm
      | Some OFPBRC_BAD_LEN -> BadLen
      | Some OFPBRC_BUFFER_EMPTY -> BufferEmpty
      | Some OFPBRC_BUFFER_UNKNOWN -> BufferUnknown
      | None ->
        let msg = "NYI: ofp_bad_request_code in error" in
              raise (Unparsable msg)

    let to_string r = match r with
      | BadVersion -> "BadVersion"
      | BadType -> "BadType"
      | BadStat -> "BadStat"
      | BadVendor -> "BadVendor"
      | BadSubType -> "BadSubType"
      | Eperm -> "Eperm"
      | BadLen -> "BadLen"
      | BufferEmpty -> "BufferEmpty"
      | BufferUnknown -> "BufferUnknown"

  end

  module BadAction = struct

    type t =
      | BadType
      | BadLen
      | BadVendor
      | BadVendorType
      | BadOutPort
      | BadArgument
      | Eperm
      | TooMany
      | BadQueue

    cenum ofp_bad_action_code {
      OFPBAC_BAD_TYPE;
      OFPBAC_BAD_LEN;
      OFPBAC_BAD_VENDOR;
      OFPBAC_BAD_VENDOR_TYPE;
      OFPBAC_BAD_OUT_PORT;
      OFPBAC_BAD_ARGUMENT;
      OFPBAC_EPERM;
      OFPBAC_TOO_MANY;
      OFPBAC_BAD_QUEUE
    } as uint16_t

    let of_int error_code =
      match int_to_ofp_bad_action_code error_code with
      | Some OFPBAC_BAD_TYPE -> BadType
      | Some OFPBAC_BAD_LEN -> BadLen
      | Some OFPBAC_BAD_VENDOR -> BadVendor
      | Some OFPBAC_BAD_VENDOR_TYPE -> BadVendorType
      | Some OFPBAC_BAD_OUT_PORT -> BadOutPort
      | Some OFPBAC_BAD_ARGUMENT -> BadArgument
      | Some OFPBAC_EPERM -> Eperm
      | Some OFPBAC_TOO_MANY -> TooMany
      | Some OFPBAC_BAD_QUEUE -> BadQueue
      | None ->
        let msg = "NYI: ofp_bad_action_code in error" in
              raise (Unparsable msg)

    let to_string a = match a with
      | BadType -> "BadType"
      | BadLen -> "BadLen"
      | BadVendor -> "BadVendor"
      | BadVendorType -> "BadVendorType"
      | BadOutPort -> "BadOutPort"
      | BadArgument -> "BadArgument"
      | Eperm -> "Eperm"
      | TooMany -> "TooMany"
      | BadQueue -> "BadQueue"

  end

  module FlowModFailed = struct

    type t =
      | AllTablesFull
      | Overlap
      | Eperm
      | BadEmergTimeout
      | BadCommand
      | Unsupported

    cenum ofp_flow_mod_failed_code {
      OFPFMFC_ALL_TABLES_FULL;
      OFPFMFC_OVERLAP;
      OFPFMFC_EPERM;
      OFPFMFC_BAD_EMERG_TIMEOUT;
      OFPFMFC_BAD_COMMAND;
      OFPFMFC_UNSUPPORTED
    } as uint16_t

    let of_int error_code =
      match int_to_ofp_flow_mod_failed_code error_code with
      | Some OFPFMFC_ALL_TABLES_FULL -> AllTablesFull
      | Some OFPFMFC_OVERLAP -> Overlap
      | Some OFPFMFC_EPERM -> Eperm
      | Some OFPFMFC_BAD_EMERG_TIMEOUT -> BadEmergTimeout
      | Some OFPFMFC_BAD_COMMAND -> BadCommand
      | Some OFPFMFC_UNSUPPORTED -> Unsupported
      | None ->
        let msg = "NYI: ofp_flow_mod_failed_code in error" in
              raise (Unparsable msg)

    let to_string f = match f with
      | AllTablesFull -> "AllTablesFull"
      | Overlap -> "Overlap"
      | Eperm -> "Eperm"
      | BadEmergTimeout -> "BadEmergTimeout"
      | BadCommand -> "BadCommand"
      | Unsupported -> "Unsupported"

  end

  module PortModFailed = struct

    type t =
      | BadPort
      | BadHwAddr

    cenum ofp_port_mod_failed_code {
      OFPPMFC_BAD_PORT;
      OFPPMFC_BAD_HW_ADDR
    } as uint16_t

    let of_int error_code =
      match int_to_ofp_port_mod_failed_code error_code with
      | Some OFPPMFC_BAD_PORT -> BadPort
      | Some OFPPMFC_BAD_HW_ADDR -> BadHwAddr
      | None ->
        let msg = "NYI: ofp_port_mod_failed_code in error" in
              raise (Unparsable msg)

    let to_string = function
      | BadPort -> "BadPort"
      | BadHwAddr -> "BadHwAddr"

  end

  module QueueOpFailed = struct

    type t =
      | BadPort
      | BadQueue
      | Eperm

    cenum ofp_queue_op_failed_code {
      OFPQOFC_BAD_PORT;
      OFPQOFC_BAD_QUEUE;
      OFPQOFC_EPERM
    } as uint16_t

    let of_int error_code =
      match int_to_ofp_queue_op_failed_code error_code with
      | Some OFPQOFC_BAD_PORT -> BadPort
      | Some OFPQOFC_BAD_QUEUE -> BadQueue
      | Some OFPQOFC_EPERM -> Eperm
      | None ->
        let msg = "NYI: ofp_queue_op_failed_code in error" in
              raise (Unparsable msg)

    let to_string = function
      | BadPort -> "BadPort"
      | BadQueue -> "BadQueue"
      | Eperm -> "Eperm"

  end

  (* Each error is composed of a pair (error_code, data) *)
  type t =
    | HelloFailed of HelloFailed.t * Cstruct.t
    | BadRequest of BadRequest.t * Cstruct.t
    | BadAction of BadAction.t * Cstruct.t
    | FlowModFailed of FlowModFailed.t * Cstruct.t
    | PortModFailed of PortModFailed.t * Cstruct.t
    | QueueOpFailed of QueueOpFailed.t  * Cstruct.t

  let parse bits =
    let error_type = get_ofp_error_msg_error_type bits in
    let error_code = get_ofp_error_msg_error_code bits in
    let body = Cstruct.shift bits sizeof_ofp_error_msg in
    match int_to_ofp_error_type error_type with
    | Some OFPET_HELLO_FAILED ->
      HelloFailed ((HelloFailed.of_int error_code), body)
    | Some OFPET_BAD_REQUEST ->
      BadRequest ((BadRequest.of_int error_code), body)
    | Some OFPET_BAD_ACTION ->
      BadAction ((BadAction.of_int error_code), body)
    | Some OFPET_FLOW_MOD_FAILED ->
      FlowModFailed ((FlowModFailed.of_int error_code), body)
    | Some OFPET_PORT_MOD_FAILED ->
      PortModFailed ((PortModFailed.of_int error_code), body)
    | Some OFPET_QUEUE_OP_FAILED ->
      QueueOpFailed ((QueueOpFailed.of_int error_code), body)
    | None ->
      let msg =
        sprintf "bad ofp_error_type in ofp_error_msg (%d)" error_type in
      raise(Unparsable msg)

  let to_string = function
    | HelloFailed (code, _) -> 
      "HelloFailed (" ^ (HelloFailed.to_string code) ^ ", <data>)"
    | BadRequest (code, _) -> 
      "BadRequest (" ^ (BadRequest.to_string code) ^ ", <data>)"
    | BadAction (code, _) -> 
      "BadAction (" ^ (BadAction.to_string code) ^ ", <data>)"
    | FlowModFailed (code, _) -> 
      "FlowModFailed (" ^ (FlowModFailed.to_string code) ^ ", <data>)"
    | PortModFailed (code, _) ->
      "PortModFailed (" ^ (PortModFailed.to_string code) ^ ", <data>)"
    | QueueOpFailed (code, _) ->
      "QueueOpFailed (" ^ (QueueOpFailed.to_string code) ^ ", <data>)"

end

module Message = struct
(* A subset of the OpenFlow 1.0 messages defined in Section 5.1 of the spec. *)

  cenum msg_code {
    HELLO;
    ERROR;
    ECHO_REQ;
    ECHO_RESP;
    VENDOR;
    FEATURES_REQ;
    FEATURES_RESP;
    GET_CONFIG_REQ;
    GET_CONFIG_RESP;
    SET_CONFIG;
    PACKET_IN;
    FLOW_REMOVED;
    PORT_STATUS;
    PACKET_OUT;
    FLOW_MOD;
    PORT_MOD;
    STATS_REQ;
    STATS_RESP;
    BARRIER_REQ;
    BARRIER_RESP;
    QUEUE_GET_CONFIG_REQ;
    QUEUE_GET_CONFIG_RESP
  } as uint8_t

  let string_of_msg_code code = match code with
    | HELLO -> "HELLO"
    | ERROR -> "ERROR"
    | ECHO_REQ -> "ECHO_REQ"
    | ECHO_RESP -> "ECHO_RESP"
    | VENDOR -> "VENDOR"
    | FEATURES_REQ -> "FEATURES_REQ"
    | FEATURES_RESP -> "FEATURES_RESP"
    | GET_CONFIG_REQ -> "GET_CONFIG_REQ"
    | GET_CONFIG_RESP -> "GET_CONFIG_RESP"
    | SET_CONFIG -> "SET_CONFIG"
    | PACKET_IN -> "PACKET_IN"
    | FLOW_REMOVED -> "FLOW_REMOVED"
    | PORT_STATUS -> "PORT_STATUS"
    | PACKET_OUT -> "PACKET_OUT"
    | FLOW_MOD -> "FLOW_MOD"
    | PORT_MOD -> "PORT_MOD"
    | STATS_REQ -> "STATS_REQ"
    | STATS_RESP -> "STATS_RESP"
    | BARRIER_REQ -> "BARRIER_REQ"
    | BARRIER_RESP -> "BARRIER_RESP"
    | QUEUE_GET_CONFIG_REQ -> "QUEUE_GET_CONFIG_REQ"
    | QUEUE_GET_CONFIG_RESP -> "QUEUE_GET_CONFIG_RESP"

  module Header = struct

    let ver : int = 0x01

    type t =
      { ver: int
      ; typ: msg_code
      ; len: int
      ; xid: int32 }

    cstruct ofp_header {
      uint8_t version;
      uint8_t typ;
      uint16_t length;
      uint32_t xid
    } as big_endian

    let size = sizeof_ofp_header
    let size_of _ = size
    let len hdr = hdr.len

    let marshal hdr out =
      set_ofp_header_version out hdr.ver;
      set_ofp_header_typ out (msg_code_to_int hdr.typ);
      set_ofp_header_length out hdr.len;
      set_ofp_header_xid out hdr.xid;
      size_of hdr

    (** [parse buf] assumes that [buf] has size [sizeof_ofp_header]. *)
    let parse body_buf =
      let buf = Cstruct.of_string body_buf in
      { ver = get_ofp_header_version buf;
        typ = begin match int_to_msg_code (get_ofp_header_typ buf) with
          | Some typ -> typ
          | None -> raise (Unparsable "unrecognized message code")
        end;
        len = get_ofp_header_length buf;
        xid = get_ofp_header_xid buf
      }

    let to_string hdr =
      Printf.sprintf "{ %d, %s, len = %d, xid = %d }"
        hdr.ver
        (string_of_msg_code hdr.typ)
        hdr.len
        (Int32.to_int hdr.xid)

  end

  type xid = int32

  type t =
    | Hello of bytes
    | ErrorMsg of Error.t
    | EchoRequest of bytes
    | EchoReply of bytes
    | SwitchFeaturesRequest
    | SwitchFeaturesReply of SwitchFeatures.t
    | FlowModMsg of FlowMod.t
    | PacketInMsg of PacketIn.t
    | PortStatusMsg of PortStatus.t
    | PacketOutMsg of PacketOut.t
    | BarrierRequest (* JNF: why not "BarrierRequestMsg"? *)
    | BarrierReply (* JNF: why not "BarrierReplyMsg"? *)
    | StatsRequestMsg of StatsRequest.t
    | StatsReplyMsg of StatsReply.t

  let delete_all_flows =
    let open FlowMod in
    FlowModMsg
      { mod_cmd = Command.DeleteFlow
      ; match_ = Match.all
      ; priority = 0
      ; actions = []
      ; cookie = 0L
      ; idle_timeout = Timeout.Permanent
      ; hard_timeout = Timeout.Permanent
      ; notify_when_removed = false
      ; apply_to_packet = None
      ; out_port = None
      ; check_overlap = false }

  let add_flow prio match_ actions =
    let open FlowMod in
    FlowModMsg
      { mod_cmd = Command.AddFlow
      ; match_ = match_
      ; priority = prio
      ; actions = actions
      ; cookie = 0L
      ; idle_timeout = Timeout.Permanent
      ; hard_timeout = Timeout.Permanent
      ; notify_when_removed = false
      ; apply_to_packet = None
      ; out_port = None
      ; check_overlap = false }

  let parse (hdr : Header.t) (body_buf : string) : (xid * t) =
    let buf = Cstruct.of_string body_buf in
    let msg = match hdr.Header.typ with
      | HELLO -> Hello buf
      | ERROR -> ErrorMsg (Error.parse buf)
      | ECHO_REQ -> EchoRequest buf
      | ECHO_RESP -> EchoReply buf
      | FEATURES_REQ -> SwitchFeaturesRequest
      | FEATURES_RESP -> SwitchFeaturesReply (SwitchFeatures.parse buf)
      | PACKET_IN -> PacketInMsg (PacketIn.parse buf)
      | PORT_STATUS -> PortStatusMsg (PortStatus.parse buf)
      | BARRIER_REQ -> BarrierRequest
      | BARRIER_RESP -> BarrierReply
      | STATS_RESP -> StatsReplyMsg (StatsReply.parse buf)
      | code -> raise (Ignored
        (Printf.sprintf "unexpected message type (%s)"
          (string_of_msg_code code)))
      in
    (hdr.Header.xid, msg)

  let msg_code_of_message (msg : t) : msg_code = match msg with
    | Hello _ -> HELLO
    | ErrorMsg _ -> ERROR
    | EchoRequest _ -> ECHO_REQ
    | EchoReply _ -> ECHO_RESP
    | SwitchFeaturesRequest -> FEATURES_REQ
    | SwitchFeaturesReply _ -> FEATURES_RESP
    | FlowModMsg _ -> FLOW_MOD
    | PacketOutMsg _ -> PACKET_OUT
    | PortStatusMsg _ -> PORT_STATUS
    | PacketInMsg _ -> PACKET_IN
    | BarrierRequest -> BARRIER_REQ
    | BarrierReply -> BARRIER_RESP
    | StatsRequestMsg _ -> STATS_REQ
    | StatsReplyMsg _ -> STATS_RESP

  let to_string (msg : t) : string = match msg with
    | Hello _ -> "Hello"
    | ErrorMsg _ -> "Error"
    | EchoRequest _ -> "EchoRequest"
    | EchoReply _ -> "EchoReply"
    | SwitchFeaturesRequest -> "SwitchFeaturesRequest"
    | SwitchFeaturesReply _ -> "SwitchFeaturesReply"
    | FlowModMsg _ -> "FlowMod"
    | PacketOutMsg _ -> "PacketOut"
    | PortStatusMsg _ -> "PortStatus"
    | PacketInMsg _ -> "PacketIn"
    | BarrierRequest -> "BarrierRequest"
    | BarrierReply -> "BarrierReply"
    | StatsRequestMsg _ -> "StatsRequest"
    | StatsReplyMsg _ -> "StatsReply"

  open Bigarray

  (** Size of the message body, without the header *)
  let sizeof_body (msg : t) : int = match msg with
    | Hello buf -> Cstruct.len buf
    | EchoRequest buf -> Cstruct.len buf
    | EchoReply buf -> Cstruct.len buf
    | SwitchFeaturesRequest -> 0
    | SwitchFeaturesReply rep -> SwitchFeatures.size_of rep
    | FlowModMsg msg -> FlowMod.size_of msg
    | PacketOutMsg msg -> PacketOut.size_of msg
    | BarrierRequest -> 0
    | BarrierReply -> 0
    | StatsRequestMsg msg -> StatsRequest.size_of msg
    | StatsReplyMsg msg -> StatsReply.size_of msg
    | _ ->
      failwith "Not yet implemented"

  let blit_message (msg : t) (out : Cstruct.t) = match msg with
    | Hello buf
    | EchoRequest buf
    | EchoReply buf ->
      Cstruct.blit buf 0 out 0 (Cstruct.len buf)
    | SwitchFeaturesRequest -> ()
    | FlowModMsg flow_mod ->
      let _ = FlowMod.marshal flow_mod out in
      ()
    | PacketOutMsg msg ->
      let _ = PacketOut.marshal msg out in
      ()
    (* | PacketInMsg _ -> () (\* TODO(arjun): wtf? *\) *)
    (* | SwitchFeaturesReply _ -> () (\* TODO(arjun): wtf? *\) *)
    | BarrierRequest -> ()
    | BarrierReply -> ()
    | StatsRequestMsg msg ->
      let _ = StatsRequest.marshal msg out in
      ()
    | StatsReplyMsg _ -> ()
    | _ -> failwith "Not yet implemented"

  let size_of msg = Header.size + sizeof_body msg

  let marshal (xid : xid) (msg : t) : string =
    let hdr = let open Header in
      {ver = ver; typ = msg_code_of_message msg; len = 0; xid = xid} in
    let sizeof_buf = Header.size_of hdr + sizeof_body msg in
    let hdr = {hdr with Header.len = sizeof_buf} in
    let buf = Cstruct.create sizeof_buf in
    let _ = Header.marshal hdr buf in
    blit_message msg (Cstruct.shift buf (Header.size_of hdr));
    let str = Cstruct.to_string buf in
    str

end

module type PLATFORM = sig
  exception SwitchDisconnected of switchId
  val send_to_switch : switchId -> Message.xid -> Message.t -> unit Lwt.t
  val recv_from_switch : switchId -> (Message.xid * Message.t) Lwt.t
  val accept_switch : unit -> SwitchFeatures.t Lwt.t
end
