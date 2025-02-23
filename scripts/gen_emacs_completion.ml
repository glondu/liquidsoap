open Liquidsoap_runtime

let () =
  Main.run_streams := false;
  Lifecycle.after_script_parse (fun () ->
      Main.load_libs ();
      Lang_string.kprint_string ~pager:false Doc.Value.print_emacs_completions);
  Runner.run ()
