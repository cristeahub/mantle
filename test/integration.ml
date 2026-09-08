(* Exercise public shell workflows with temporary homes and an OCaml fake Codex. *)
let ( / ) = Filename.concat
let quote value = "'" ^ String.concat "'\\''" (String.split_on_char '\'' value) ^ "'"
let contains text part =
  try ignore (Str.search_forward (Str.regexp_string part) text 0); true with Not_found -> false
let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () -> really_input_string channel (in_channel_length channel))
let write path contents =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel contents)
let copy source target = write target (read source); Unix.chmod target 0o755
let mkdir path = Unix.mkdir path 0o700
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
    Array.iter (fun name -> remove (path / name)) (Sys.readdir path);
    Unix.rmdir path)
  else Unix.unlink path
let replace env values = values @ List.filter (fun (name, _) -> not (List.mem_assoc name values)) env
let wait_until description ready =
  let deadline = Unix.gettimeofday () +. 10. in
  while not (ready ()) do
    if Unix.gettimeofday () >= deadline then failwith ("timed out: " ^ description);
    Unix.sleepf 0.01
  done

type invocation = { codex_home : string option; cwd : string; args : string list }

(* The test executable is also copied onto PATH as codex, without another runtime. *)
let fake_codex () =
  let args = List.tl (Array.to_list Sys.argv) in
  if args = ["login"; "status"] then (
    prerr_endline "SECRET_NATIVE_OUTPUT_MUST_NOT_LEAK";
    exit (int_of_string (Option.value (Sys.getenv_opt "FAKE_LOGIN_EXIT") ~default:"0")));
  if args = ["hold"] then (
    write (Sys.getenv "READY") "";
    wait_until "fake Codex release" (fun () -> Sys.file_exists (Sys.getenv "RELEASE")));
  let record = { codex_home = Sys.getenv_opt "CODEX_HOME"; cwd = Sys.getcwd (); args } in
  let contents = Marshal.to_string record [] in
  match Sys.getenv_opt "RECORD" with
  | Some path -> write path contents
  | None -> output_string stdout contents

type child = { pid : int; output_path : string; error_path : string; mutable status : Unix.process_status option }
type result = { output : string; error : string }

let start ~root ~env ~cwd ?input arguments =
  let output_path = Filename.temp_file ~temp_dir:root "stdout-" "" in
  let error_path = Filename.temp_file ~temp_dir:root "stderr-" "" in
  let input_fd = match input with Some fd -> fd | None -> Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
  let output_fd = Unix.openfile output_path [Unix.O_WRONLY] 0 in
  let error_fd = Unix.openfile error_path [Unix.O_WRONLY] 0 in
  let environment = Array.of_list (List.map (fun (name, value) -> name ^ "=" ^ value) env) in
  flush_all ();
  let pid = Unix.fork () in
  if pid = 0 then (
    try
      ignore (Unix.setsid ());
      Unix.chdir cwd;
      Unix.dup2 input_fd Unix.stdin;
      Unix.dup2 output_fd Unix.stdout;
      Unix.dup2 error_fd Unix.stderr;
      List.iter Unix.close [input_fd; output_fd; error_fd];
      Unix.execve (List.hd arguments) (Array.of_list arguments) environment
    with exn -> prerr_endline (Printexc.to_string exn); exit 127);
  List.iter Unix.close [input_fd; output_fd; error_fd];
  { pid; output_path; error_path; status = None }

let stop child =
  if child.status = None then (
    (try Unix.kill (-child.pid) Sys.sigkill with
     | Unix.Unix_error ((Unix.ESRCH | Unix.EPERM), _, _) ->
       (try Unix.kill child.pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ()));
    child.status <- Some (snd (Unix.waitpid [] child.pid)))

let finish ?(expected = 0) description child =
  Fun.protect ~finally:(fun () -> stop child) (fun () ->
    wait_until description (fun () ->
      let pid, status = Unix.waitpid [Unix.WNOHANG] child.pid in
      if pid = 0 then false else (child.status <- Some status; true));
    let result = { output = read child.output_path; error = read child.error_path } in
    if child.status <> Some (Unix.WEXITED expected) then
      failwith (Printf.sprintf "%s\nstdout: %S\nstderr: %S" description result.output result.error);
    result)

