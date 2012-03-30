(* 
 * Program Repair Prototype (v2) 
 *
 * This is the main driver: it reads in options, loads the
 * program-to-be-repaired (using the given representation),
 * calls for its fault localization information, and then
 * applies a search technique to the problem. 
 *
 * Still TODO: parallelism (e.g., work queues)
 *)
open Printf
open Cil
open Global
open Elf
open Population

let representation = ref ""
let time_at_start = Unix.gettimeofday () 
let describe_machine = ref false 
let starting_genome = ref ""

let _ =
  options := !options @
  [
	"--gui", Arg.Set gui, " output suitable for reading by the phone gui";
    "--describe-machine", Arg.Set describe_machine, " describe the current machine (e.g., for cloud computing)" ;
    "--incoming-pop", Arg.Set_string incoming_pop_file, "X X contains a list of variants for the first generation" ;
    "--no-test-cache", Arg.Set Rep.no_test_cache, " do not load testing .cache file" ;
    "--no-cache", Arg.Unit (fun () -> Rep.no_rep_cache := true; Rep.no_test_cache := true), " do not load either cache file.";
    "--nht-server", Arg.Set_string Rep.nht_server, "X connect to network test cache server X" ; 
    "--nht-port", Arg.Set_int Rep.nht_port, "X connect to network test cache server on port X" ;
    "--nht-id", Arg.Set_string Rep.nht_id, "X this repair scenario's NHT identifier" ; 
    "--rep", Arg.Set_string representation, "X use representation X (c,txt,java)" ;
	"--genome", Arg.Set_string starting_genome, " modify the original genome with X. If .txt, load from a binfile, otherwise I'll assume it's a string." ;
    "-help", Arg.Unit (fun () -> raise (Arg.Bad "")),   " Display this list of options" ;
    "--help", Arg.Unit (fun () -> raise (Arg.Bad "")),   " Display this list of options" ;
  ] 


(***********************************************************************
 * Conduct a repair on a representation
 ***********************************************************************)
let process base ext (rep :('a,'b) Rep.representation) = begin

  (* WRW: Sat Oct 22 17:49:53 EDT 2011
   * As Neal notes, incoming_population must be initialized *before* the 
   * original has been loaded, otherwise the incoming_population 
   * members won't have codebanks / oracles. 
   * CLG: As of March 30, 2012, this is no longer true. *) 
	(* load the rep, either from a cache or from source *) 
  rep#load base;
	(* print debug_info *)
  rep#debug_info () ; 
  let population = if !incoming_pop_file <> "" then 
	let fin = open_in_bin !incoming_pop_file in
	  GPPopulation.deserialize ~in_channel:fin !incoming_pop_file rep 
	else [] 
  in
  let comma = Str.regexp "," in 
      
	(* Apply the requested search strategies in order. Typically there
	 * is only one, but they can be chained. *) 
  let what_to_do = Str.split comma !search_strategy in
	try
	  ignore(
		List.fold_left 
		  (fun pop ->
			fun strategy ->
				match strategy with
				| "dist" | "distributed" | "dist-net" | "net" | "dn" ->
				  Network.distributed_client rep pop
				| "brute" | "brute_force" | "bf" -> 
				  Search.brute_force_1 rep pop
				| "ga" | "gp" | "genetic" -> 
				  Search.genetic_algorithm rep pop
				| "multiopt" | "ngsa_ii" -> 
				  Multiopt.ngsa_ii rep pop
                | "mutrb" | "neut" | "neutral" ->
                  Search.neutral_variants rep
				| "oracle" ->
				  assert(!starting_genome <> "");
				  Search.oracle_search rep !starting_genome;
                | "walk" | "neutral_walk" ->
                  Search.neutral_walk rep pop
				| x -> failwith x
		  ) population what_to_do);
	  (* If we had found a repair, we could have noted it earlier and 
	   * thrown an exception. *)
	  debug "\nNo repair found.\n"  
	with Search.Found_repair(rep) -> ()
end
(***********************************************************************
 * Parse Command Line Arguments, etc. 
 ***********************************************************************)
