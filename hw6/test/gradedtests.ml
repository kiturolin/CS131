open Util.Assert
open X86
open Oat
open Driver
open Ll
open Backend
open Analysistests
open Datastructures

(* Do NOT modify this file -- we will overwrite it with our *)
(* own version when we test your project.                   *)

(* These tests will be used to grade your assignment *)

let exec_ll_ast path ll_ast args extra_files =
  let () = Platform.verb @@ Printf.sprintf "** exec_ll_ast: %s\n" path in

  let output_path = !Platform.output_path in

  (* First - optimize the ll ast *)
  let _ = Opt.do_opt := true in
  let ll_ast = Opt.optimize ll_ast in

  (* Write out the optimized ll file for debugging purposes *)
  let ll_str = Driver.string_of_ll_ast path ll_ast in
  let dot_ll_file = Platform.gen_name output_path "test" ".ll" in
  let () = write_file dot_ll_file ll_str in

  (* Run the ll backend *)
  let _ = Backend.set_liveness "dataflow" in
  let _ = Backend.set_regalloc "better" in
  let asm_ast = Backend.compile_prog ll_ast in
  let asm_str = X86.string_of_prog asm_ast in

  (* Write out the resulting .s file for debugging purposes *)
  let dot_s_file = Platform.gen_name output_path "test" ".s" in
  let _ = Driver.write_file dot_s_file asm_str in

  (* Create the executable *)
  let exec_file = Platform.gen_name output_path "exec" "" in
  let _ = Platform.link (dot_s_file::extra_files) exec_file in

  (* Run it, piping the output to a temporary file *)
  let tmp_file = Platform.gen_name output_path "tmp" ".txt" in
  let result = Driver.run_program args exec_file tmp_file in
  let () = Platform.sh (Printf.sprintf "rm -f %s %s %s" dot_ll_file exec_file tmp_file) Platform.ignore_error in
  let () = Platform.verb @@ Printf.sprintf "** Executable output:\n%s\n" result in
  result

let exec_ll_file path args =
  let ast = Driver.parse_ll_file path in
  exec_ll_ast path ast args []

let oat_file_e2e_test path args =
  let () = Platform.verb @@ Printf.sprintf "** oat_file_e2e_test: %s\n" path in
  (* Run the Oat typechecker and frontend *)
  let oat_ast = parse_oat_file path in
  Typechecker.typecheck_program oat_ast;
  let ll_ast = Frontend.cmp_prog oat_ast in
  exec_ll_ast path ll_ast args ["bin/runtime.c"]

let pass_all = ref true
let pass_all_executed_ll_file tests =
  List.map (fun (fn, ans) ->
      fn, (fun () ->
          try  assert_eqfs (fun () -> exec_ll_file fn "") ans ()
          with exn -> pass_all := false; raise exn))
    tests

let pass_all_executed_oat_file tests =
  List.map (fun (path, args, ans) ->
      (path ^ " args: " ^ args),
      (fun () ->
         try assert_eqfs (fun () -> oat_file_e2e_test path args) ans ()
         with exn -> pass_all := false; raise exn))
    tests

let compile_with_config live regalloc ll_ast =
  let open Registers in
  let open Backend in
  let _ = set_liveness live in
  let _ = set_regalloc regalloc in
  let asm_ast = compile_prog ll_ast in
  let (histogram,size) = histogram_of_prog asm_ast in
  histogram, size, asm_ast

let assert_quality fn ll_ast =
  if not !pass_all then failwith "Your register allocator failed a correctness test" else
  let _ = Opt.do_opt := true in
  let ll_ast = Opt.optimize ll_ast in
  let h_greedy, size_greedy, x86_greedy = compile_with_config "dataflow" "greedy" ll_ast in
  let h_better, size_better, x86_better = compile_with_config "dataflow" "better" ll_ast in  
  let mem_greedy = Registers.memop_of_prog x86_greedy in
  let mem_better = Registers.memop_of_prog x86_better in  
  let msg =
    Printf.sprintf "greedy sz: %4d mem: %4d\t\tbetter sz: %4d mem: %4d \t diff_sz: %4d diff_mem: %4d - %s\n"
      size_greedy mem_greedy size_better mem_better (size_greedy - size_better) (mem_greedy - mem_better) fn
  in
  let _ = if !Driver.print_regs_flag then begin Printf.printf "%s" msg end
  in
  if
    mem_better < mem_greedy then ()
  else if
    size_better < size_greedy then ()
  else failwith @@ Printf.sprintf "GREEDY is better\n%s" msg

