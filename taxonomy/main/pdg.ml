open Batteries
open Utils
open Ref
open Set
open Cabs
open Cprint
open Cabsvisit
open Cabswalker
open Pretty
open Cfg

let exp_str exp = Pretty.sprint ~width:80 (d_exp () exp)
let hfind ht key msg = ht_find ht key (fun _ -> failwith msg)

(* there exists a directed data dependency edge from program point 1 to program
   point2 if and only if the execution of p2 depends on data calculated directly
   by p1 *)

(* there exists a directed control dependency edge from p1 to p2 iff the choice
   to executed p2 depends on the test in p1 *)

module NodeSet = Set.Make (struct
  type t = cfg_node
  let compare v1 v2 = Pervasives.compare v1.cid v2.cid
end)

module EdgeSet = Set.Make(struct
  type t = cfg_node * label 
  let compare (v1,l1) (v2,l2) = 
	if (Pervasives.compare v1.cid v2.cid) == 0 then Pervasives.compare l1 l2 else
	  Pervasives.compare v1.cid v2.cid 
end)

module PairSet = Set.Make(struct
  type t = cfg_node * cfg_node * label
  let compare (n11,n12,_) (n21,n22,_) = 
	if (Pervasives.compare n11.cid n21.cid) == 0 then
	  Pervasives.compare n12.cid n22.cid
	else Pervasives.compare n11.cid n21.cid
end)

module DefSet = Set.Make (struct 
  type t = int * int 
  let compare (v1,v2) (v3,v4) = 
	if (Pervasives.compare v1 v3) == 0 
	then Pervasives.compare v2 v4 
	else Pervasives.compare v1 v3
end)