let shells = ["/bin/bash"; "/bin/zsh"]
let flags shell = if Filename.basename shell = "bash" then ["--noprofile"; "--norc"] else ["-f"]
let init = "eval \"$(\"$BINARY\" init \"$TEST_SHELL\")\"\n"
let decode contents : invocation = Marshal.from_string contents 0

let check_shell root binary_dir binary shell =
  assert (Sys.file_exists shell);
  let name = Filename.basename shell in
  let user_dir = root / (name ^ " home ' $(touch INJECTED) `touch INJECTED` ; % []\nline") in
  let cwd = root / (name ^ " project") in
  mkdir user_dir;
  mkdir cwd;
  let profiles = user_dir / ".local/share/mantle/profiles" in
  let work = profiles / "work/codex" and private_profile = profiles / "private/codex" in
  let custom = profiles / "client-a_2/codex" in
  let env = ["PATH", binary_dir ^ ":/usr/bin:/bin"; "HOME", user_dir; "TERM", "dumb";
             "SHELL", shell; "BINARY", binary; "TEST_SHELL", name; "WORK", work; "PRIVATE", private_profile; "CUSTOM", custom] in
  let spawn extra script =
    start ~root ~env:(replace env extra) ~cwd (shell :: flags shell @ ["-c"; "set -eu\n" ^ script]) in
  let run ?(extra = []) ?(expected = 0) script =
    finish ~expected (shell ^ "\n" ^ script) (spawn extra script) in
  let check ?(extra = []) script = ignore (run ~extra script) in

  (* Defaults are available before any profile has been initialized; listing is read-only. *)
  assert ((run "\"$BINARY\" list").output = "private\nwork\n");
  let result = run (init ^ "if mantle unknown; then exit 99; fi\ntest \"${CODEX_HOME+x}\" = \"\"") in
  assert (contains result.error "mantle create unknown");
  assert (not (Sys.file_exists (user_dir / ".local")));
  (* Direct execution cannot change a parent shell; malformed commands emit no code. *)
  List.iter (fun args ->
    let result = run ~expected:1 ("\"$BINARY\" " ^ String.concat " " (List.map quote args)) in
    assert (result.output = ""))
    [["work"]; ["private"]; ["off"]; ["invalid"]; ["init"; "fish"];
     ["work"; "extra"]; ["prompt"; "extra"]; ["_home"; "other"];
     ["create"]; ["create"; "client"; "extra"]; ["list"; "extra"]];
  let result = run (init ^ {|
test "$(mantle prompt)" = ""
test "$("$BINARY" prompt)" = ""
mantle off
test "${CODEX_HOME+x}" = ""
mantle work
test "$CODEX_HOME" = "$WORK"
test "$(mantle prompt)" = '(work)'
test "$("$BINARY" prompt)" = '(work)'
test "$(mantle prompt; printf X)" = '(work)X'
codex 'arg with spaces' '' "quote'" '$(touch INJECTED)' '--flag=*'
mantle private
test "$CODEX_HOME" = "$PRIVATE"
test "$(mantle prompt; printf X)" = '(private)X'
eval "$(mantle init "$TEST_SHELL")"
eval "$(mantle init "$TEST_SHELL")"
mantle work
mantle work
test "$(mantle prompt)" = '(work)'
if mantle work extra; then exit 90; fi
if mantle other; then exit 91; fi
test "$CODEX_HOME" = "$WORK"
test "$(mantle prompt)" = '(work)'
mantle off
mantle off
test "${CODEX_HOME+x}" = ""
test "${MANTLE_CONTEXT+x}" = ""
test "$(mantle prompt; printf X)" = X
test "$("$BINARY" prompt; printf X)" = X
|}) in
  assert (decode result.output = { codex_home = Some work; cwd;
    args = ["arg with spaces"; ""; "quote'"; "$(touch INJECTED)"; "--flag=*"] });
  assert (not (Sys.file_exists (cwd / "INJECTED")));

  (* Every profile directory is private; repeated setup preserves exact file contents. *)
  let mode path = (Unix.stat path).Unix.st_perm land 0o777 in
  List.iter (fun path -> assert (mode path = 0o700))
    [Filename.dirname profiles; profiles; profiles / "work"; profiles / "private"; work; private_profile];
  let config = work / "config.toml" and auth = work / "auth.json" in
  assert (mode config = 0o600);
  let original_config = read config ^ "\n# User setting\nmodel = \"custom-model\"\n" in
  let original_auth = "{\"fake\":\"DO_NOT_READ_OR_CHANGE\"}\n" in
  write config original_config;
  write auth original_auth;
  Unix.chmod auth 0o644;
  check (init ^ "mantle work\nmantle private\nmantle work");
  assert (read config = original_config && read auth = original_auth && mode auth = 0o600);
  assert (not (Sys.file_exists (private_profile / "auth.json")));

  (* Custom profiles use the same commands, homes, permissions, and preservation rules. *)
  check (init ^ {|
"$BINARY" create client-a_2 >/dev/null
test "${CODEX_HOME+x}" = ""
test "$(mantle prompt)" = ""
mantle work
mantle create playground >/dev/null
test "$CODEX_HOME" = "$WORK"
test "$(mantle prompt)" = '(work)'
mantle client-a_2
test "$CODEX_HOME" = "$CUSTOM"
test "$(mantle prompt; printf X)" = '(client-a_2)X'
test "$("$BINARY" prompt; printf X)" = '(client-a_2)X'
if mantle unknown; then exit 97; fi
if mantle client-a_2 extra; then exit 98; fi
test "$CODEX_HOME" = "$CUSTOM"
test "$(mantle prompt)" = '(client-a_2)'
mantle off
test "${CODEX_HOME+x}" = ""
|});
  let listing = "client-a_2\nplayground\nprivate\nwork\n" in
  assert ((run (init ^ "mantle list")).output = listing);
  assert (not (Sys.file_exists (profiles / "unknown")));
  assert (mode custom = 0o700 && mode (Filename.dirname custom) = 0o700 && mode (custom / "config.toml") = 0o600);
  let custom_config = read (custom / "config.toml") ^ "# Keep custom settings\n" in
  List.iter (fun (file, contents) -> write (custom / file) contents)
    ["config.toml", custom_config; "auth.json", original_auth; "history.jsonl", "custom history\n"];
  let result = run (init ^ {|
mantle create client-a_2 >/dev/null
mantle client-a_2
codex 'custom argument' ''
mantle create client-a_2 >/dev/null
mantle off
|}) in
  assert (decode result.output = { codex_home = Some custom; cwd; args = ["custom argument"; ""] });
  assert (read (custom / "config.toml") = custom_config && read (custom / "auth.json") = original_auth);
  assert (read (custom / "history.jsonl") = "custom history\n" && mode (custom / "auth.json") = 0o600);
  let result = run (init ^ "mantle client-a_2\nmantle status") in
  assert (contains result.output "Context: client-a_2 (selection only)" && contains result.output custom);

  (* Names cannot escape their directory, inject prompt syntax, or shadow commands. *)
  List.iter (fun profile ->
    let result = run ~expected:1 ("\"$BINARY\" create " ^ quote profile) in
    assert (result.output = ""))
    [""; "."; ".."; "../escape"; "/escape"; "a/b"; "Upper"; "_internal"; "--flag";
     "a b"; "a$(touch INJECTED)"; "a%F{red}"; "a\nline"; String.make 33 'a';
     "init"; "list"; "create"; "off"; "status"; "prompt"];
  assert ((run "\"$BINARY\" list").output = listing);
  assert (not (Sys.file_exists (cwd / "INJECTED")));
  Unix.symlink (profiles / "work") (profiles / "alias");
  write (profiles / "notes") "not a profile";
  assert ((run "\"$BINARY\" list").output = listing);
  check (init ^ "mantle client-a_2\nif mantle alias; then exit 99; fi\nif mantle create alias; then exit 99; fi\ntest \"$CODEX_HOME\" = \"$CUSTOM\"");
  Unix.unlink (profiles / "alias");
  Unix.unlink (profiles / "notes");
  List.iter (fun previous ->
    check ~extra:["CODEX_HOME", previous; "PREVIOUS", previous] (init ^ {|
mantle work
mantle private
mantle client-a_2
eval "$(mantle init "$TEST_SHELL")"
mantle off
test "${CODEX_HOME+x}" = x
test "$CODEX_HOME" = "$PREVIOUS"
test "$(mantle prompt)" = ""
|})) [""; root / "original ' $x `literal` ; []\ntrailing\n"];
  let result = run (init ^ {|
CODEX_HOME='shell-local value'
mantle work
mantle client-a_2
mantle off
test "$CODEX_HOME" = 'shell-local value'
codex
|}) in
  assert ((decode result.output).codex_home = None);
  check (init ^ {|
export CODEX_HOME
test_previous_set=${CODEX_HOME+x}
mantle work
mantle off
test "${CODEX_HOME+x}" = "$test_previous_set"
test "${CODEX_HOME-}" = ""
|});
  List.iter (fun variable ->
    let result = run ~extra:[variable, "SECRET_OVERRIDE"]
      (init ^ "mantle create client-a_2 >/dev/null\nif mantle work; then exit 99; fi\nif mantle client-a_2; then exit 99; fi\ntest \"${CODEX_HOME+x}\" = \"\"") in
    assert (contains result.error variable);
    assert (not (contains (result.output ^ result.error) "SECRET_OVERRIDE")))
    ["CODEX_ACCESS_TOKEN"; "CODEX_API_KEY"; "OPENAI_API_KEY"; "CODEX_SQLITE_HOME"];

  (* Child shells inherit both context and the original restoration snapshot. *)
  List.iter (fun previous ->
    let extra = ["PREVIOUS", Option.value previous ~default:""; "EXPECT_SET", if previous = None then "" else "x"]
      @ (match previous with None -> [] | Some value -> ["CODEX_HOME", value]) in
    List.iter (fun child ->
      let script = "set -eu\neval \"$(\"$BINARY\" init " ^ Filename.basename child ^ ")\"\n" ^ {|
test "$CODEX_HOME" = "$WORK"
test "$(mantle prompt)" = '(work)'
mantle client-a_2
test "$CODEX_HOME" = "$CUSTOM"
mantle off
test "${CODEX_HOME+x}" = "$EXPECT_SET"
test "${CODEX_HOME-}" = "$PREVIOUS"
|} in
      check ~extra (init ^ "mantle work\n" ^ String.concat " " (List.map quote (child :: flags child @ ["-c"; script]))
        ^ "\ntest \"$CODEX_HOME\" = \"$WORK\"\ntest \"$(mantle prompt)\" = '(work)'")) shells)
    [None; Some ""; Some (root / "original custom")];

  (* Readonly variables and failed setup must leave the previous environment intact. *)
  List.iter (fun variable -> check (init ^ "readonly " ^ variable ^ "=locked\n" ^ {|
if mantle work; then exit 92; fi
test "${CODEX_HOME-locked}" = locked
test "${_MANTLE_PREV_HOME-locked}" = locked
test "${_MANTLE_PREV_STATE-locked}" = locked
test "${_MANTLE_SELECTED_HOME-locked}" = locked
test "${MANTLE_CONTEXT-locked}" = locked
test "$(mantle prompt)" = ""
|})) ["CODEX_HOME"; "MANTLE_CONTEXT"; "_MANTLE_SELECTED_HOME"; "_MANTLE_PREV_STATE"; "_MANTLE_PREV_HOME"];
  check (init ^ {|
mantle work
readonly CODEX_HOME
if mantle private; then exit 93; fi
if mantle off; then exit 94; fi
test "$CODEX_HOME" = "$WORK"
test "$(mantle prompt)" = '(work)'
|});
  let private_config = private_profile / "config.toml" in
  Unix.unlink private_config;
  mkdir private_config;
  check (init ^ {|
mantle work
if mantle private; then exit 95; fi
test "$CODEX_HOME" = "$WORK"
test "$(mantle prompt)" = '(work)'
|});
  Unix.rmdir private_config;
  Unix.symlink config private_config;
  let fails profile = init ^ "if mantle " ^ profile ^ "; then exit 96; fi\ntest \"${CODEX_HOME+x}\" = \"\"" in
  check (fails "private");
  assert (read config = original_config);
  Unix.unlink private_config;
  check (init ^ "mantle private");
  List.iter (fun link ->
    let private_auth = private_profile / "auth.json" in
    link auth private_auth;
    check (fails "private");
    assert (read auth = original_auth);
    Unix.unlink private_auth) [Unix.symlink; Unix.link];
  let redirected = root / (name ^ " redirected") in
  List.iter mkdir [redirected; redirected / ".local"; redirected / ".local/share"];
  Unix.symlink (Filename.dirname profiles) (redirected / ".local/share/mantle");
  check ~extra:["HOME", redirected] (fails "work");
  let blocked = root / (name ^ " blocked") in
  mkdir blocked;
  write (blocked / ".local") "not a directory";
  check ~extra:["HOME", blocked] (fails "work");
  check ~extra:["HOME", "relative"] (fails "work");

  let result = run (init ^ "mantle work\nmantle status") in
  List.iter (fun part -> assert (contains result.output part))
    ["Context: work (selection only)"; "Codex home: " ^ work; "Native login: authenticated"; "not verified"];
  assert (not (contains (result.output ^ result.error) "SECRET"));
  let result = run ~extra:["FAKE_LOGIN_EXIT", "7"] ~expected:7 (init ^ "mantle status") in
  assert (contains result.error "exited 7" && not (contains (result.output ^ result.error) "SECRET"));
  let result = run ~extra:["PATH", "/nonexistent"] ~expected:1 (init ^ "mantle status") in
  assert (contains result.error "not found on PATH");
  check (init ^ "mantle work\nexport CODEX_HOME=/changed\ntest \"$(mantle prompt)\" = \"\"\ntest \"$(\"$BINARY\" prompt)\" = \"\"");

  (* A running Codex keeps its home while the parent shell switches. *)
  let ready = root / (name ^ "-ready") and release = root / (name ^ "-release") and record = root / (name ^ "-record") in
  Fun.protect ~finally:(fun () -> write release "") (fun () ->
    check ~extra:["READY", ready; "RELEASE", release; "RECORD", record] (init ^ {|
mantle client-a_2
codex hold &
agent=$!
while [ ! -e "$READY" ]; do sleep 0.01; done
mantle private
test "$CODEX_HOME" = "$PRIVATE"
: > "$RELEASE"
wait "$agent"
|}));
  assert ((decode (read record)).codex_home = Some custom);
  check (init ^ "test \"${CODEX_HOME+x}\" = \"\"\ntest \"$(mantle prompt)\" = \"\"");

  (* Concurrent first setup includes two shells selecting the same profile. *)
  let concurrent_dir = root / (name ^ " concurrent") in
  mkdir concurrent_dir;
  let release = root / (name ^ "-concurrent-release") in
  let jobs = ref [] in
  Fun.protect ~finally:(fun () -> write release ""; List.iter (fun (child, _, _, _) -> stop child) !jobs) (fun () ->
    List.iteri (fun index profile ->
      let prefix = root / Printf.sprintf "%s-concurrent-%d" name index in
      let ready = prefix ^ "-ready" and record = prefix ^ "-record" in
      let child = spawn ["HOME", concurrent_dir; "READY", ready; "RELEASE", release; "RECORD", record]
        (init ^ "mantle create " ^ profile ^ " >/dev/null\nmantle " ^ profile ^ "\ncodex hold") in
      jobs := (child, ready, record, profile) :: !jobs) ["work"; "private"; "client-a_2"; "client-a_2"];
    wait_until "concurrent shells ready" (fun () -> List.for_all (fun (_, ready, _, _) -> Sys.file_exists ready) !jobs);
    write release "";
    List.iter (fun (child, _, record, profile) ->
      ignore (finish "concurrent shell" child);
      assert ((decode (read record)).codex_home = Some (concurrent_dir / ".local/share/mantle/profiles" / profile / "codex"))) !jobs);

  (* The documented prompt insertion preserves Git text and is idempotent. *)
  let snippet = {|case "$PS1" in
  *'$(mantle prompt)'*) ;;
  *) PS1='$(mantle prompt) '"$PS1" ;;
