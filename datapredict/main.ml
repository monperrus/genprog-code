open List
open Cil
open Pretty
open Utils
open DPGlobs
open Globals
open Invariant
open State
open Graph
open Predict

let cbi_hash_tables = ref ""
let runs_in = ref ""
let to_eval = ref ""
let inter_weights = ref []
let do_cbi = ref false

(* what we want to do is print out to several files, one for fault and
 * one for fix for each of several strategies, in addition to the
 * debug output. *)

let usageMsg = "Giant Predicate Processing Program of Doom\n"
let options = ref [
  "-cbi-hin", Arg.Set_string cbi_hash_tables, 
  "\t File containing serialized hash tables from my implementation \
                of CBI." ;
  "-rs", Arg.Set_string runs_in,
  "\t File listing names of files containing runs, followed by a passed \
                or failed on the same line to delineate runs." ;
  "-inter", Arg.String (fun str -> inter_weights :=
						  float_of_string(str) :: !inter_weights),
  "\t Do intersection-style localization (think genprog baseline) \
       with X as the weight given to statements on the good path." ;
  "-cbi-fault", Arg.Set do_cbi, "\t Do CBI-style fault localization." ;
  "-pred", Arg.Set_string to_eval,
  "\t predicate to evaluate at every state on every run. Debug, \
      mostly.";
  "-name", Arg.Set_string name, "\t Name to prepend to output files." ;
] 

(* Utility function to read 'command-line arguments' from a file. 
 * This allows us to avoid the old 'ldflags' file hackery, etc. *) 
let parse_options_in_file (file : string) : unit =
  let args = ref [ Sys.argv.(0) ] in 
    try
      let fin = open_in file in 
	(try while true do
	   let line = input_line fin in
	   let words = Str.bounded_split space_regexp line 2 in 
	     args := !args @ words 
	 done with _ -> close_in fin) ;
	Arg.current := 0 ; 
	Arg.parse_argv (Array.of_list !args) 
	  (Arg.align !options) 
	  (fun str -> debug "%s: unknown option %s\n"  file str) usageMsg 
    with _ -> () 

