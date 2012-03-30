(* Minimization
 * Generates the minimized diff script (created by CDiff)
 * Basically an ocaml implementation of delta debugging,
 * specifically for our CDiff-generated script. Used to
 * find the 1-minimal subset for repairs, which will also
 * make applying them to the original file significantly easier
 * and more accurate. *)
open Cil
open Rep
open Global
open Cdiff
open Rep
open Printf

let minimization = ref false
let minimize_patch = ref false

let _ =
  options := !options @
  [
	"--minimization", Arg.Set minimization, " Attempt to minimize diff script using delta-debugging";
	"--edit-script", Arg.Set minimize_patch, " Minimize the edit script, not the tree-based diff. Default: false";
  ] 

let whitespace = Str.regexp "[ \t\n]+"

(* Sometimes we want to compute the structural difference between two
 * variants to get a fine-grained diff between them. Currently this is only
 * really supported by CIL using the CDIFF/DIFFX code. *) 
type structural_signature =  
	{ signature : (Cdiff.node_id StringMap.t) StringMap.t ; 
	  node_map : Cdiff.tree_node IntMap.t }


(* 
 * Tree-Structured Differencing. Use the "structural_signature" method of a
 * rep to get the structural signature. You can either inspet the Cdiff
 * edit script directly (it lists tree-structured edits needed to transform
 * rep1 into rep2) or just take the length of that script as the
 * "distance". 
 *)
(* The innermost list contains edit actions for a given global.
 * The second list contains globals for a given file.
 * The outermost list is files - one element = one file. *)