esac
|} in
  let script = init ^ "PS1='project (main) > '\n" ^ snippet ^ snippet ^ {|
mantle work
test "$PS1" = '$(mantle prompt) project (main) > '
|} in
  check (script ^ if name <> "zsh" then "" else {|
setopt PROMPT_SUBST
COLUMNS=80
test "$(print -P -- "$PS1")" = '(work) project (main) > '
test "$(print -P -- '$(mantle prompt)%(6l.yes.no)')" = '(work)yes'
test "$(print -P -- '$(mantle prompt)%(7l.bad.good)')" = '(work)good'
mantle private
test "$(print -P -- '$(mantle prompt)%(9l.yes.no)')" = '(private)yes'
mantle client-a_2
test "$(print -P -- '$(mantle prompt)%(12l.yes.no)')" = '(client-a_2)yes'
mantle off
test "$(print -P -- "$PS1")" = ' project (main) > '
|});
  if name = "bash" then (
    (* The native script utility supplies a PTY without C bindings or another language. *)
    let platform = finish "uname" (start ~root ~env ~cwd ["/usr/bin/uname"; "-s"]) in
    let command = shell :: flags shell @ ["-i"] in
    let transcript = root / "prompt-transcript" in
    let arguments = if String.trim platform.output = "Darwin" then
        ["/usr/bin/script"; "-q"; "-F"; transcript] @ command
      else ["/usr/bin/script"; "-q"; "-e"; "-f"; "-c"; String.concat " " (List.map quote command); transcript] in
    let input, output = Unix.pipe ~cloexec:true () in
    let writer = Unix.out_channel_of_descr output in
    let child = start ~root ~env:(replace env ["PS1", "READY> "]) ~cwd ~input arguments in
    Fun.protect ~finally:(fun () -> close_out_noerr writer; stop child) (fun () ->
      let prompt expected =
        try wait_until ("Bash PTY prompt " ^ expected)
          (fun () -> Sys.file_exists transcript && String.ends_with ~suffix:expected (read transcript))
        with Failure message ->
          failwith (Printf.sprintf "%s\nstdout: %S\nstderr: %S" message (read child.output_path) (read child.error_path)) in
      let send command = output_string writer (command ^ "\n"); flush writer in
      prompt "READY> ";
      send {|eval "$("$BINARY" init bash)"; shopt -s promptvars; PS1='$(mantle prompt) project (main) > '; mantle work|};
      prompt "(work) project (main) > ";
      send "mantle private";
      prompt "(private) project (main) > ";
      send "mantle client-a_2";
      prompt "(client-a_2) project (main) > ";
      send "mantle off";
      prompt " project (main) > ";
      send "exit";
      ignore (finish "Bash PTY prompt rendering" child)));

  (* Adopt the original work/private layout without moving or rewriting its data. *)
  let legacy = root / (name ^ " legacy home") in
  List.iter mkdir [legacy; legacy / ".local"; legacy / ".local/share"; legacy / ".local/share/mantle";
                  legacy / ".local/share/mantle/profiles"];
  let legacy_profiles = legacy / ".local/share/mantle/profiles" in
  List.iter (fun profile ->
    let home = legacy_profiles / profile / "codex" in
    List.iter mkdir [legacy_profiles / profile; home];
    List.iter (fun file -> write (home / file) ("existing " ^ profile ^ " " ^ file ^ "\n"))
      ["config.toml"; "auth.json"; "history.jsonl"]) ["work"; "private"];
  let extra = ["HOME", legacy; "WORK", legacy_profiles / "work/codex"; "PRIVATE", legacy_profiles / "private/codex"] in
  assert ((run ~extra "\"$BINARY\" list").output = "private\nwork\n");
  check ~extra (init ^ "mantle work\ntest \"$CODEX_HOME\" = \"$WORK\"\nmantle private\ntest \"$CODEX_HOME\" = \"$PRIVATE\"\nmantle create work >/dev/null\nmantle off");
  List.iter (fun profile -> List.iter (fun file ->
    assert (read (legacy_profiles / profile / "codex" / file) = "existing " ^ profile ^ " " ^ file ^ "\n"))
    ["config.toml"; "auth.json"; "history.jsonl"]) ["work"; "private"];
  Printf.printf "%s: public commands, isolation, restoration, quoting, permissions, failures, prompts passed\n%!" name