let assert_quality_oat fn () =
  let oat_ast = parse_oat_file fn in
  let ll_ast = Frontend.cmp_prog oat_ast in
  assert_quality fn ll_ast

let quality_oat tests =
  List.map (fun (fn, _, _) -> fn, assert_quality_oat fn) tests



let fdecl_of_path path =
  Platform.verb @@ Printf.sprintf "* processing file: %s\n" path;
  let ll_ast = parse_ll_file path in
  match ll_ast.Ll.fdecls with
  | [_, fdecl] -> (fdecl, ll_ast.tdecls)
  | _ -> failwith "test expected one fdecl"

let ll_dfa_file_test path compare analyze expected =
  let (fdecl, _) = fdecl_of_path path in
  let dfa = analyze (Cfg.of_ast fdecl) in
  compare dfa expected
  
let throw_key_diff compare val_to_string a b =
  let keys = LblM.diff_keys compare a b in
  if List.length keys == 0 then ()
  else begin
    let str_a = LblM.to_string val_to_string a in
    let str_b = LblM.to_string val_to_string b in
    failwith @@ Printf.sprintf "Output differs at labels: %s in maps\n%s\n%s\n"
      (String.concat ", " keys)
      str_a
      str_b
  end
    
let ll_opt_file_test path optimize ans =
  let (fdecl, tdecls) = fdecl_of_path path in
  let expected = (Cfg.of_ast @@ fst @@ fdecl_of_path ans).Cfg.blocks in
  let opt = optimize (Cfg.of_ast fdecl) in
  let printer k b = Printf.sprintf "%s %s" (Lbl.to_string k) (Llutil.string_of_block tdecls b) in
  throw_key_diff Llutil.compare_block printer opt expected