let compute_dominators startfun predfun cfg_nodes = 
  pprintf "in compute dominators\n"; flush stdout;
  let dominators = hcreate 10 in
  let idoms = hcreate 10 in
  let start = startfun cfg_nodes in 
  let node_set = NodeSet.of_enum (List.enum cfg_nodes) in
  let start_set = NodeSet.singleton start in
  let full_set = NodeSet.remove start node_set in
	hadd dominators start start_set;
	NodeSet.iter
	  (fun cfg_node ->
		hadd dominators cfg_node node_set
	  ) full_set;
	let strictly_dominates dom n =
	  (n.cid != dom.cid) &&
		(let domn = hfind dominators n "one" in 
		   NodeSet.exists
			 (fun node ->
			   node.cid == dom.cid) domn)
	in
	let compute (cfg_node : cfg_node) : NodeSet.t =
	  let n = NodeSet.singleton cfg_node in
	  let preds = predfun cfg_node in
		NodeSet.union n 
		  (lfoldl
			 (fun inter ->
			   fun pred ->
				 let domp : NodeSet.t = hfind dominators (hfind easy_access pred "three") "two" in
				   NodeSet.inter inter domp)
			 node_set preds)
	in
	let different (domn : NodeSet.t) (domn' : NodeSet.t) =
	  let diff1 = NodeSet.diff domn domn' in
	  let diff2 = NodeSet.diff domn' domn in
		not ((NodeSet.is_empty diff1) && (NodeSet.is_empty diff2))
	in
    let rec calc_doms () = 
	  let changed =
		NodeSet.fold
		  (fun n ->
			fun changed ->
			  let domn = hfind dominators n "four" in 
			  let domn' = compute n in
				hrep dominators n domn';
				if different domn domn' then true
				else changed) full_set false in 
		if changed then calc_doms() else ()
	in
	let calc_idom n = 
	  if n.cid == start.cid then () 
	  else begin
		if hmem idoms n then () 
		else begin
		  let domn = hfind dominators n "five" in 
		  let strict_doms = List.of_enum (NodeSet.enum (NodeSet.remove n domn)) in 
		  let rec find_strict_dom  = function
			| strict_dom :: tl -> 
			  if List.exists (fun other_dom -> strictly_dominates strict_dom other_dom && other_dom.cid != n.cid) strict_doms then 
				find_strict_dom tl
			  else 
				begin
				  if hmem idoms n then failwith "Already has an immediate dominator!" 
				  else hadd idoms n strict_dom
				end
			| [] -> failwith "no strict dominator and not the start, FAIL\n" 
		  in
			find_strict_dom strict_doms
		end
	  end
	in
	let calc_idoms () = liter calc_idom cfg_nodes in
	  calc_doms(); calc_idoms();
	  liter
		(fun n ->
		  let domn = hfind dominators n "six" in
		  let domn' = NodeSet.remove n domn in
			hrep dominators n domn') cfg_nodes;
	  pprintf "after liter1, before hiter\n"; flush stdout;
	  hiter
		(fun node ->
		  fun dominators ->
			pprintf "NODE:\n"; flush stdout;
			print_node node;
			pprintf "Post Dominators:\n" ;
			NodeSet.iter
			  (fun dom ->
				pprintf "%d, " dom.cid) dominators;
			pprintf "\n";
			if node.cid == start.cid then () else begin
			  let idom = hfind idoms node "seven" in
				pprintf "Immediate post dominator: %d\n\n\n" idom.cid
			end
		) dominators; pprintf "Done hiter\n"; flush stdout;  dominators,idoms

(* idoms matches nodes to their immediate dominators; can we convert that into a
   tree that we can traverse easily? *)

let compute_pre_dominators = compute_dominators get_entry (fun c -> lmap (fun (p,_) -> p) c.preds)
let compute_post_dominators = compute_dominators get_end (fun c -> lmap (fun (p,_) -> p) c.succs)

type pdg_node = 
	{ cfg_node : cfg_node ;
	  mutable control_dependents : EdgeSet.t ;
	  mutable data_dependents : EdgeSet.t }

let control_dependence cfg_nodes =
  let post_dominators,idoms = compute_post_dominators cfg_nodes in
  let node_set = NodeSet.of_enum (List.enum cfg_nodes) in
  let cfs = 
	NodeSet.filter 
	  (fun node -> 
		List.exists
		  (fun (_,label) ->
			match label with
			  TRUE | FALSE -> true
			| _ -> false) node.succs) node_set in
  let edges = 
	lfoldl
	  (fun pairset ->
		fun node ->
		  let succs = lfilt (fun (succ,l) -> match l with TRUE | FALSE -> true | _ -> false) node.succs in 
			lfoldl
			  (fun pairset ->
				fun (succ,l) ->
				  PairSet.add (node,hfind easy_access succ "eight",l) pairset
			  ) pairset succs
	  ) (PairSet.empty) (NodeSet.elements cfs)
  in
	pprintf "pairs1:\n"; flush stdout;
	PairSet.iter
	  (fun (a,b,_) ->
		pprintf "(%d,%d), " a.cid b.cid) edges;
	pprintf "\n";
	let pairs =
	  PairSet.filter
		(fun (a,b,_) ->
		  let post_doms = hfind post_dominators a "nine" in
			not (NodeSet.exists (fun node -> node.cid == b.cid) post_doms)) edges in
	  pprintf "Done computing pairs, pairs:\n"; flush stdout;
	  PairSet.iter
		(fun (a,b,_) ->
		  pprintf "(%d,%d), " a.cid b.cid) pairs;
	  pprintf "\n"; flush stdout;
	  let control_dependents = hcreate 10 in
	  let visited = hcreate 10 in
	  let rec traverse_backwards a src dest label =
		if not (hmem visited (src.cid,dest.cid)) then begin
		  hadd visited (src.cid,dest.cid) ();
		  if src.cid == dest.cid then () else
			begin
			  let set = ht_find control_dependents a (fun _ -> EdgeSet.empty) in
				hrep control_dependents a (EdgeSet.add (src,label) set);
				let next = hfind idoms src "ten" in
				  traverse_backwards a next dest label
			end
		end
	  in	
		PairSet.iter
		  (fun (a,b,label) -> 
			match a.cnode with
			  STOP -> () 
			| _ ->
			  let parent = hfind idoms a "eleven" in 
				traverse_backwards a b parent label) pairs;
		let cd_preds = hcreate 10 in
		  hiter
			(fun node ->
			  fun control_dependents ->
				EdgeSet.iter
				  (fun (cd,label) ->
					let set = 
					  ht_find cd_preds cd
						(fun _ -> EdgeSet.empty) in
					  hrep cd_preds cd (EdgeSet.add (node,label) set))
				  control_dependents) control_dependents;
			  (* Now, factoring and inserting region nodes, sigh *)
			  (* let as_list = List.of_enum (Hashtbl.enum cd_preds) in let
				 filtered = List.filter (fun (node,cd_preds) ->
				 if EdgeSet.is_empty cd_preds then false else
				 if (EdgeSet.cardinal cd_preds) == 1 then begin
				 let (_,label) = EdgeSet.choose cd_preds in
				 label != NONE end else true) as_list in let
				 cd_set_ht = hcreate 10 in liter (fun (node,cd)
				 -> let region_node = ht_find cd_set_ht cd (fun
				 _ -> let id = new_cfg() in { cid = id; cnode =
				 REGION_NODE (EdgeSet.elements cd) ; preds =
				 []; succs = [] }) in let cdeps = ht_find
				 control_dependents region_node (fun _ ->
				 EdgeSet.empty) in hrep control_dependents
				 region_node (EdgeSet.union cdeps
				 (EdgeSet.singleton (node,NONE))); EdgeSet.iter
				 (fun (parent,label) -> let cds = hfind
				 control_dependents parent in let cds =
				 EdgeSet.remove (node,label) cds in hrep
				 control_dependents parent (EdgeSet.union cds
				 (EdgeSet.singleton (region_node,label)))) cd )
				 filtered ; let add_regions = hfold (fun node
				 -> fun control_dependents -> fun lst -> let
				 numT,numF,numN = EdgeSet.fold (fun
				 (node,label) -> fun (numT,numF,numN) -> match
				 label with NONE | DATA -> numT,numF,numN + 1 |
				 TRUE -> numT + 1, numF, numN | FALSE ->
				 numT,numF + 1,numN) control_dependents (0,0,0)
				 in let lst = if numT > 1 then (node,TRUE) ::
				 lst else lst in if numF > 1 then (node,FALSE)
				 :: lst else lst) control_dependents [] in
				 pprintf "after add_regions, before liter\n";
				 flush stdout; liter (fun (parent,label) ->
				 match parent.cnode with CONTROL_FLOW _ -> let
				 region_node = ht_find cd_set_ht
				 (EdgeSet.singleton (parent,label)) (fun _ ->
				 let id = new_cfg() in { cid = id; cnode =
				 REGION_NODE [ (parent,label)] ; preds = [];
				 succs = [] }) in let cdeps = hfind
				 control_dependents parent in let cdeps =
				 EdgeSet.filter (fun (cd,l) -> if l == label
				 then begin let region_cds = ht_find
				 control_dependents region_node (fun _ ->
				 EdgeSet.empty) in let region_cds =
				 EdgeSet.union region_cds (EdgeSet.singleton
				 (cd,l)) in hrep control_dependents region_node
				 region_cds; false end else true) cdeps in hrep
				 control_dependents parent (EdgeSet.union cdeps
				 (EdgeSet.singleton (region_node,label))) | _
				 -> ()) add_regions; *)
		  control_dependents

let cabs_id_to_uses = hcreate 10
let str_to_def = hcreate 10
let def_to_str : (int, (string * int)) Hashtbl.t = hcreate 10 

let def_num = ref 0 

class usesWalker = object(self)
  inherit [string Set.t] singleCabsWalker
  method default_res () = Set.empty
  method combine set1 set2 = Set.union set1 set2

  method wExpression exp = 
	let is_assign = function 
	  | ASSIGN | ADD_ASSIGN | SUB_ASSIGN | MUL_ASSIGN 
	  | DIV_ASSIGN | MOD_ASSIGN | BAND_ASSIGN | BOR_ASSIGN 
	  | XOR_ASSIGN | SHL_ASSIGN | SHR_ASSIGN -> true
	  | _ -> false 
	in
	let is_simple exp = 
	  match exp.node with
		NODE(VARIABLE(str)) -> true
	  | _ -> false 
	in
	  match dn exp with 
	  | BINARY(bop,exp1,exp2) when (is_assign bop) && (is_simple exp1) ->
		Result(self#walkExpression exp2)
	  | LABELADDR(str)
	  | VARIABLE(str)
	  | EXPR_PATTERN(str) -> 
		Result(Set.singleton str)
	  | _ -> Children
end

let function_exclusions = lmap Str.regexp_string_case_fold ["printf";"fprintf";"log";"atoi"]
let arg_names = lmap Str.regexp_string_case_fold ["argv";"argc"]

let my_uses = new usesWalker 
let gen_cache = hcreate 10
  
class labelDefs (bbnum : int) = object(self)
  inherit nopCabsVisitor

  method vexpr exp = 
	match dn exp with 
	| UNARY(uop,exp1) ->
	  begin
		pprintf "UNARY label\n"; flush stdout;
		match uop with 
		| PREINCR 
		| PREDECR 
		| POSINCR 
		| POSDECR -> 
		  let defs = my_uses#walkExpression exp1 in 
			hadd cabs_id_to_uses exp.id defs;
			let gens = 
			  DefSet.of_enum(
				Set.enum
				  (Set.map (fun str -> 
					let num = post_incr def_num in 
					  pprintf "exp: %d, defnum: %d, var: %s\n" exp.id num str;
					  hadd str_to_def (str,exp.id) num;
					  hadd def_to_str num (str,exp.id);
					  bbnum,num
				   ) defs)) in
			let orig = ht_find gen_cache bbnum (fun _ -> DefSet.empty) in
			  hrep gen_cache bbnum (DefSet.union orig gens)
		| _ -> ()
	  end; DoChildren
	| BINARY(bop,exp1,exp2) ->
	  begin
		pprintf "BINARY LABEL\n"; flush stdout;
		match bop with 
		| ASSIGN
		| ADD_ASSIGN
		| SUB_ASSIGN
		| MUL_ASSIGN
		| DIV_ASSIGN
		| MOD_ASSIGN
		| BAND_ASSIGN
		| BOR_ASSIGN
		| XOR_ASSIGN
		| SHL_ASSIGN
		| SHR_ASSIGN ->
		  let defs = my_uses#walkExpression exp1 in 
			hadd cabs_id_to_uses exp.id defs;
			let gens = 
			  DefSet.of_enum(
				Set.enum
				  (Set.map (fun str -> 
					let num = post_incr def_num in 
					  pprintf "exp: %d, defnum: %d, var: %s\n" exp.id num str;
					  hadd str_to_def (str,exp.id) num;
					  hadd def_to_str num (str,exp.id);
					  bbnum,num
				   ) defs)) in
			let orig = ht_find gen_cache bbnum (fun _ -> DefSet.empty) in
			  hrep gen_cache bbnum (DefSet.union orig gens)

		| _ -> ()
	  end; DoChildren
	| CALL (e1, elist) ->
	  pprintf "CALL LABEL\n"; flush stdout;
	  let function_name = my_uses#walkExpression e1 in 
	  let heuristic = 
		List.exists
		  (fun regexp ->
			Set.exists (fun name -> any_match regexp name) function_name)
		  function_exclusions
	  in
		if not heuristic then begin
		  liter
			(fun exp ->
			  let defs = my_uses#walkExpression exp in 
				pprintf "Def set size: %d\n" (Set.cardinal defs); flush stdout;
			  let defs = 
				Set.filter
				  (fun str ->
					not (List.exists (fun regexp -> any_match regexp str) arg_names)) defs 
			  in
				hadd cabs_id_to_uses exp.id defs;
				let gens = 
				  DefSet.of_enum(
					Set.enum
					  (Set.map (fun str -> 
						let num = post_incr def_num in 
						  pprintf "exp: %d, defnum: %d, var: %s\n" exp.id num str;
						  hadd str_to_def (str,exp.id) num;
						  hadd def_to_str num (str,exp.id);
						  bbnum,num
					   ) defs)) in
				let orig = ht_find gen_cache bbnum (fun _ -> DefSet.empty) in
				  hrep gen_cache bbnum (DefSet.union orig gens)) elist; 
		end; DoChildren
	| _ -> DoChildren

  method vdef def = 
	match dn def with
	  DECDEF(ing,_) ->
		let _,ins = ing in
		let names = 
		  Set.of_enum (List.enum (
			lmap 
			  (fun (name,ie) ->
				let (str,_,_,_) = name in  str) ins)) in 
		  hadd cabs_id_to_uses def.id names;
		  let gens = 
			DefSet.of_enum(
			  Set.enum(
				Set.map (fun str -> 
				  let num = post_incr def_num in 
					pprintf "def: %d, defnum: %d, var: %s\n" def.id num str;
					hadd str_to_def (str,def.id) num;
					hadd def_to_str num (str,def.id);
					bbnum,num
				) names)) in
		  let orig = ht_find gen_cache bbnum (fun _ -> DefSet.empty) in
			hrep gen_cache bbnum (DefSet.union orig gens);
			DoChildren
	| _ -> DoChildren

end

let data_dependence cfg_nodes =
  let kill_cache = hcreate 10 in
  let out_cache = hcreate 10 in
  let rec label bb = 
	pprintf "labeling bb: %d\n" bb.cid;
	hadd gen_cache bb.cid (DefSet.empty);
	let labelWalker = new labelDefs bb.cid in 
	  match bb.cnode with
	  | BASIC_BLOCK (slist) -> ignore(lmap (visitStatement labelWalker) slist)
	  | CONTROL_FLOW(stmt,exp) -> ignore(visitExpression labelWalker exp)
	  | REGION_NODE(cnodes) -> liter (fun (cnode,_) -> label cnode) cnodes
	  | _ -> ()
  in
	pprintf "labeling, %d nodes:\n" (llen cfg_nodes);
	liter label cfg_nodes;
	pprintf "Done labeling!\n"; flush stdout;
	let different domn domn' =
	  let diff1 = DefSet.diff domn domn' in
	  let diff2 = DefSet.diff domn' domn in
		not ((DefSet.is_empty diff1) && (DefSet.is_empty diff2))
	in
	let kill_b (bb : cfg_node) gen_b in_b =
	  DefSet.fold
		(fun (bbid,generated_def) ->
		  fun killed_stuff ->
			let gen_str,_ = hfind def_to_str generated_def "12" in
			  DefSet.filter
				(fun (bb,in_b_def) ->
				  let def_str,_ = hfind def_to_str in_b_def "13" in
					def_str = gen_str) in_b 
		) gen_b (DefSet.empty)
	in
	let with_gen = lmap (fun bb -> bb,hfind gen_cache bb.cid "15" ) cfg_nodes in
	let rec calc_reaching() =
	  let changed = 
		lfoldl
		  (fun changed -> 
			fun (bb,gen_b) ->
			  let out_b = ht_find out_cache bb.cid (fun _ -> DefSet.empty) in
			  let in_b = 
				lfoldl
				  (fun inb ->
					fun (pred,_) ->
					  let outp = ht_find out_cache pred (fun _ -> DefSet.empty) in
						DefSet.union outp inb) (DefSet.empty) bb.preds in
			  let kill_b = kill_b bb gen_b in_b in
				hrep kill_cache bb.cid kill_b;
				let out_b' = DefSet.union gen_b (DefSet.diff in_b kill_b) in
				  hrep out_cache bb.cid out_b'; 
				  if different out_b out_b' then true else changed) false with_gen
	  in
		if changed then calc_reaching() else () 
	in
	  calc_reaching();
	  let pdg_edges = hcreate 10 in
	  let usesWalk = new usesWalker in
	  let add_edges bb =
		let in_b = 
		  lfoldl
			(fun inb ->
			  fun (pred,_) ->
				let outp = hfind out_cache pred "16" in
				  DefSet.union outp inb) (DefSet.empty) bb.preds 
		in 
		let gen_b = hfind gen_cache bb.cid "17" in
		let rec calc_uses bb = 
		  match bb.cnode with
			BASIC_BLOCK (slist) ->
			  lfoldl
				(fun uses ->
				  fun stmt ->
					let genSet = usesWalk#walkStatement stmt in
					  Set.union genSet uses) (Set.empty) slist
		  | CONTROL_FLOW(stmt,exp) -> usesWalk#walkExpression exp
		  | REGION_NODE(cnodes) ->
			lfoldl (fun accum -> fun (cnode,_) -> Set.union accum (calc_uses cnode)) (Set.empty) cnodes
		  | _ -> Set.empty
		in 
		let uses : string Set.t = calc_uses bb in
		  pprintf "bbid: %d\n" bb.cid;
		  pprintf "INB:\n";
		  DefSet.iter (fun (defining_bb,def_num) -> pprintf "  Defined in %d, definition num %d\n" defining_bb def_num) in_b;
		  pprintf "OUTB:\n";
		  DefSet.iter (fun (defining_bb,def_num) -> pprintf "  Defined in %d, definition num %d\n" defining_bb def_num) (hfind out_cache bb.cid "18");
		  pprintf "GENS: \n";
		  DefSet.iter (fun (defining_bb,def_num) -> pprintf "  Defined in %d, definition num %d\n" defining_bb def_num) gen_b;
		  pprintf "KILLS: \n";
		  let kill_b = hfind kill_cache bb.cid "19" in
			DefSet.iter (fun (defining_bb,def_num) -> pprintf "  Defined in %d, definition num %d\n" defining_bb def_num) kill_b;
			pprintf "USES: \n";
			Set.iter (fun varstr -> pprintf "%s, " varstr) uses;
			pprintf "\n";

			let where_defined =
			  Set.map
				(fun (varstr : string) ->
				  let res =
					DefSet.filter
					  (fun (bb_id,def_id) ->
						let def_str,_ = hfind def_to_str def_id "20" in 
						  def_str = varstr) 
					  in_b
				  in
					pprintf "%s was defined at nodes: \n" varstr;
					DefSet.iter (fun (defining_bb,def_num) -> pprintf "  Defined in %d, definition num %d\n" defining_bb def_num) res;
					res
				) uses in
			let where_defined =
			  Set.fold
				(fun set1 ->
				  fun sets ->
					DefSet.union set1 sets) where_defined (DefSet.empty) 
			in
			  DefSet.iter
				(fun (def_node_id,_) ->
				  let init_val = ht_find pdg_edges def_node_id (fun _ -> EdgeSet.empty) in
					hrep pdg_edges def_node_id (EdgeSet.add (bb,DATA) init_val)) where_defined;
	  in
		liter add_edges cfg_nodes;
		pdg_edges
		  
let cfg2pdg cfg_nodes = 
  pprintf "before control_deps, %d nodes\n" (llen cfg_nodes); flush stdout;
  let pdg_nodes = 
	lmap
	  (fun node -> {cfg_node = node; control_dependents = EdgeSet.empty; data_dependents = EdgeSet.empty} ) cfg_nodes 
  in
  let control_deps = control_dependence cfg_nodes in 
	pprintf "after control_deps,  Before data_dependence\n"; flush stdout;
	let pdg_deps = data_dependence cfg_nodes in
	  pprintf "after data_dependence\n"; flush stdout;
	  lmap (fun node -> 
		node.control_dependents <- ht_find control_deps node.cfg_node (fun _ -> EdgeSet.empty); 
		node.data_dependents <- ht_find pdg_deps node.cfg_node.cid (fun _ -> EdgeSet.empty); 
		print_node node.cfg_node;
		pprintf "data dependents:\n";
		EdgeSet.iter
		  (fun (bb,label) -> 
			pprintf "(%d,%s) " bb.cid (labelstr label)
		  ) node.data_dependents;
		pprintf "\n control dependents:\n";
		EdgeSet.iter
		  (fun (bb,label) -> 
			pprintf "(%d,%s) " bb.cid (labelstr label)
		  ) node.control_dependents;
		pprintf "\n"; flush stdout;
		node
	  ) pdg_nodes
		
		
type wc_graph_node = 
	{ wcn : pdg_node ;
	  mutable index : int }

type subgraph = pdg_node list 

let interesting_subgraphs (pdg_nodes : pdg_node list) =
  pprintf "pdg nodes length: %d\n" (llen pdg_nodes);
  liter (fun pdg_node -> print_node pdg_node.cfg_node) pdg_nodes;
  pprintf "done printing pdg_nodes\n"; flush stdout;
  let easy_access : (int, pdg_node) Hashtbl.t = hcreate 10 in
  let undirected_graph : (int, IntSet.t) Hashtbl.t = hcreate 10 in
  let directed_graph : (int, IntSet.t) Hashtbl.t = hcreate 10 in
  let compressed : (int * pdg_node * IntSet.t) list =
	lmap (fun node -> 
	  hadd easy_access node.cfg_node.cid node;
	  let control_ints = 
		IntSet.of_enum
		  (Enum.map (fun (cnode,_) -> cnode.cid) (EdgeSet.enum node.control_dependents)) in
	  let data_ints = IntSet.of_enum (Enum.map (fun (cnode,_) -> cnode.cid) (EdgeSet.enum node.data_dependents)) in
		node.cfg_node.cid, node, IntSet.union control_ints data_ints) pdg_nodes
  in
	pprintf "compressed\n"; flush stdout;
	liter
	  (fun (nid,node,all_neighbors) ->
		pprintf "adding %d to graphs\n" nid; flush stdout;
		hrep directed_graph nid all_neighbors;
		let set = ht_find undirected_graph nid (fun _ -> IntSet.empty) in
		  hrep undirected_graph nid (IntSet.union set all_neighbors);
		  IntSet.iter
			(fun neighbor ->
			  let set = ht_find undirected_graph neighbor (fun _ -> IntSet.empty) in
				hrep undirected_graph neighbor (IntSet.add nid set))
			all_neighbors) compressed;
	pprintf "directed and undirected\n"; flush stdout;
	(* weakly-connected components: a set of statements is a weakly-connected
	   component if there exists an undirected path between all pairs of nodes in
	   the set *)
	let without_implicits : (int * pdg_node * IntSet.t) list = 
	  lfilt 
		(fun (nid,node,neighbors) -> 
		  match node.cfg_node.cnode with 
			START | STOP | ENTRY -> false
		  | _ -> true) compressed
	in
	  pprintf "Filtered, length: %d\n" (llen without_implicits); flush stdout;
	  let wc_tbl : (int, wc_graph_node) Hashtbl.t = hcreate 10 in
	  let index = ref 1 in
	  let wc_nodes : wc_graph_node list = 
		lmap (fun (nid,pdg_node,_) -> 
		  let wcn = {wcn = pdg_node; index = 0 } in
			hadd wc_tbl nid wcn; wcn) without_implicits 
	  in
		pprintf "wc nodes: %d\n" (llen wc_nodes); flush stdout;
		let reach_ht = hcreate 10 in
		let undirected (node : pdg_node) : IntSet.t = 
		  hfind undirected_graph node.cfg_node.cid "21"
		in
		let directed (node : pdg_node) : IntSet.t = 
		  hfind directed_graph node.cfg_node.cid "22"
		in
		let rec reachable (node : pdg_node) (neighbor_func : pdg_node -> IntSet.t) : IntSet.t = 
		  if not (hmem reach_ht node.cfg_node.cid) then begin
			hadd reach_ht node.cfg_node.cid (IntSet.empty);
			let immediate = neighbor_func node in
			let neighbors = 
			  IntSet.fold
				(fun neighbor ->
				  fun all_reachable ->
					IntSet.union (reachable (hfind easy_access neighbor "23" ) neighbor_func) all_reachable)
				immediate immediate
			in
			  hrep reach_ht node.cfg_node.cid neighbors; neighbors
		  end else hfind reach_ht node.cfg_node.cid "24"
		in
		let components : (int, IntSet.t) Hashtbl.t = hcreate 10 in
		let rec compute_wcs (lst : wc_graph_node list) = 
		  match lst with
			ele :: eles ->
			  let all_reachable = reachable ele.wcn undirected in
				pprintf "after reachable\n"; flush stdout;
				let all_reachable = 
				  IntSet.filter
					(fun id -> hmem wc_tbl id) all_reachable in
				  IntSet.iter
					(fun id ->
					  let wgn = hfind wc_tbl id "25" in
						wgn.index <- !index) all_reachable;
				  pprintf "index initialized\n"; flush stdout;
				  hadd components !index all_reachable;
				  incr index;
				  pprintf "remaining\n"; flush stdout;
				  let remaining = 
					lfilt 
					  (fun ele ->
						let wgn = hfind wc_tbl ele.wcn.cfg_node.cid "26" in
						  wgn.index == 0) lst in
					pprintf "Remaining: %d\n" (llen remaining); flush stdout;
					compute_wcs remaining
		  | [] -> ()
		in
(*		  compute_wcs wc_nodes; Skipping this for now because we may not need it in light
		  of the tiny size of the code we're looking at and the use of semantic threads, below. *)
		  pprintf "After compute_wcs\n"; flush stdout;
	  (* semantic threads *)
		  let rec add_slice (ist : IntSet.t Set.t) (slice : IntSet.t) = 
			let conflicts = hcreate 10 in
			  Set.iter 
				(fun t ->
				  if (IntSet.cardinal (IntSet.inter slice t)) > 5 (* 5 is arbitrarily selected *) then 
					hadd conflicts t ();
				) ist;
			  if hlen conflicts == 0 then 
				Set.add slice ist
			  else begin
				let all_cs = Set.of_enum (Hashtbl.keys conflicts) in
				let slice = 
				  Set.fold 
					(fun new_slice -> 
					  fun thread -> 
						IntSet.union new_slice thread)
					all_cs slice in
				  add_slice (Set.diff ist all_cs) slice
			  end
		  in
		  let bst pdg_nodes = 
			hclear reach_ht;
			let visited = hcreate 10 in 
			  lfoldl
				(fun ist ->
				  fun pnode ->
					if not (hmem visited pnode.cfg_node.cid) then begin
					  hadd visited pnode.cfg_node.cid ();
					  let slice = reachable pnode directed in
						IntSet.iter (fun node -> hadd visited node ()) slice;
						add_slice ist slice
					end else ist 
				) (Set.empty) pdg_nodes
		  in 
		  let components_to_subgraphs (components : (int, IntSet.t) Hashtbl.t) : subgraph list = 
			let comps = List.of_enum (Hashtbl.values components) in
			let one_component (component : IntSet.t) = 
			  let as_nodes : wc_graph_node list = 
				lmap (fun nodeid -> hfind wc_tbl nodeid "27") (List.of_enum (IntSet.enum component)) in
				lmap (fun node -> node.wcn) as_nodes
			in
			  lmap one_component comps
		  in
		  let ist_to_subgraphs ist = 
			let ists = List.of_enum (Set.enum ist) in
			let one_thread thread = 
			  lmap (fun id -> hfind easy_access id "28") (List.of_enum (IntSet.enum thread))
			in
			  lmap one_thread ists
		  in
			pprintf "Before call to bst\n"; flush stdout;
			let ist = bst pdg_nodes in
			  pprintf "After call to bst\n"; flush stdout;
			  let comps = components_to_subgraphs components in
				pprintf "component subgraphs:\n"; 
				liter
				  (fun subgraph ->
					pprintf "SEPSEPSEPSEP\n";
					liter (fun ele -> print_node ele.cfg_node) subgraph;
					pprintf "SEPSEPSEPSEP\n"
				  ) comps;
				pprintf "done printing subgraphs\n"; 
				let ists = ist_to_subgraphs ist in 
				  pprintf "semantic thread subgraphs:\n";
				pprintf "component subgraphs:\n"; 
				liter
				  (fun subgraph ->
					pprintf "SEPSEPSEPSEP\n";
					liter (fun ele -> print_node ele.cfg_node) subgraph;
					pprintf "SEPSEPSEPSEP\n"
				  ) ists;
				pprintf "done printing subgraphs\n"; 
				comps @ ists

(* FIXME/TODO: OK, I *think* that the insert_parent number should be in the
   first tree, but DOUBLE CHECK *)

class containsMods modsites = object(self)
  inherit [bool] singleCabsWalker

  val modsites = modsites 
  method default_res () = false 
  method combine one two = one || two 

  method wExpression exp = 
	if List.mem exp.id modsites then Result(true) 
	else Children

  method wStatement stmt = 
	if List.mem stmt.id modsites then Result(true) 
	else Children

  method wDefinition def = 
	if List.mem def.id modsites then Result(true)
	else Children

  method wTreenode tn = 
	if List.mem tn.id modsites then Result(true)
	else Children
	
end

let contains_modsites modsites subgraph = 
  let cont_walker = new containsMods modsites in 
  let rec cfg_contains cfg_node = 
	match cfg_node.cnode with
	| BASIC_BLOCK(slist) ->
	  List.exists (fun stmt -> cont_walker#walkStatement stmt) slist
	| CONTROL_FLOW(stmt,exp) ->
	  cont_walker#walkExpression exp || cont_walker#walkStatement stmt
	| REGION_NODE(cls) -> 
	  let cnodes = fst (List.split cls) in 
		List.exists cfg_contains cnodes
	| _ -> false
  in
	List.exists (fun pdg_node -> cfg_contains pdg_node.cfg_node) subgraph