let main () = begin
  Random.self_init () ; 
  (* By default we use and note a new random seed each time, but the user
   * can override that if desired for reproducibility. *) 
  random_seed := (Random.bits ()) ;  
  Rep.port := 800 + (Random.int 800) ;  

  let to_parse_later = ref [] in 
  let handleArg str = begin
    to_parse_later := !to_parse_later @ [str] 
  end 
  in 
  let aligned = Arg.align !options in 
  Arg.parse aligned handleArg usageMsg ; 
  List.iter parse_options_in_file !to_parse_later ;  
  (* now parse the command-line arguments again, so that they win
   * out over "./configuration" or whatnot *) 
  Arg.current := 0;
  Arg.parse aligned handleArg usageMsg ; 
  let debug_str = sprintf "repair.debug.%d" !random_seed in 
  debug_out := open_out debug_str ; 

  (* For debugging and reproducibility purposes, print out the values of
   * all command-line argument-settable global variables. *)
  List.iter (fun (name,arg,_) ->
    if name = "-help" or name = "--help" then () 
    else
    debug "%s %s\n" name 
    (match arg with
    | Arg.Set br 
    | Arg.Clear br 
    -> sprintf "%b" !br 
    | Arg.Set_string sr
    -> sprintf "%S" !sr
    | Arg.Set_int ir
    -> sprintf "%d" !ir
    | Arg.Set_float fr
    -> sprintf "%g" !fr
    | _ -> "?") 
  ) (List.sort (fun (a,_,_) (a',_,_) -> compare a a') (!options)) ; 

  (* Cloud-computing debugging: print out machine information. *)
  if !describe_machine then begin 
    List.iter (fun cmd ->  
      try 
        let uname_output = Unix.open_process_in cmd in  
        let line = input_line uname_output in 
        debug "%s: %s\n" cmd line ;  
        ignore (Unix.close_process_in uname_output)  
      with e ->  
        debug "%s: %s\n" cmd (Printexc.to_string e)  
    ) [ "uname -a" ; "date" ; "id" ; "cat /etc/redhat-release" ; 
        "grep 'model name' /proc/cpuinfo" ; 
        "grep 'MemTotal' /proc/meminfo" ;
        "grep 'SwapTotal' /proc/meminfo" ;
      ] 
  end ; 

  if !program_to_repair = "" then begin 
    abort "main: no program to repair (try --help)\n" ;
  end ; 

  (* Bookkeeping information to print out whenever we're done ... *) 
  at_exit (fun () -> 
    let tc = (Rep.num_test_evals_ignore_cache ()) in 
    debug "\nVariant Test Case Queries: %d\n" tc ;
    debug "\"Test Suite Evaluations\": %g\n\n" 
      ((float tc) /. (float (!pos_tests + !neg_tests))) ;
    
    debug "Compile Failures: %d\n" !Rep.compile_failures ; 
    debug "Wall-Clock Seconds Elapsed: %g\n" 
      ((Unix.gettimeofday ()) -. time_at_start) ;
	if not !gui then 
      Stats2.print !debug_out "Program Repair Prototype (v2)" ; 
    close_out !debug_out ;
    debug_out := stdout ; 
	if not !gui then
      Stats2.print stdout "Program Repair Prototype (v2)" ; 
  ) ; 



  Cil.initCIL () ; 
  Random.init !random_seed ; 


  if not !Rep.no_test_cache then begin 
    Rep.test_cache_load () ;
    at_exit (fun () -> 
      debug "Rep: saving test cache\n" ; 
      Rep.test_cache_save ()
    ) 
  end ;


  (* Read in the input file to be repaired and convert it to 
   * our internal representation. *) 
  let base, real_ext = split_ext !program_to_repair in
  let filetype = 
    if !representation = "" then 
      real_ext
    else 
      !representation
  in 
  Global.extension := filetype ; 
	if real_ext = "txt" && real_ext <> filetype then begin
	  Rep.use_subdirs := true; 
	end;

	match String.lowercase filetype with 

  | "s" | "asm" ->
    process base real_ext 
    ((new Asmrep.asmRep) :>('a,'b) Rep.representation)
	| "c" | "i" 
	| "cilpatch" -> 
      process base real_ext ((new Cilrep.patchCilRep) :> ('c,'d) Rep.representation)

  | "txt" | "string" ->
    process base real_ext 
    (((new Stringrep.stringRep) :>('a,'b) Rep.representation))

  | "" | "exe" | "elf" ->
      process base real_ext 
        ((new Elfrep.elfRep) :>('a,'b) Rep.representation);
  | other -> begin 
    List.iter (fun (ext,myfun) ->
      if ext = other then myfun () 
    ) !Rep.global_filetypes ; 
    debug "%s: unknown file type to repair" !program_to_repair ;
    exit 1 
  end 
end ;;

try 
  main ()  
with 
  (* as per Mike's request, try to echo system errors to the debug file *) 
  | Unix.Unix_error(e,s1,s2) as exc -> begin 
    let msg = Unix.error_message e in 
    debug "%s aborting: Unix error: %S %S %S\n" 
      Sys.argv.(0) msg s1 s2 ;
    raise exc 
  end 
  | e -> begin 
    debug "%s aborting: %s\n" Sys.argv.(0) (Printexc.to_string e) ;
    raise e 
  end 