let dfa_liveness_file (tests : (string * 'a Datastructures.LblM.t) list) =
  let open Liveness in
  let analyze f = Graph.dfa (analyze f) in
  let printer k s = Printf.sprintf "%s %s" (Lbl.to_string k) (UidS.to_string s) in  
  List.map (fun (path, ans) -> 
    ("liveness: " ^ path, 
     fun () -> ll_dfa_file_test path (throw_key_diff Fact.compare printer) analyze ans)) tests

let dfa_alias_file tests =
  let open Alias in
  let analyze f = Graph.dfa (analyze f) in
  let printer k f = Printf.sprintf "%s %s" (Lbl.to_string k) (Alias.Fact.to_string f) in    
  List.map (fun (path, ans) ->
    ("alias: " ^ path, 
     fun () -> ll_dfa_file_test path (throw_key_diff Fact.compare printer) analyze ans)) tests

let dfa_constprop_file tests =
  let open Constprop in
  let analyze f = Graph.dfa (analyze f) in
  let printer k f = Printf.sprintf "%s %s" (Lbl.to_string k) (Constprop.Fact.to_string f) in      
  List.map (fun (path, ans) ->
    ("constprop: " ^ path, 
     fun () -> ll_dfa_file_test path (throw_key_diff Fact.compare printer) analyze ans)) tests

let opt_dce_file tests =
  let opt g =
    let ag = Alias.analyze g in
    let lg = Liveness.analyze g in
    let g = Dce.run lg ag g in
    g.Cfg.blocks
  in
  List.map (fun (path, ans) ->
      (Printf.sprintf "dce opt: %s, %s" 
                      (Filename.basename path) (Filename.basename ans), 
       fun () -> ll_opt_file_test path opt ans)) tests

let opt_constfold_file tests =
  let opt g =
    let cg = Constprop.analyze g in
    let g = Constprop.run cg g in
    g.Cfg.blocks
  in
  List.map (fun (path, ans) ->
      (Printf.sprintf "constprop opt: %s, %s" 
                      (Filename.basename path) (Filename.basename ans), 
       fun () -> ll_opt_file_test path opt ans)) tests

(* this test harness is used for part iv of the homework -------------------- *)
let executed_fullopt_file tests =
  let opt n g = let g = Opt.pass n g in g.Cfg.blocks in
  List.map (fun (n, path, ans) ->
      (Printf.sprintf "fullopt %d iterations: %s" n path,
       fun () -> ll_opt_file_test path (opt n) ans)) tests


let binop_tests =
  [ "llprograms/add.ll", "14"
  ; "llprograms/sub.ll", "1"
  ; "llprograms/mul.ll", "45"
  ; "llprograms/and.ll", "0"
  ; "llprograms/or.ll",  "1"
  ; "llprograms/xor.ll", "0"
  ; "llprograms/shl.ll", "168"
  ; "llprograms/lshr.ll", "10"
  ; "llprograms/ashr.ll", "5" ]

let calling_convention_tests =
  [ "llprograms/call.ll", "42"
  ; "llprograms/call1.ll", "17" 
  ; "llprograms/call2.ll", "19"
  ; "llprograms/call3.ll", "34"
  ; "llprograms/call4.ll", "34"
  ; "llprograms/call5.ll", "24"
  ; "llprograms/call6.ll", "26"            
  ; "llprograms/call7.ll", "7"
  ; "llprograms/call8.ll", "21"
  ]

let memory_tests =
  [ "llprograms/alloca1.ll", "17"
  ; "llprograms/alloca2.ll", "17"
  ; "llprograms/global1.ll", "12"    
  ]

let terminator_tests =
  [ "llprograms/return.ll", "0"
  ; "llprograms/return42.ll", "42"
  ; "llprograms/br1.ll", "9"
  ; "llprograms/br2.ll", "17"    
  ; "llprograms/cbr1.ll", "7"
  ; "llprograms/cbr2.ll", "9"
  ; "llprograms/cbr3.ll", "9"
  ]

let bitcast_tests =
  [ "llprograms/bitcast1.ll", "3"
  ]

let gep_tests =
  [ "llprograms/gep1.ll", "6"
  ; "llprograms/gep2.ll", "4"
  ; "llprograms/gep3.ll", "1"
  ; "llprograms/gep4.ll", "2"
  ; "llprograms/gep5.ll", "4"
  ; "llprograms/gep6.ll", "7"
  ; "llprograms/gep7.ll", "7"    
  ; "llprograms/gep8.ll", "2"
  ; "llprograms/gep9.ll", "5"
  ; "llprograms/gep10.ll", "3"            
  ]


let arithmetic_tests =
  [ "llprograms/add_twice.ll", "29" 
  ; "llprograms/sub_neg.ll", "255" (* Why, oh why, does the termianl only report the last byte? *)
  ; "llprograms/arith_combo.ll", "4"
  ; "llprograms/return_intermediate.ll", "18" ]

let sum_tree_tests = ["llprograms/sum_tree.ll", "116"]
let gcd_euclidian_tests = [ "llprograms/gcd_euclidian.ll", "2"]
let sieve_tests = [["bin/cinterop.c"], "llprograms/sieve.ll", [], "1"]
let binary_search_tests = ["llprograms/binarysearch.ll", "8"]
let gep_5_deep_tests = ["llprograms/qtree.ll", "3"]
let binary_gcd_tests = ["llprograms/binary_gcd.ll", "3"]
let linear_search_tests = ["llprograms/linear_search.ll", "1"]
let lfsr_tests = ["llprograms/lfsr.ll", "108"]
let naive_factor_tests = 
  [ "llprograms/naive_factor_prime.ll", "1"
  ; "llprograms/naive_factor_nonprime.ll", "0"
  ]
let euclid_recursive_test = ["llprograms/euclid.ll", "2"]
let matmul_tests = ["llprograms/matmul.ll", "0"]

let large_tests = [ "llprograms/list1.ll", "3"
                  ; "llprograms/cbr.ll", "42"
                  ; "llprograms/factorial.ll", "120"
                  ; "llprograms/factrect.ll", "120"
                  ]

let ll_tests =
  binop_tests 
  @ terminator_tests 
  @ memory_tests 
  @ calling_convention_tests 
  @ bitcast_tests
  @ gep_tests 
  @ arithmetic_tests 
  @ sum_tree_tests
  @ gcd_euclidian_tests
  @ binary_search_tests
  @ gep_5_deep_tests
  @ binary_gcd_tests
  @ linear_search_tests
  @ lfsr_tests
  @ naive_factor_tests
  @ euclid_recursive_test
  @ matmul_tests
  @ large_tests

(* Should not be used for quality tests *)
let greedy_is_good_tests = [
 ("hw4programs/easyrun1.oat", "", "17");
 ("hw4programs/easyrun2.oat", "", "35");
 ("hw4programs/easyrun5.oat", "", "212");
 ("hw4programs/easyrun6.oat", "", "9");
 ("hw4programs/easyrun7.oat", "", "23");
 ("hw4programs/easyrun8.oat", "", "160");
 ("hw4programs/path1.oat", "", "17");
 ("hw4programs/run26.oat", "", "0");
 ("hw4programs/run27.oat", "", "99");
 ("hw4programs/run29.oat", "", "1");
 ("hw4programs/run30.oat", "", "9");
 ("hw4programs/run31.oat", "", "9");
 ("hw4programs/run13.oat", "", "1");
 ("hw4programs/run38.oat", "", "31");
 ("hw4programs/run40.oat", "", "8");
 ("hw4programs/run60.oat", "", "85");
 ("hw4programs/heap.oat", "", "1");
 ("hw5programs/ifq2.oat", "", "5");
 ("hw5programs/length1.oat", "", "5");
 ("hw4programs/lcs.oat", "", "OAT0");
]


let hw4_easiest_tests = [
  ("hw4programs/easyrun3.oat", "", "73");
  ("hw4programs/easyrun4.oat", "", "6");
  ("hw4programs/easyrun9.oat", "", "236");
]

(* Should not be used for quality tests *)
let hw4_globals_tests = [
  ("hw4programs/globals1.oat", "", "42");
  ("hw4programs/globals2.oat", "", "17");
  ("hw4programs/globals3.oat", "", "17");
  ("hw4programs/globals4.oat", "", "5");
  ("hw4programs/globals5.oat", "", "17");
  ("hw4programs/globals6.oat", "", "15");
]

let hw4_path_tests = [
 ("hw4programs/path2.oat", "", "35");
 ("hw4programs/path3.oat", "", "3");
 ("hw4programs/arrayargs1.oat", "", "17");
 ("hw4programs/arrayargs2.oat", "", "17");
 ("hw4programs/arrayargs4.oat", "", "0"); 
]

let hw4_easy_tests = [
    ("hw4programs/run28.oat", "", "18");
    ("hw4programs/run32.oat", "", "33");
    ("hw4programs/run21.oat", "", "99");
    ("hw4programs/run33.oat", "", "1");
    ("hw4programs/run34.oat", "", "66");
    ("hw4programs/run39.oat", "a", "2");
    ("hw4programs/run42.oat", "", "2");
    ("hw4programs/run49.oat", "", "abc0");
    ("hw4programs/run50.oat", "", "abcde0");
    ("hw4programs/run61.oat", "", "131");
]

let hw4_medium_tests = [
  ("hw4programs/fact.oat", "", "1200");
  ("hw4programs/run1.oat", "", "153");
  ("hw4programs/run2.oat", "", "6");
  ("hw4programs/run8.oat", "", "2");
  ("hw4programs/run9.oat", "", "4");
  ("hw4programs/run10.oat", "", "5");
  ("hw4programs/run11.oat", "", "7");
  ("hw4programs/run14.oat", "", "16");
  ("hw4programs/run15.oat", "", "19");
  ("hw4programs/run16.oat", "", "13");
  ("hw4programs/run22.oat", "", "abc0");
  ("hw4programs/run23.oat", "", "1230");
  ("hw4programs/run25.oat", "", "nnn0");
  ("hw4programs/run46.oat", "", "420");
  ("hw4programs/run47.oat", "", "3");
  ("hw4programs/run48.oat", "", "11");
  ("hw4programs/lib4.oat", "", "53220");
  ("hw4programs/lib5.oat", "", "20");
  ("hw4programs/lib6.oat", "", "56553");
  ("hw4programs/lib7.oat", "", "53");
  ("hw4programs/lib8.oat", "", "Hello world!0");
  ("hw4programs/lib9.oat", "a b c d", "abcd5");
  ("hw4programs/lib11.oat", "", "45");
  ("hw4programs/lib14.oat", "", "~}|{zyxwvu0");
  ("hw4programs/lib15.oat", "123456789", "456780");
  ("hw4programs/regalloctest.oat", "", "0");
  ("hw4programs/regalloctest2.oat", "", "137999986200000000")  
]

let hw4_hard_tests = [
("hw4programs/fac.oat", "", "120");
("hw4programs/bsort.oat", "", "y}xotnuw notuwxy}255");
("hw4programs/msort.oat", "", "~}|{zyxwvu uvwxyz{|}~ 0");
("hw4programs/msort2.oat", "", "~}|{zyxwvu uvwxyz{|}~ 0");
("hw4programs/selectionsort.oat", "", "01253065992000");
("hw4programs/matrixmult.oat", "", "19 16 13 23 \t5 6 7 6 \t19 16 13 23 \t5 6 7 6 \t0");
]

let hw4_old_student_tests = [
    ("hw4programs/binary_search.oat", "", "Correct!0")
  ; ("hw4programs/xor_shift.oat", "", "838867572\n22817190600")
  ; ("hw4programs/sieve.oat", "", "25")
  ; ("hw4programs/fibo.oat", "", "0")
  ; ("hw4programs/lfsr.oat", "", "TFTF FFTT0")
  ; ("hw4programs/gnomesort.oat", "", "01253065992000")
  ; ("hw4programs/josh_joyce_test.oat", "", "0")
  ; ("hw4programs/gcd.oat", "", "16")
  ; ("hw4programs/insertion_sort.oat", "", "42")
  ; ("hw4programs/maxsubsequence.oat", "", "107")
]

let struct_tests = [
("hw5programs/compile_assign_struct.oat", "", "16");
("hw5programs/compile_basic_struct.oat", "", "7");
("hw5programs/compile_global_struct.oat", "", "254");
("hw5programs/compile_nested_struct.oat", "", "10");
("hw5programs/compile_return_struct.oat", "", "0");
("hw5programs/compile_struct_array.oat", "", "15");
("hw5programs/compile_struct_fptr.oat", "", "7");
("hw5programs/compile_various_fields.oat", "", "hello253"); 
]

let fptr_tests = [
  ("hw5programs/compile_array_fptr.oat", "", "2");
  ("hw5programs/compile_func_argument.oat", "", "4");
  ("hw5programs/compile_global_fptr.oat", "", "7");
  ("hw5programs/compile_global_fptr_unordered.oat", "", "2");
  ("hw5programs/compile_scall_fptr.oat", "", "4");
  ("hw5programs/compile_var_fptr.oat", "", "1");
  ("hw5programs/compile_local_fptr.oat", "", "5");
  ("hw5programs/compile_function_shadow.oat", "", "12");
  ("hw5programs/compile_global_struct_fptr.oat", "", "20");
  ("hw5programs/compile_builtin_argument.oat", "", "abab0");    
]

let regalloc_challenge_tests = [
 ("hw4programs/arrayargs3.oat", "", "34");
 ("hw4programs/run41.oat", "", "3");
 ("hw4programs/run51.oat", "", "341");
 ("hw4programs/run52.oat", "", "15");
 ("hw4programs/run54.oat", "", "10");
 ("hw4programs/run55.oat", "", "6");    
 ("hw4programs/qsort.oat", "", "kpyf{shomfhkmopsy{255");
 ("hw4programs/count_sort.oat", "", "AFHZAAEYC\nAAACEFHYZ0");
]

let new_tests = [
  ("hw5programs/ifq1.oat", "", "4");
  ("hw5programs/length2.oat", "", "3");  
  ("hw5programs/initarr1.oat", "", "1");
  ("hw5programs/initarr2.oat", "", "2");
]


let oat_regalloc_quality_tests =
  hw4_easiest_tests
  @ hw4_path_tests
  @ hw4_easy_tests
  @ hw4_medium_tests
  @ hw4_hard_tests
  @ hw4_old_student_tests
  @ struct_tests
  @ fptr_tests
  @ new_tests
  @ regalloc_challenge_tests
  

let oat_correctness_tests =
  oat_regalloc_quality_tests
  @ hw4_globals_tests
  @ greedy_is_good_tests

let dce_opt_tests =
  [ "llprograms/analysis1_cf_opt.ll", "llprograms/analysis1_dce_opt.ll"
  ; "llprograms/analysis2_cf_opt.ll", "llprograms/analysis2_dce_opt.ll"
  ; "llprograms/analysis3_cf_opt.ll", "llprograms/analysis3_dce_opt.ll"
  ; "llprograms/analysis4_cf_opt.ll", "llprograms/analysis4_dce_opt.ll"
  ; "llprograms/analysis5_cf_opt.ll", "llprograms/analysis5_dce_opt.ll"
  ; "llprograms/analysis6_cf_opt.ll", "llprograms/analysis6_dce_opt.ll"
  ; "llprograms/analysis7_cf_opt.ll", "llprograms/analysis7_dce_opt.ll"
  ; "llprograms/analysis8_cf_opt.ll", "llprograms/analysis8_dce_opt.ll"
  ; "llprograms/analysis9_cf_opt.ll", "llprograms/analysis9_dce_opt.ll"
  ; "llprograms/analysis10_cf_opt.ll", "llprograms/analysis10_dce_opt.ll"
  ; "llprograms/analysis11_cf_opt.ll", "llprograms/analysis11_dce_opt.ll"
  ; "llprograms/analysis12_cf_opt.ll", "llprograms/analysis12_dce_opt.ll"
  ; "llprograms/analysis13_cf_opt.ll", "llprograms/analysis13_dce_opt.ll"
  ; "llprograms/analysis14_cf_opt.ll", "llprograms/analysis14_dce_opt.ll"
  ; "llprograms/analysis15_cf_opt.ll", "llprograms/analysis15_dce_opt.ll"
  ; "llprograms/analysis16_cf_opt.ll", "llprograms/analysis16_dce_opt.ll"
  ; "llprograms/analysis17_cf_opt.ll", "llprograms/analysis17_dce_opt.ll"
  ; "llprograms/analysis18_cf_opt.ll", "llprograms/analysis18_dce_opt.ll"
  ; "llprograms/analysis19_cf_opt.ll", "llprograms/analysis19_dce_opt.ll"
  ]

let constprop_opt_tests =
  [ "llprograms/analysis1.ll", "llprograms/analysis1_cf_opt.ll"
  ; "llprograms/analysis2.ll", "llprograms/analysis2_cf_opt.ll"
  ; "llprograms/analysis3.ll", "llprograms/analysis3_cf_opt.ll"
  ; "llprograms/analysis4.ll", "llprograms/analysis4_cf_opt.ll"
  ; "llprograms/analysis5.ll", "llprograms/analysis5_cf_opt.ll"
  ; "llprograms/analysis6.ll", "llprograms/analysis6_cf_opt.ll"
  ; "llprograms/analysis7.ll", "llprograms/analysis7_cf_opt.ll"
  ; "llprograms/analysis8.ll", "llprograms/analysis8_cf_opt.ll"
  ; "llprograms/analysis9.ll", "llprograms/analysis9_cf_opt.ll"
  ; "llprograms/analysis10.ll", "llprograms/analysis10_cf_opt.ll"
  ; "llprograms/analysis11.ll", "llprograms/analysis11_cf_opt.ll"
  ; "llprograms/analysis12.ll", "llprograms/analysis12_cf_opt.ll"
  ; "llprograms/analysis13.ll", "llprograms/analysis13_cf_opt.ll"
  ; "llprograms/analysis14.ll", "llprograms/analysis14_cf_opt.ll"
  ; "llprograms/analysis15.ll", "llprograms/analysis15_cf_opt.ll"
  ; "llprograms/analysis16.ll", "llprograms/analysis16_cf_opt.ll"
  ; "llprograms/analysis17.ll", "llprograms/analysis17_cf_opt.ll"
  ; "llprograms/analysis18.ll", "llprograms/analysis18_cf_opt.ll"
  ; "llprograms/analysis19.ll", "llprograms/analysis19_cf_opt.ll"
  ]



let tests : suite =
  [
  GradedTest("solver / liveness analysis tests", 10, dfa_liveness_file liveness_analysis_tests);
  GradedTest("alias analysis tests", 10, dfa_alias_file alias_analysis_tests);
  GradedTest("dce optimization tests", 10, opt_dce_file dce_opt_tests);
  GradedTest("constprop analysis tests", 15, dfa_constprop_file constprop_analysis_tests);
  GradedTest("constprop optimization tests", 10, opt_constfold_file constprop_opt_tests);
  Test("ll regalloc correctness tests", pass_all_executed_ll_file ll_tests);
  Test("oat regalloc correctness tests", pass_all_executed_oat_file (oat_correctness_tests @ regalloc_challenge_tests));
  GradedTest("oat regalloc quality tests", 35, quality_oat oat_regalloc_quality_tests);
  
  
  ]

let manual_tests : suite = [
    GradedTest ("Submitted Test Case", 5,
              [("manually", assert_eq true false)]
    )
  ; GradedTest ("Performance Comparison", 5,
              [("manually", assert_eq true false)]
    )
  ]

let graded_tests : suite =
  tests @
  manual_tests
