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
Switches affect this shell and future children.
Login separately with codex login or claude auth login --claudeai.
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

let claude_defaults = {|{
  "forceLoginMethod": "claudeai"
}
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
      ["CODEX_ACCESS_TOKEN"; "CODEX_API_KEY"; "OPENAI_API_KEY"; "CODEX_SQLITE_HOME";
       "ANTHROPIC_API_KEY"; "ANTHROPIC_AUTH_TOKEN"; "ANTHROPIC_BASE_URL"; "ANTHROPIC_PROFILE";
       "ANTHROPIC_FEDERATION_RULE_ID"; "ANTHROPIC_ORGANIZATION_ID";
       "CLAUDE_CODE_OAUTH_TOKEN"; "CLAUDE_CODE_OAUTH_REFRESH_TOKEN";
       "CLAUDE_CODE_USE_BEDROCK"; "CLAUDE_CODE_USE_VERTEX"; "CLAUDE_CODE_USE_FOUNDRY";
       "CLAUDE_CODE_USE_ANTHROPIC_AWS"; "CLAUDE_CODE_USE_MANTLE"]);
  mkdir_parents share;
  let path = List.fold_left (fun parent part ->
    let path = Filename.concat parent part in
    (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    secure path Unix.S_DIR 0o700;
    path) share ["mantle"; "profiles"; profile] in
  List.iter (fun (directory, config_name, contents, credentials) ->
    let path = Filename.concat path directory in
    (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    secure path Unix.S_DIR 0o700;
    let lock = Filename.concat path ".setup.lock" in
    let descriptor = Unix.openfile lock [Unix.O_CREAT; Unix.O_RDWR] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      secure lock Unix.S_REG 0o600;
      Unix.lockf descriptor Unix.F_LOCK 0;
      let config = Filename.concat path config_name in
      (* Publish complete defaults; serialize setup so another switch never sees a temporary hard link. *)
      if not (Sys.file_exists config) then (
        let temporary, channel = Filename.open_temp_file ~temp_dir:path ~perms:0o600 ".config-" ".tmp" in
        Fun.protect ~finally:(fun () -> close_out_noerr channel; Unix.unlink temporary) (fun () ->
          output_string channel contents;
          close_out channel;
          try Unix.link temporary config with Unix.Unix_error (Unix.EEXIST, _, _) -> ()));
      secure config Unix.S_REG 0o600;
      List.iter (fun name ->
        try secure (Filename.concat path name) Unix.S_REG 0o600
        with Unix.Unix_error (Unix.ENOENT, _, _) -> ()) credentials))
    ["codex", "config.toml", defaults, ["auth.json"];
     "claude", "settings.json", claude_defaults, [".claude.json"; ".credentials.json"]];
  Filename.concat path "codex"

let active_context () =
  let context = getenv "MANTLE_CONTEXT" in
  if valid_profile context
     && List.mem (getenv "_MANTLE_PREV_STATE") ["unset"; "local"; "export"]
     && getenv "_MANTLE_SELECTED_HOME" <> ""
     && getenv "CODEX_HOME" = getenv "_MANTLE_SELECTED_HOME"
     && List.mem (getenv "_MANTLE_PREV_CLAUDE_STATE") ["unset"; "local"; "export"]
     && getenv "_MANTLE_SELECTED_CLAUDE_HOME" <> ""
     && getenv "CLAUDE_CONFIG_DIR" = getenv "_MANTLE_SELECTED_CLAUDE_HOME"
  then context else ""

let init shell =
  let executable = quote (Unix.realpath Sys.executable_name) in
  let unexport = if shell = "zsh" then "typeset -g +x" else "export -n" in
  let export_state name =
    if shell = "zsh" then "\"${parameters[" ^ name ^ "]-}\""
    else "\"$(declare -p " ^ name ^ " 2>/dev/null)\"" in
  let exported = if shell = "zsh" then "*-export*" else "'declare -x '*" in
  Printf.printf {|_mantle_apply() {
  if [ "$1" = off ]; then
    case "${_MANTLE_PREV_STATE-}" in
      unset) unset CODEX_HOME || return ;;
      export|local)
        export CODEX_HOME="${_MANTLE_PREV_HOME-}" || return
        if [ "$_MANTLE_PREV_STATE" = local ]; then %s CODEX_HOME || return; fi
        ;;
    esac &&
    case "${_MANTLE_PREV_CLAUDE_STATE-}" in
      unset) unset CLAUDE_CONFIG_DIR || return ;;
      export|local)
        export CLAUDE_CONFIG_DIR="${_MANTLE_PREV_CLAUDE_HOME-}" || return
        if [ "$_MANTLE_PREV_CLAUDE_STATE" = local ]; then %s CLAUDE_CONFIG_DIR || return; fi
        ;;
    esac &&
    unset _MANTLE_PREV_STATE _MANTLE_PREV_HOME _MANTLE_SELECTED_HOME \
      _MANTLE_PREV_CLAUDE_STATE _MANTLE_PREV_CLAUDE_HOME _MANTLE_SELECTED_CLAUDE_HOME MANTLE_CONTEXT
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
    case "${_MANTLE_PREV_CLAUDE_STATE-}" in
      unset|local|export) ;;
      *)
        case "${CLAUDE_CONFIG_DIR+x}":%s in
          :*) export _MANTLE_PREV_CLAUDE_STATE=unset ;;
          x:%s) export _MANTLE_PREV_CLAUDE_STATE=export ;;
          *) export _MANTLE_PREV_CLAUDE_STATE=local ;;
        esac &&
        export _MANTLE_PREV_CLAUDE_HOME="${CLAUDE_CONFIG_DIR-}" || return
        ;;
    esac &&
    export CODEX_HOME="$2" _MANTLE_SELECTED_HOME="$2" \
      CLAUDE_CONFIG_DIR="${2%%/codex}/claude" _MANTLE_SELECTED_CLAUDE_HOME="${2%%/codex}/claude" MANTLE_CONTEXT="$1"
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
|} unexport unexport (export_state "CODEX_HOME") exported
    (export_state "CLAUDE_CONFIG_DIR") exported
    (if shell = "zsh" then "emulate -L zsh" else ":")
    (String.concat "|" (List.filter (( <> ) "off") commands)) executable executable

