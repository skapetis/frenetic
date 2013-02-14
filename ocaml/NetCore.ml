open Wildcard
open Pattern
open ControllerInterface
open MessagesDef
open Packet
open Platform
open NetCoreEval
open Printf

module type HANDLERS = sig

  val get_packet_handler : 
    NetCoreEval.id -> switchId -> portId -> packet -> unit

end

module MakeNetCoreMonad
  (Platform : PLATFORM) 
  (Handlers : HANDLERS) = struct

  type state = NetCoreController.ncstate
      
  type 'x m = state -> ('x * state) Lwt.t

  let bind (m : 'a m) (k : 'a -> 'b m) : 'b m = fun s ->
    Lwt.bind (m s) (fun (a, s') -> k a s')

  let ret (a : 'a) : 'a m = fun (s : state) -> Lwt.return (a,s)

  let get : state m = fun s -> Lwt.return (s,s)

  let put (s : state) : unit m = fun _ -> Lwt.return ((), s)

  let rec forever (m : unit m) = bind m (fun _ -> forever m)

  (** Channel of events for a single-threaded controller. *)
  let events : event Lwt_channel.t = Lwt_channel.create ()

  let send (sw_id : switchId) (xid : xid) (msg : message) = fun (s : state) ->
    Lwt.catch
      (fun () ->
        Lwt.bind (Platform.send_to_switch sw_id xid msg)
          (fun () -> Lwt.return ((), s)))
      (fun exn ->
        match exn with
          | Platform.SwitchDisconnected sw_id' ->
            Lwt.bind (Lwt_channel.send (SwitchDisconnected sw_id') events)
              (fun () -> Lwt.return ((), s))
          | _ -> Lwt.fail exn)

  let recv : event m = fun (s : state) ->
    Lwt.bind (Lwt_channel.recv events) (fun ev -> Lwt.return (ev, s))

  let recv_from_switch_thread sw_id () = 
    Lwt.catch
      (fun () ->
        let rec loop () = 
          Lwt.bind (Platform.recv_from_switch sw_id )
            (fun (xid,msg) ->
              Lwt.bind
                (Lwt_channel.send (SwitchMessage (sw_id, xid, msg)) events)
                (fun () -> loop ())) in
        loop ())
      (fun exn ->
        match exn with
          | Platform.SwitchDisconnected sw_id' ->
            Lwt_channel.send (SwitchDisconnected sw_id') events
          | _ -> Lwt.fail exn)

  let rec accept_switch_thread () = 
    Lwt.bind (Platform.accept_switch ())
      (fun feats -> 
        eprintf "[netcore-monad] SwitchConnected event queued.\n%!";
        Lwt.bind (Lwt_channel.send (SwitchConnected feats.switch_id) events)
          (fun () ->
            Lwt.async 
              (recv_from_switch_thread feats.switch_id);
            accept_switch_thread ()))

  let handle_get_packet id switchId portId pkt : unit m = fun state ->
    Lwt.return (Handlers.get_packet_handler id switchId portId pkt, state)

  let run (init : state) (action : 'a m) : 'a Lwt.t = 
    (** TODO(arjun): kill threads etc. *)
    Lwt.async accept_switch_thread;
    Lwt.bind (action init) (fun (result, _) -> Lwt.return result)
end

let drop_all_packets = NetCoreEval.PoAtom (NetCoreEval.PrAll, [])

type eventOrPolicy = 
  | Event of ControllerInterface.event
  | Policy of NetCoreEval.pol

module MakeDynamic
  (Platform : PLATFORM)
  (Handlers : HANDLERS) = struct

  (* The monad is written in OCaml *)
  module NetCoreMonad = MakeNetCoreMonad (Platform) (Handlers)
  (* The controller is written in Coq *)
  module Controller = NetCoreController.Make (NetCoreMonad)

  let start_controller policy_stream =
    let init_state = { 
      NetCoreController.policy = drop_all_packets; 
      NetCoreController.switches = []
    } in
    let policy_stream = Lwt_stream.map (fun v -> Policy v) policy_stream in
    let event_stream = Lwt_stream.map (fun v -> Event v)
      (Lwt_channel.to_stream NetCoreMonad.events) in
    let event_or_policy_stream = Lwt_stream.choose 
      [ event_stream ; policy_stream ] in
    let body = fun state ->
      Lwt.bind (Lwt_stream.next event_or_policy_stream)
        (fun v -> match v with
          | Event ev -> 
            eprintf "[DynamicController] new event.\n%!";
            Controller.handle_event ev state
          | Policy pol ->
            eprintf "[DynamicController] new policy.\n%!";
            Controller.set_policy pol state) in
    let main = NetCoreMonad.forever body in
    NetCoreMonad.run init_state main

end

type get_packet_handler = switchId -> portId -> packet -> unit

type predicate =
  | And of predicate * predicate
  | Or of predicate * predicate
  | Not of predicate
  | All
  | NoPackets
  | Switch of switchId
  | InPort of portId
  | DlSrc of Int64.t
  | DlDst of Int64.t
  (* TODO(arjun): fill in others *)

type action =
  | To of int
  | ToAll
  | GetPacket of get_packet_handler

type policy =
  | Pol of predicate * action list
  | Par of policy * policy (** parallel composition *)


module Make (Platform : PLATFORM) = struct

  let next_id : int ref = ref 0

  let get_pkt_handlers : (int, get_packet_handler) Hashtbl.t = 
    Hashtbl.create 200

  module Handlers : HANDLERS = struct
      
    let get_packet_handler queryId switchId portId packet = 
      Printf.printf "[platform] Got packet from %Ld\n" switchId;
      (Hashtbl.find get_pkt_handlers queryId) switchId portId packet
  end
          
  let desugar_act act = match act with
    | To pt -> Forward (PhysicalPort pt)
    | ToAll -> Forward AllPorts
    | GetPacket handler ->
      let id = !next_id in
      incr next_id;
      Hashtbl.add get_pkt_handlers id handler;
      ActGetPkt id

  let rec desugar_pred pred = match pred with
    | And (p1, p2) -> 
      PrNot (PrOr (PrNot (desugar_pred p1), PrNot (desugar_pred p2)))
    | Or (p1, p2) ->
      PrOr (desugar_pred p1, desugar_pred p2)
    | Not p -> PrNot (desugar_pred p)
    | All -> PrAll
    | NoPackets -> PrNone
    | Switch swId -> PrOnSwitch swId
    | InPort pt -> PrHdr (Pattern.inPort pt)
    | DlSrc n -> PrHdr (Pattern.dlSrc n)
    | DlDst n -> PrHdr (Pattern.dlDst n)

  let rec desugar_pol pol = match pol with
    | Pol (pred, acts) -> 
      PoAtom (desugar_pred pred, List.map desugar_act acts)
    | Par (pol1, pol2) ->
      PoUnion (desugar_pol pol1, desugar_pol pol2)

  module Controller = MakeDynamic (Platform) (Handlers)

  let clear_handlers () : unit = 
    Hashtbl.clear get_pkt_handlers;
    next_id := 0

  let start_controller (pol : policy Lwt_stream.t) : unit Lwt.t = 
    Controller.start_controller
      (Lwt_stream.map 
         (fun pol -> 
           Printf.eprintf "[netcore] got a new policy.%!\n";
           clear_handlers (); 
           desugar_pol pol)
         pol)

end
