let fail message = raise (Failure message)
let getenv name = Option.value (Sys.getenv_opt name) ~default:""
let quote value = "'" ^ String.concat "'\\''" (String.split_on_char '\'' value) ^ "'"
let commands = ["init"; "list"; "create"; "off"; "status"; "prompt"]
let default_profiles = ["private"; "work"]
let valid_profile name =
  String.length name > 0 && String.length name <= 32
  && (match name.[0] with 'a' .. 'z' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true | _ -> false) name
  && not (List.mem name commands)
let usage = {|Usage: mantle init bash|zsh
       mantle list
       mantle create NAME
       mantle NAME
       mantle off
       mantle status
       mantle prompt

Default profiles: private, work. Create another with: mantle create NAME.
Activate shell integration first: eval "$(mantle init bash)" (or zsh).
Switches affect this shell and future children. Login separately with codex login.
The prompt is a context label, not a verified account or workspace identity.
|}

let user_home () =
  let path = getenv "HOME" in
  if path = "" || Filename.is_relative path then fail "HOME must be an absolute directory";
  Unix.realpath path

let rec mkdir_parents path =
  if not (Sys.file_exists path) then (
    mkdir_parents (Filename.dirname path);
    try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let check_path path kind =
  let stat = Unix.lstat path in
  if stat.Unix.st_kind <> kind || stat.Unix.st_uid <> Unix.getuid () then
    fail ("expected an owned, non-symlink " ^ (if kind = Unix.S_DIR then "directory: " else "file: ") ^ path);
  if kind = Unix.S_REG && stat.Unix.st_nlink <> 1 then fail ("refusing a hard-linked file: " ^ path)

let secure path kind mode = check_path path kind; Unix.chmod path mode

let profiles () =
  let root = Filename.concat (user_home ()) ".local/share/mantle/profiles" in
  let existing = try
      check_path (Filename.dirname root) Unix.S_DIR;
      check_path root Unix.S_DIR;
      Array.to_list (Sys.readdir root) |> List.filter (fun name ->
        valid_profile name &&
        try check_path (Filename.concat root name) Unix.S_DIR; true
        with Failure _ | Unix.Unix_error (Unix.ENOENT, _, _) -> false)
    with Unix.Unix_error (Unix.ENOENT, _, _) -> []
  in
  List.sort_uniq String.compare (default_profiles @ existing)

let defaults = {|# Keep file credentials and subscription login for independent Mantle homes.
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"
|}

let setup ~create profile =
  if not (valid_profile profile) then
    fail ("profile names must start with a lowercase letter, contain only a-z, 0-9, - or _, and be at most 32 characters; reserved: "
          ^ String.concat ", " commands);
  let share = Filename.concat (user_home ()) ".local/share" in
  if not create then (
    if not (List.mem profile default_profiles)
       && not (Sys.file_exists (Filename.concat share ("mantle/profiles/" ^ profile))) then
      fail ("unknown profile '" ^ profile ^ "'; create it with: mantle create " ^ profile);
    List.iter (fun name ->
      if getenv name <> "" then fail ("unset " ^ name ^ " before switching; it overrides profile authentication or storage"))
      ["CODEX_ACCESS_TOKEN"; "CODEX_API_KEY"; "OPENAI_API_KEY"; "CODEX_SQLITE_HOME"]);
  mkdir_parents share;
  let path = List.fold_left (fun parent part ->
    let path = Filename.concat parent part in
    (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    secure path Unix.S_DIR 0o700;
    path) share ["mantle"; "profiles"; profile; "codex"] in
  let lock = Filename.concat path ".setup.lock" in
  let descriptor = Unix.openfile lock [Unix.O_CREAT; Unix.O_RDWR] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
    secure lock Unix.S_REG 0o600;
    Unix.lockf descriptor Unix.F_LOCK 0;
    let config = Filename.concat path "config.toml" in
    (* Publish complete defaults; serialize setup so another switch never sees a temporary hard link. *)
    if not (Sys.file_exists config) then (
      let temporary, channel = Filename.open_temp_file ~temp_dir:path ~perms:0o600 ".config-" ".tmp" in
      Fun.protect ~finally:(fun () -> close_out_noerr channel; Unix.unlink temporary) (fun () ->
        output_string channel defaults;
        close_out channel;
        try Unix.link temporary config with Unix.Unix_error (Unix.EEXIST, _, _) -> ()));
    secure config Unix.S_REG 0o600;
    try secure (Filename.concat path "auth.json") Unix.S_REG 0o600
    with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  path

let active_context () =
  let context = getenv "MANTLE_CONTEXT" in
  if valid_profile context
     && List.mem (getenv "_MANTLE_PREV_STATE") ["unset"; "local"; "export"]
     && getenv "_MANTLE_SELECTED_HOME" <> ""
     && getenv "CODEX_HOME" = getenv "_MANTLE_SELECTED_HOME"
  then context else ""

let init shell =
  let executable = quote (Unix.realpath Sys.executable_name) in
  Printf.printf {|_mantle_apply() {
  if [ "$1" = off ]; then
    case "${_MANTLE_PREV_STATE-}" in
      unset) unset CODEX_HOME || return ;;
      export|local)
        export CODEX_HOME="${_MANTLE_PREV_HOME-}" || return
        if [ "$_MANTLE_PREV_STATE" = local ]; then %s CODEX_HOME || return; fi
        ;;
    esac &&
    unset _MANTLE_PREV_STATE _MANTLE_PREV_HOME _MANTLE_SELECTED_HOME MANTLE_CONTEXT
  else
    case "${_MANTLE_PREV_STATE-}" in
      unset|local|export) ;;
      *)
        case "${CODEX_HOME+x}":%s in
          :*) export _MANTLE_PREV_STATE=unset ;;
          x:%s) export _MANTLE_PREV_STATE=export ;;
          *) export _MANTLE_PREV_STATE=local ;;
        esac &&
        export _MANTLE_PREV_HOME="${CODEX_HOME-}" || return
        ;;
    esac &&
    export CODEX_HOME="$2" _MANTLE_SELECTED_HOME="$2" MANTLE_CONTEXT="$1"
  fi
}
mantle() {
  %s
  case "${1-}" in
    ''|%s|-*|_*) %s "$@" ;;
    *)
      local _mantle_home
      _mantle_home=$(%s _home "$@") || return
      # Check readonly variables in a subshell before changing the caller.
      ( _mantle_apply "$1" "$_mantle_home" ) && _mantle_apply "$1" "$_mantle_home"
      ;;
  esac
}
|} (if shell = "zsh" then "typeset -g +x" else "export -n")
    (if shell = "zsh" then "\"${parameters[CODEX_HOME]-}\"" else "\"$(declare -p CODEX_HOME 2>/dev/null)\"")
    (if shell = "zsh" then "*-export*" else "'declare -x '*")
    (if shell = "zsh" then "emulate -L zsh" else ":")
    (String.concat "|" (List.filter (( <> ) "off") commands)) executable executable