let status () =
  let context = active_context () in
  Printf.printf "Context: %s\n" (if context = "" then "inactive" else context ^ " (selection only)");
  print_endline "Account/workspace identity: not verified by Mantle";
  let checked = ref false and failure = ref 0 in
  let record_failure code = if !failure = 0 then failure := code in
  (* Native output can contain credential details. Report only its exit status. *)
  let sink = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
  Fun.protect ~finally:(fun () -> Unix.close sink) (fun () ->
    List.iter (fun (label, variable, default, arguments, login) ->
      let effective = match Sys.getenv_opt variable with
        | None | Some "" -> Filename.concat (user_home ()) default
        | Some path -> if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
      in
      Printf.printf "%s home: %s\n" label effective;
      flush stdout;
      let command = String.concat " " (Array.to_list arguments) in
      try
        let pid = Unix.create_process arguments.(0) arguments sink sink sink in
        checked := true;
        match snd (Unix.waitpid [] pid) with
        | Unix.WEXITED 0 -> Printf.printf "%s native login: authenticated (%s succeeded)\n" label command
        | Unix.WEXITED code ->
          Printf.eprintf "%s native login: unavailable (%s exited %d).\nRun %s for details, or %s to sign in.\n"
            label command code command login;
          record_failure code
        | _ ->
          Printf.eprintf "%s native login: unavailable (%s was interrupted).\n" label command;
          record_failure 1
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Printf.printf "%s native login: not installed (not found on PATH)\n" label
      | Unix.Unix_error (error, _, _) ->
        Printf.eprintf "%s native login: unavailable (%s).\n" label (Unix.error_message error);
        record_failure 1)
      ["Codex", "CODEX_HOME", ".codex", [|"codex"; "login"; "status"|], "codex login";
       "Claude", "CLAUDE_CONFIG_DIR", ".claude", [|"claude"; "auth"; "status"|], "claude auth login --claudeai"]);
  if !failure <> 0 then exit !failure;
  if not !checked then fail "no supported CLI found on PATH (codex or claude)"

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
