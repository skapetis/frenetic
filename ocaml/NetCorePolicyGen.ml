open Printf
open MininetTypes

module G = PolicyGenerator.Make (MininetTypes)

type t = G.t

let from_mininet_raw (lst : (node * portId * node) list) =
  let g = G.empty () in
  List.iter (fun (src,portId,dst) -> G.add_edge g src portId dst) lst;
  g

let from_mininet filename = 
  from_mininet_raw (Mininet.parse_from_chan (open_in filename) filename)

let hosts (g : G.t) : hostAddr list =
  List.fold_right 
    (fun node lst -> match node with
      | Switch _ -> lst
      | Host addr -> addr :: lst) 
    (G.all_nodes g) []

let switches (g : G.t) : switchId list =
  List.fold_right 
    (fun node lst -> match node with
      | Switch dpid -> dpid :: lst
      | Host addr -> lst) 
    (G.all_nodes g) []

open NetCoreSyntax

let hop_to_pol (pred : predicate) (hop : node * portId * node) : policy =
  match hop with
    | (MininetTypes.Switch swId, pt, _) ->
      Pol (And (pred, Switch swId), [To pt])
    | _ -> Empty

let all_pairs_shortest_paths (g : G.t) = 
  let all_paths = G.floyd_warshall g in
  List.fold_right
    (fun p pol ->
      match p with
        | (Host src, path, Host dst) -> 
          let pred = And (DlSrc src, DlDst dst) in
          Par (par (List.map (hop_to_pol pred) (G.path_with_edges g path)), pol)
        | _ -> pol)
    all_paths
    Empty