
type node = string * Database_code.entity_kind
 type nodeinfo = {
   pos: Parse_info.token_location;
   props: Database_code.property list;
 }
type edge = Has | Use

type error =
 | NodeAlreadyPresent
exception Error of error

(* really an hypergraph actually *)
type graph

(* moving around directories to have less backward dependencies *)
type adjust = (string * string)
(* skip certain edges that are marked as ok regarding backward dependencies *)
type dependency = (node * node)
type whitelist = dependency list

val save: graph -> Common.filename -> unit
val load: Common.filename -> graph

val root: node
 val pb: node
  val not_found: node
  val dupe: node
(* val stdlib: node *)

val create_initial_hierarchy: graph -> unit

(* similar API to graph.ml *)

(* graph construction *)
val create: unit -> graph
(* may raise NodeAlreadyPresent *)
val add_node: node -> graph -> unit
val add_nodeinfo: node -> nodeinfo -> graph -> unit
val add_edge: (node * node) -> edge -> graph -> unit
val create_intermediate_directories_if_not_present: 
  graph -> Common.dirname -> unit
val remove_edge: (node * node) -> edge -> graph -> unit

(* graph access *)
val has_node: node -> graph -> bool
val succ: node -> edge -> graph -> node list
val pred: node -> edge -> graph -> node list
(* can raise exception *)
val parent: node -> graph -> node
val parents: node -> graph -> node list
val children: node -> graph -> node list
val nodeinfo: node -> graph -> nodeinfo
val file_of_node: node -> graph -> Common.filename

val all_children: node -> graph -> node list

val iter_use_edges: (node -> node -> unit) -> graph -> unit
val iter_nodes: (node -> unit) -> graph -> unit
val all_use_edges: graph -> (node * node) list
val all_nodes: graph -> node list

val nb_nodes: graph -> int
val nb_use_edges: graph -> int

(* algorithms *)

val group_edges_by_files_edges:
  (node * node) list -> graph ->
  ((Common.filename * Common.filename) * (node * node) list) list


(* debugging support *)
val string_of_node: node -> string
val display_with_gv: graph -> unit

(* adjustments *)
val load_adjust: Common.filename -> adjust list
val load_whitelist: Common.filename -> whitelist
val save_whitelist: whitelist -> Common.filename -> graph -> unit
(* does side effect on the graph *)
val adjust_graph: graph -> adjust list -> whitelist -> unit

(* example builder *)
val graph_of_dotfile: Common.filename -> graph

(* internals *)