let check_install root =
  let source = Unix.realpath Sys.argv.(1) in
  let checkout = root / "checkout ' $cash `literal` ; [glob]" in
  let user_dir = root / "installer home" in
  List.iter mkdir [checkout; user_dir];
  List.iter (fun name -> copy (Filename.dirname source / name) (checkout / name))
    ["install"; "mantle.ml"; "dune"; "dune-project"];
  let existing_setup = "PS1='project (main) > '\n" in
  List.iter (fun name -> write (user_dir / name) existing_setup; Unix.chmod (user_dir / name) 0o640) [".bashrc"; ".zshrc"];
  let env = ["HOME", user_dir; "SHELL", "/bin/bash"; "TERM", "dumb"; "DUNE_CACHE", "disabled";
             "DESTDIR", root / "unused staging";
             "PATH", String.concat ":" [Filename.dirname Sys.argv.(2); Filename.dirname Sys.argv.(3); "/usr/bin"; "/bin"]] in
  let run ?(expected = 0) ?(extra = []) ?(answer = "") args =
    let input_path = root / "installer-answer" in
    write input_path answer;
    let input = Unix.openfile input_path [Unix.O_RDONLY] 0 in
    finish ~expected "installer" (start ~root ~env:(replace env extra) ~cwd:root ~input (checkout / "install" :: args)) in
  ignore (run ["--help"]);
  List.iter (fun args -> ignore (run ~expected:2 args)) [["--prefix"]; ["--prefix"; ""]; ["--unknown"]];
  assert (not (Sys.file_exists (checkout / "_build")));
  ignore (run []);
  let default_binary = user_dir / ".local/bin/mantle" in
  Unix.access default_binary [Unix.X_OK];
  let original = read default_binary in
  let prefix = "installed ' $cash `literal` ; [glob]\nline" in
  let binary_dir = root / prefix / "bin" in
  let binary = binary_dir / "mantle" in
  let result = run ["--prefix"; prefix] in
  assert (contains result.output ("Installed: " ^ binary));
  assert (contains result.output ("export PATH=" ^ quote binary_dir ^ ":\"$PATH\""));
  write binary "old CLI";
  ignore (run ["--prefix"; prefix]);
  assert (read binary = original);
  ignore (run ~answer:"n\n" ["--prefix"; prefix]);
  List.iter (fun name -> assert (read (user_dir / name) = existing_setup)) [".bashrc"; ".zshrc"];
  assert (not (Sys.file_exists (user_dir / ".bash_profile")));

  (* Consent adds one replaceable block; Bash works for login and non-login terminals. *)
  List.iter (fun shell ->
    let extra = ["SHELL", shell] in
    let names = if Filename.basename shell = "bash" then [".bashrc"; ".bash_profile"] else [".zshrc"] in
    let files = List.map (Filename.concat user_dir) names in
    ignore (run ~extra ~answer:"YES\n" ["--prefix"; prefix]);
    List.iter (fun file -> write file (read file ^ "# Keep user edits after Mantle too.\n")) files;
    let saved = List.map read files in
    assert (String.starts_with ~prefix:existing_setup (List.hd saved));
    assert ((Unix.stat (List.hd files)).Unix.st_perm = 0o640);
    ignore (run ~extra ~answer:"y\n" ["--prefix"; prefix]);
    assert (List.map read files = saved);
    ignore (run ~extra ~answer:"yes\n" []);
    assert (not (contains (read (List.hd files)) binary_dir));
    ignore (run ~extra ~answer:"yes\n" ["--prefix"; prefix]);
    assert (List.map read files = saved)) shells;
  assert ((Unix.stat (user_dir / ".bash_profile")).Unix.st_perm = 0o600);
  assert (not (Sys.file_exists (user_dir / ".local/share/mantle")));

  let shell_check shell options script =
    finish "installed shell startup" (start ~root ~env:(replace env ["SHELL", shell]) ~cwd:root
      (shell :: options @ ["-i"; "-c"; {|
mantle work
test "$(mantle prompt)" = '(work)' || exit 1
case "$PS1" in
  '$(mantle prompt) '*'$(mantle prompt)'*) exit 2 ;;
  '$(mantle prompt) '*) ;;
  *) exit 3 ;;
esac
|} ^ script ^ "\nmantle off"])) in
  List.iter (fun shell -> ignore (shell_check shell [] {|test "$PS1" = '$(mantle prompt) project (main) > ' || exit 4|})) shells;
  ignore (shell_check "/bin/bash" ["-l"] "");

  (* A malformed existing block aborts before changing any startup file. *)
  let bashrc = user_dir / ".bashrc" and profile = user_dir / ".bash_profile" in
  let saved_rc = read bashrc and saved_profile = read profile in
  write profile (saved_profile ^ "# >>> mantle >>>\n");
  ignore (run ~expected:1 ~answer:"yes\n" []);
  assert (read bashrc = saved_rc && read profile = saved_profile ^ "# >>> mantle >>>\n");
  write profile saved_profile;

  (* Respect existing Bash login profiles, ZDOTDIR, and symlinked dotfiles. *)
  Unix.rename profile (user_dir / ".profile");
  ignore (run ~answer:"yes\n" ["--prefix"; prefix]);
  assert (not (Sys.file_exists profile));
  assert (read (user_dir / ".profile") = saved_profile);
  let zdotdir = root / "zsh config ' $x" in
  mkdir zdotdir;
  let target = root / "linked-zshrc" in
  write target existing_setup;
  Unix.chmod target 0o640;
  Unix.symlink target (zdotdir / ".zshrc");
  let previous_zshrc = read (user_dir / ".zshrc") in
  ignore (run ~extra:["SHELL", "/bin/zsh"; "ZDOTDIR", Filename.basename zdotdir] ~answer:"yes\n" ["--prefix"; prefix]);
  assert ((Unix.lstat (zdotdir / ".zshrc")).Unix.st_kind = Unix.S_LNK);
  assert ((Unix.stat target).Unix.st_perm = 0o640 && contains (read target) "# >>> mantle >>>");
  assert (read (user_dir / ".zshrc") = previous_zshrc);
  ignore (finish "ZDOTDIR startup" (start ~root ~env:(replace env ["ZDOTDIR", zdotdir]) ~cwd:root
    ["/bin/zsh"; "-i"; "-c"; "mantle work && test \"$(mantle prompt)\" = '(work)' && mantle off"]));

  write (checkout / "mantle.ml") "intentionally invalid OCaml\n";
  ignore (run ~expected:1 ~answer:"yes\n" ["--prefix"; prefix]);
  assert (read binary = original && read default_binary = original);
  assert (read bashrc = saved_rc && read (user_dir / ".profile") = saved_profile);
  assert (not (Sys.file_exists (root / "unused staging")));
  (* All shell checks below use this installed CLI after its source checkout is removed. *)
  remove checkout;
  print_endline "installer: prefixes, upgrades, failed builds, consent, idempotent Bash/Zsh startup passed";
  binary_dir, binary

let main () =
  let root = Filename.temp_file "mantle-check-" "" in
  Unix.unlink root;
  mkdir root;
  let root = Unix.realpath root in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let binary_dir, binary = check_install root in
    copy Sys.executable_name (binary_dir / "codex");
    List.iter (check_shell root binary_dir binary) shells;
    print_endline "Integration checks passed (OCaml fake Codex; no authentication isolation claim).")

let () =
  Printexc.record_backtrace true;
  try
    if Filename.basename Sys.argv.(0) = "codex" then fake_codex () else main ()
  with exn ->
    prerr_endline (Printexc.to_string exn);
    prerr_string (Printexc.get_backtrace ());
    exit 1