let preprocess () = begin
  (* compile list of files containing output of instrumented program runs *)

  let fin = open_in !runs_in in
	pprintf "after open\n"; flush stdout;
  let file_list = ref [] in
	begin
	  try
		while true do
		  let line = input_line fin in
		  let split = Str.split whitespace_regexp line in 
			file_list := ((hd split), (hd (tl split))) :: !file_list
		done
	  with _ -> close_in fin
	end;

	(* preprocess the input files *)
	lmap
	  (fun (fname,porf) ->
		 pprintf "fname: %s\n" fname; flush stdout;
		 (* I need to know when there's a transition b/w states *)
		 let transition_table = hcreate 100 in
		 let site_count_table = hcreate 50 in
		   (* I need to know how many times a given site with a given state is
			* visited (meaning: identical lines).  Track exactly this for
			* branches, returns, and visited predicates; just output scalar_pairs
			* as is to the processed out file and deal with them later *)
		 let fname' = fname ^ ".processed" in
		 let fin = open_in fname in
		 let fout = open_out fname' in
		   output_string fout "SCALAR PAIRS INFO:\n"; 
		   let rec one_line last_site =
			 try
			   let line = input_line fin in 
			   let split = Str.split comma_regexp line in 
				 if (String.sub (hd split) 0 1) = "*" then begin
				   output_string fout (line^"\n"); one_line last_site
				 end
				 else begin
				   let site_num,info = int_of_string (hd split),(tl split) in (* transitions between stmts! *)
					 if not (last_site == site_num)
					 then begin hrep transition_table (last_site,site_num) (); end;
					 (match (hfind !site_ht site_num) with
						Scalar_pairs(_) -> output_string fout (line^"\n")
					  | _ -> hincr site_count_table line); one_line site_num
				 end
			 with End_of_file -> last_site
		   in
		   let last_site = one_line (-1) in
			 if (String.get (String.capitalize porf) 0) == 'P' then 
			   hadd transition_table (last_site, (-2)) ()
			 else 
			   hadd transition_table (last_site, (-3)) ();
			 
			 output_string fout "OTHER SITES INFO:\n";
			 hiter
			   (fun key ->
				  fun count ->
					let out_line = Printf.sprintf "%s,%d\n" key count in
					  output_string fout out_line)
			   site_count_table;
			 output_string fout "TRANSITION TABLE:\n";
			 hiter
			   (fun ((tos,from)) ->
				  fun _ ->
					let transition = Printf.sprintf "%d,%d\n" tos from in
					  output_string fout transition) transition_table;
			 close_in fin; close_out fout; (fname',porf)
	  ) !file_list;
	
end

let main () = begin
  Random.self_init ();

  let handleArg str = parse_options_in_file str in
    Arg.parse (Arg.align !options) handleArg usageMsg ;

	liter (fun (name,arg,_) ->
			 pprintf "%s %s\n" name
			   (match arg with
				| Arg.Set br 
				| Arg.Clear br 
				  -> Printf.sprintf "%b" !br 
				| Arg.Set_string sr
				  -> Printf.sprintf "%S" !sr
				| Arg.Set_int ir
				  -> Printf.sprintf "%d" !ir
				| Arg.Set_float fr
				  -> Printf.sprintf "%g" !fr
				| _ -> "?"); flush stdout
		  ) (List.sort (fun (a,_,_) (a',_,_) -> compare a a') (!options)) ; 

    (* get relevant hashtables from instrumentation *)
    let max_site = ref 0 in
    let in_channel = open_in !cbi_hash_tables in 
	  pprintf "one\n"; flush stdout;
	  ignore(Marshal.from_channel in_channel); (* first thing is the file and we don't care *)
	  pprintf "two\n"; flush stdout;
      coverage_ht := Marshal.from_channel in_channel;
	  pprintf "three\n"; flush stdout;
	  ignore(Marshal.from_channel in_channel); (* third thing is the max stmtid and we don't care *)
	  pprintf "four\n"; flush stdout;
      site_ht := Marshal.from_channel in_channel;
	  pprintf "five\n"; flush stdout;
      max_site := Marshal.from_channel in_channel;
	  pprintf "six\n"; flush stdout;
      close_in in_channel;

	  (* build_graph takes processed log files, because unprocessed = hella
		 long.  Preprocess() processes log files, saves the processed versions, and
		 returns a list of processed files for build_graph *)

	  let file_list = preprocess () in
		pprintf "preprocess\n"; flush stdout;
	  let graph = DynamicExecGraph.build_graph file_list in
		DynamicExecGraph.print_graph graph;
		(*		  if !do_cbi then begin debug, don't bother with the flag *)
		pprintf "ranking\n"; flush stdout;
		let ranked = DynamicPredict.invs_that_predict_inv graph (RunFailed) in
		  pprintf "post ranked\n"; flush stdout;
		  liter
			(fun (p1,s1,rank1) -> 
			   let exp_str = d_pred p1 in 
				 pprintf "pred: %s, state: %d, f_P: %d s_P: %d, f_P_obs: %d s_P_obs: %d, failure_P: %g, context:%g,increase: %g, imp: %g\n" 
	  			   exp_str s1 rank1.f_P rank1.s_P rank1.f_P_obs
				   rank1.s_P_obs rank1.failure_P rank1.context rank1.increase
				   rank1.importance; flush stdout)
			ranked;
		  pprintf "really post ranked\n"; flush stdout;
		  let pred = match (List.hd ranked) with (p1,s1,rank1) -> p1 in
			pprintf "Propagating and predicting the top predictor: ";
			d_pred pred; flush stdout;
			DynamicExecGraph.propagate_predicate graph pred;
			let ranked1 = DynamicPredict.invs_that_predict_inv graph (pred) in 
			let ranked2 = DynamicPredict.invs_that_predict_inv graph in
			  DynamicExecGraph.print_fault_localization graph true true !inter_weights
				
(*		  end*)
end ;;

main () ;;