let status () =
  let context = active_context () in
  Printf.printf "Context: %s\n" (if context = "" then "inactive" else context ^ " (selection only)");
  let effective = match Sys.getenv_opt "CODEX_HOME" with
    | None | Some "" -> Filename.concat (user_home ()) ".codex"
    | Some path -> if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
  in
  Printf.printf "Codex home: %s\n" effective;
  print_endline "Account/workspace identity: not verified by Mantle";
  flush stdout;
  (* Native output can contain credential details. Report only its exit status. *)
  let sink = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
  Fun.protect ~finally:(fun () -> Unix.close sink) (fun () ->
    let pid = try Unix.create_process "codex" [|"codex"; "login"; "status"|] sink sink sink
      with Unix.Unix_error (Unix.ENOENT, _, _) -> fail "Codex executable not found on PATH"
    in
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED 0 -> print_endline "Native login: authenticated (codex login status succeeded)"
    | Unix.WEXITED code ->
      Printf.eprintf "Native login: unavailable (codex login status exited %d).\nRun codex login status for details, or codex login to sign in.\n" code;
      exit code
    | _ -> fail "codex login status was interrupted")

let main () =
  match Array.to_list Sys.argv |> List.tl with
  | ["init"; ("bash" | "zsh" as shell)] -> init shell
  | ["list"] -> List.iter print_endline (profiles ())
  | ["create"; profile] ->
    ignore (setup ~create:true profile);
    Printf.printf "Profile ready: %s\nSelect with: mantle %s\n" profile profile
  | ["_home"; "off"] -> ()
  | ["_home"; profile] -> print_endline (setup ~create:false profile)
  | ["prompt"] -> let context = active_context () in if context <> "" then Printf.printf "(%s)" context
  | ["status"] -> status ()
  | [] | ["--help"] | ["-h"] -> print_string usage
  | [profile] when profile = "off" || valid_profile profile ->
    fail "shell integration is required; run eval \"$(mantle init bash)\" (or zsh) first"
  | _ -> fail ("invalid invocation\n" ^ usage)

let () =
  try main () with
  | Failure message | Sys_error message -> Printf.eprintf "mantle: %s\n" message; exit 1
  | Unix.Unix_error (error, operation, path) ->
    Printf.eprintf "mantle: %s: %s: %s\n" operation path (Unix.error_message error); exit 1