(* OK.  This assumes that the two representations have the same number and
   types and names of functions, which isn't reasonable. *)
let cdiff_data_ht = hcreate 255 
let structural_difference_edit_script
    (rep1 : structural_signature)
    (rep2 : structural_signature) =
(*    :  (string * (string * Cdiff.edit_action list)) list =*)
  let map_union map1 map2 = 
	IntMap.fold
	  (fun k -> fun v -> fun new_map -> IntMap.add k v new_map)
	  map1 map2
  in
  let node_map = map_union rep1.node_map rep2.node_map in 
  let final_result = ref [] in
	Hashtbl.clear cdiff_data_ht;
	StringMap.iter
	  (fun filename ->
		fun filemap ->
		  let file2 = StringMap.find filename rep2.signature in
		  let inner_result = ref [] in
			StringMap.iter
			  (fun global_name1 ->
				fun t1 ->
				  let t2 = StringMap.find global_name1 file2 in
				  let m = Cdiff.mapping node_map t1 t2 in
					Hashtbl.add cdiff_data_ht global_name1 (m,t1,t2);
					let s = 
					  Cdiff.generate_script 
						node_map
						(Cdiff.node_of_nid node_map t1) 
						(Cdiff.node_of_nid node_map t2) m 
					in
					  inner_result := (global_name1,s) :: !inner_result)
			  filemap;
			final_result := (filename, (List.rev !inner_result) ) :: !final_result)
	  rep1.signature;
	List.rev !final_result

let structural_difference
      (rep1 : structural_signature)
      (rep2 : structural_signature)
      : int 
      =
  (* I'm fairly certain this always returns a list = the # of files in the
	 representations *)
  List.length (structural_difference_edit_script rep1 rep2) 

let structural_difference_to_string
      (rep1 : structural_signature)
      (rep2 : structural_signature)
      : string 
      =
  let b = Buffer.create 255 in
  let the_script = structural_difference_edit_script rep1 rep2 in
  List.iter (fun (the_file,file_script) ->
    List.iter (fun (globalname,globalscript) ->
      List.iter (fun elt ->
        Printf.bprintf b "%s %s %s\n" the_file globalname (Cdiff.edit_action_to_str elt)
      ) globalscript
    ) file_script
  ) the_script;
	Buffer.contents b

class virtual minimizableObject = object(self)

  (* Tree-Structured Comparisons
   *   Mostly for CIL ASTs using the DiffX algorithm. 
   *   Use the "structural_difference" methods to compute the
   *   actual difference. 
   *) 
  val already_signatured = ref None

  method virtual internal_structural_signature : unit -> structural_signature
  method structural_signature () = 
	match !already_signatured with
	  Some(s) -> s
	| None -> 
	  let s = self#internal_structural_signature() in
		already_signatured := Some(s); s

  method virtual from_source_min : ((string * string list) list) -> Cdiff.tree_node IntMap.t -> unit (* Build a rep directly from Cil.files, for mininimization *)
end

module DiffElement =
  struct
    type t = int * string
    let compare (x,_) (y,_) = x - y
  end
module DiffSet = Set.Make(DiffElement)

(* Read in a diff script to be minimized and store it. *)
let read_in_diff_script filename = begin
  let c = open_in filename in
  let res = ref [] in
  try
    while true do
      let next_line = input_line c in
		res :=  next_line :: !res
    done;
    close_in c; List.rev !res
  with End_of_file -> close_in c;
	List.rev !res
end

(* For repair, split the diff script based on newlines (it's from a string buffer) *)
let diff_script_from_repair the_script = 
  let newline = Str.regexp "\n" in
   Str.split newline the_script 

(* Turn a list of strings into a list of pairs, (string1 * string2), where string1 is unique *)
let split str =
 let whitespace = Str.regexp " " in
 let split_str = Str.split whitespace str in
 match split_str with
 | [a; b; c; d] -> a, a^" "^b^" "^c^" "^d
 | _ -> assert(false)

let script_to_pair_list a =
  List.fold_left (fun (acc : (string * (string list)) list) (ele : string) ->
    let (a : string),(b : string) = split ele in
	  match acc with
	  | (a',b') :: tl when a=a' -> (a',(b'@[b])) :: tl
	  | x -> (a,[b]) :: x
  ) [] a
	
exception Test_Failed
(* Run all the tests on the representation. Return true if they all pass. *)

let run_all_tests my_rep =
  let result = 
	try
	  liter (fun i -> 
		let res, _ = my_rep#test_case (Negative i) in
		  if not res then raise Test_Failed)
		(1 -- !neg_tests);
      let sorted_sample, sample_size = 
		if !sample < 1.0 then begin
		  let sample_size = int_of_float (
			max ((float !pos_tests) *. !sample) 1.0) 
		(* always sample at least one test case *) 
		  in
		  let random_pos = random_order (1 -- !pos_tests) in
			List.sort compare (first_nth random_pos sample_size), sample_size
		end else 
		  (1 -- !pos_tests), !pos_tests
	  in
		liter 
		  (fun i -> 
			let res, _ = my_rep#test_case (Positive i) in
			  if not res then raise Test_Failed) sorted_sample;
		if sample_size < !pos_tests then begin
		(* If we are sub-sampling and it looks like we have a candidate
		 * repair, we must run it on all of the rest of the tests to make
		 * sure! *)  
		  let rest_tests = List.filter (fun possible_test -> 
			not (List.mem possible_test sorted_sample)) (1 -- !pos_tests)
		  in 
			assert((llen rest_tests) + (llen sorted_sample) = !pos_tests);
			liter (fun pos_test ->
			  let res, _ = my_rep#test_case (Positive pos_test) in
				if not res then raise Test_Failed) rest_tests
		end; true
	with Test_Failed -> false
  in
	(my_rep#cleanup(); result)

let debug_diff_script the_script = liter (fun x -> debug "%s\n" x) the_script

(* exclude_line
 * utility function. Returns a list containing
 * a copy of the list passed to it, minus the line
 * indicated by the second parameter. (int) *)
let exclude_line the_list to_exclude = begin
  let ret_value = ref [] in
  let count = ref 0 in
  List.iter (fun x ->
	if (!count)<> to_exclude then 
	(
		ret_value := x :: !ret_value;
		incr count
	)
	else incr count;
	) the_list;
  List.rev !ret_value
end

let write_script to_write name = begin
  let outc = open_out name in
  List.iter (fun x -> Printf.fprintf outc "%s\n" x) to_write;
  close_out outc
end

(* Utility function to return a string representation of a given
 * integer in binary. *)
let in_binary num = begin
  let result = ref "" in
  let rec calc n =
    if n<=1 then begin
      result := (string_of_int (n)) ^ (!result);
      n
    end
    else begin
      result := (string_of_int (n mod 2)) ^ (!result);
      calc (n/2)
    end
  in
  ignore (calc num);
  !result
end

(* Print out files to disk. Used to output minimized repaired files. *)
let print_files files_to_cilfiles dirname = begin
  List.iter(fun (fn,cilfile) ->
    let fn = dirname^"/"^fn in
    ensure_directories_exist fn;
    let oc = open_out fn in
    iterGlobals cilfile (fun glob ->
      ignore(Pretty.fprintf oc "%a\n" dn_global glob); ());
    close_out oc
  ) files_to_cilfiles
end

(* process_representation
 * As input, take in the original and repaired variant
 * representations, a diff script to pass to Cdiff,
 * and names for both the temporary "minimized" representation
 * and the temporary "minimized" diff script. Use these
 * to perform the basic process to create a representation,
 * pass it through cdiff, and see if it passes all test cases.
 * If it does pass them all, return true, otherwise return false.
 ****
 * This is a "helper" method for testing; run_all_tests is an internal
 * method for running test cases, while this is the method which should
 * get called by whatever minimization method you're using. *)
let iteration = ref 0
let process_representation orig node_map diff_script diff_name is_sanity = begin
(* Call structural differencing to reset the data structures in Cdiff. *)
(* Create the directories for the source and diff temporary files, if they don't exist. *)
  (* Arbitrary diffscript (list of strings) to string * (string list) list *)
    let the_rep = orig#copy() in
	  if !minimize_patch then begin
		let repair_history =
		  List.fold_left (fun acc x ->
			let the_action = String.get x 0 in
			  match the_action with
				'd' ->   Scanf.sscanf x "%c(%d)" (fun _ id -> (Delete(id)) :: acc)
			  |	'a' -> Scanf.sscanf x "%c(%d,%d)" (fun _ id1 id2 -> (Append(id1,id2)) :: acc)
			  | 's' -> Scanf.sscanf x "%c(%d,%d)" (fun _ id1 id2 -> 
				  (Swap(id1,id2)) :: acc)
			  | 'r' -> Scanf.sscanf x "%c(%d,%d)" (fun _ id1 id2 -> 
				  (Replace(id1,id2)) :: acc)
			  |  _ -> assert(false)
		  ) [] diff_script
		in
		  the_rep#set_history repair_history
	  end else
		the_rep#from_source_min (script_to_pair_list diff_script) node_map;
    let res = run_all_tests the_rep in
    if (is_sanity) then 
	  begin 
		let old_subdirs = !use_subdirs in
		  use_subdirs := true; 
		let subdir = add_subdir(Some("Minimization_Files/original")) in 
		let filename = Filename.concat subdir ("original."^ !Global.extension^ !Global.suffix_extension ) in
		  orig#output_source filename;
		let subdir = add_subdir(Some("Minimization_Files/minimized")) in 
		let filename = Filename.concat subdir ("minimized."^ !Global.extension^ !Global.suffix_extension ) in
		  the_rep#output_source filename;
		  use_subdirs := old_subdirs
	  end; 
res
end


let delta_set_to_list the_set = begin
  let result = ref [] in
  DiffSet.iter (fun (_,x) ->
    result := x :: !result;
  ) the_set;
  List.rev !result
end

(* Implementation of delta-debugging for efficient diff script minimization.
 * This is all that should ever be used. You don't want 2^N temp files do you?? *)
let delta_count = ref 0

let stmt_id_to_loc = hcreate 10

class statementLocVisitor = object
  inherit nopCilVisitor
  method vstmt stmt = 
    hadd stmt_id_to_loc stmt.sid !currentLoc; DoChildren
end


let res = ref (locUnknown)

class findLocVisitor = object
  inherit nopCilVisitor
  method vstmt stmt = 
    if !currentLoc <> locUnknown then (res := !currentLoc; SkipChildren)
    else DoChildren
end

let loc_visitor = new statementLocVisitor 
let find_loc_visitor = new findLocVisitor
let apply_diff orig node_map diff_file =
  let actions = ref [] in
  let fin = open_in diff_file in
	(try while true do
		actions := (input_line fin) :: !actions
	  done with End_of_file -> close_in fin);
    actions := lrev !actions;
	process_representation orig (copy node_map) !actions "this_diff" true

let delta_debugging orig to_minimize node_map = begin
  let counter = ref 0 in
  let c =
	lfoldl
	(fun c ->
	  fun x ->
		let c = 
		  DiffSet.add ((!counter),x) c in
    incr counter; c
  ) (DiffSet.empty) to_minimize in
    (* sanity check the diff script *)
    if not (process_representation orig (copy node_map) (delta_set_to_list c) "Minimization_Files/sanity_script.diff" false) then
        debug "WARNING: original script doesn't pass!\n"
    else debug "GOOD NEWS: original script passes!\n";
  let rec delta_debug c n =
    incr delta_count;
    debug "Entering delta, pass number %d...\n" !delta_count;
    let count = ref 0 in
    let ci_array = Array.init n (fun _ -> DiffSet.empty) in
	  match n<=(DiffSet.cardinal c) with
	  | true -> begin
		DiffSet.iter (fun (num,x) ->
  		  ci_array.(!count mod n) <- DiffSet.add (num,x) ci_array.(!count mod n);
  		  incr count
		) c;
		let ci_list = Array.to_list ci_array in
		let diff_name = "Minimization_Files/delta_temp_scripts/delta_temp_script_"^(string_of_int !delta_count) in
		  try
			let ci = List.find (fun c_i -> 
			  process_representation orig (copy node_map) (delta_set_to_list c_i) diff_name false) ci_list in
			  delta_debug ci 2
		  with Not_found -> begin
			try
			  let ci = List.find (fun c_i ->
				process_representation orig (copy node_map) (delta_set_to_list (DiffSet.diff c c_i)) diff_name false) ci_list in
				delta_debug (DiffSet.diff c ci) (max (n-1) 2);
			with Not_found -> begin
			  if n < ((DiffSet.cardinal c)) then 
				delta_debug c (min (2*n) (DiffSet.cardinal c))
			  else c
			end
		  end
	  end
	  | false -> c
  in
  let minimized_script = delta_debug c 2 in
  debug "MINIMIZED DIFFSCRIPT: (after %d iterations) \n" !delta_count;
  DiffSet.iter (fun (_,x) -> debug "%s\n" x) minimized_script;
  let output_name = "minimized.diffscript" in
  let minimized = delta_set_to_list minimized_script in
  ensure_directories_exist ("Minimization_Files/full."^output_name);
  write_script minimized ("Minimization_Files/full."^output_name);
  let res = process_representation orig (copy node_map) minimized ("Minimization_Files/"^output_name) true in
  if res then debug "Sanity checking successful!\n" else debug "Sanity checking failed...\n";
	minimized
end

let do_minimization orig rep =
  if !minimization then begin
	let orig_sig = orig#structural_signature() in
	let rep_sig = rep#structural_signature() in
	let map_union (map1) (map2) : Cdiff.tree_node IntMap.t = 
	  IntMap.fold
		(fun k -> fun v -> fun new_map -> IntMap.add k v new_map)
		map1 map2
	in
	let node_map : Cdiff.tree_node IntMap.t = map_union orig_sig.node_map rep_sig.node_map in 
	let node_id_to_node = hcreate 10 in
	  (* CLG: HACK *)
	  IntMap.iter (fun node_id -> fun node -> hadd node_id_to_node node_id node) node_map;
		let to_minimize = 
		  if !minimize_patch then
			let name = rep#name() in
			  Str.split space_regexp name
		  else
			let diff_script = structural_difference_to_string orig_sig rep_sig in
			  debug "\nDifference script:\n*****\n%s*****\n\n" diff_script;
			  diff_script_from_repair diff_script 
		in
		let my_script =
		  if !minimization then 
			delta_debugging orig to_minimize node_map
		  else to_minimize
		in
		  ()
  end
