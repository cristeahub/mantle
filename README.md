# mantle

![Mantle: one core, many states](assets/mantle.png)

Switch between work and private Codex homes in Bash or Zsh, then keep running ordinary `codex`.

```text
~/project (main) (work) ❯ codex
~/project (main) (private) ❯ codex
```

The label identifies the selected context, not a verified account or workspace.

## Install and activate

Requires OCaml 4.14+, Dune 3.0+, and macOS or Linux.
Dependencies are declared in `dune-project`; there are no generated opam files or third-party libraries.

```sh
./install
# Or choose a different prefix:
./install --prefix /path/to/prefix
```

The installer is an OCaml script, following Monty's default `~/.local` prefix and Dune build flow.
It uses `dune install` to install the standalone executable at `PREFIX/bin/mantle` and prints shell setup instructions.
Run it again to upgrade; a failed build leaves the installed CLI untouched.
The installed CLI works independently of this checkout.
After installation, it detects Bash or Zsh from `$SHELL` and asks before adding PATH, shell integration, and the prompt segment to your startup files.
Only `y` or `yes` agrees; Enter, EOF, and other answers leave those files untouched.
For another shell, run `SHELL=/bin/bash ./install` or `SHELL=/bin/zsh ./install`.
Zsh setup uses `$ZDOTDIR/.zshrc` when `ZDOTDIR` is exported and nonempty, otherwise `~/.zshrc`.
Bash setup uses `~/.bashrc` and the first existing login file (`~/.bash_profile`, `~/.bash_login`, or `~/.profile`), creating `~/.bash_profile` if none exists.
Setup preserves existing content, permissions, and dotfile symlinks; repeated installs update a single marked block.
Open a new terminal after accepting setup.
Installation does not create Codex profiles.

Ensure `~/.local/bin` and your usual Codex executable are on `PATH`.
If you skip automatic setup, run the appropriate integration below and add it to your own shell startup file if desired.
For manual Bash setup, ensure your login startup file sources `~/.bashrc`.

Bash (`~/.bashrc`):

```bash
eval "$(mantle init bash)"
shopt -s promptvars
```

Zsh (`~/.zshrc`):

```zsh
eval "$(mantle init zsh)"
setopt PROMPT_SUBST
```

To try without installing, run `dune build`, then use `./_build/default/mantle.exe init bash` (or `zsh`) from this repository.
Integration pins the absolute executable path, so install before saving it in a startup file.
Initialization defines shell functions without selecting a context or changing `PS1`; repeated initialization does not stack wrappers.

## Select and log in

| Command          | Selected `CODEX_HOME`                           |
| ---------------- | ----------------------------------------------- |
| `mantle work`    | `~/.local/share/mantle/profiles/work/codex/`    |
| `mantle private` | `~/.local/share/mantle/profiles/private/codex/` |

Log in once per context:

```sh
mantle work
codex login       # Select your work account and correct Business workspace.
mantle status
codex

mantle private
codex login       # Select your personal account and workspace.
mantle status
codex

mantle off
```

Each shell and its future children keep their own selection; already-running agents retain their original environment.
A fresh independent shell keeps its existing environment until activated.
Child shells inherit both the selection and the original restoration snapshot, including across Bash and Zsh.
`mantle off` restores the original value and export state of `CODEX_HOME`, including empty or unset values, and clears the prompt segment.
Repeated switches preserve that original snapshot.

Invalid commands, readonly variables, and setup failures leave the previous shell environment intact.
Failed setup may leave private directories behind.
Calling the executable directly to switch contexts reports that shell integration is required.
Mantle's `_MANTLE_*`, `MANTLE_CONTEXT`, and `_mantle_*` names are reserved.

Fresh profiles use native configuration:

```toml
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"
```

Profile directories are mode `0700`; configuration and existing credentials are secured to `0600`.
Setup rejects symlinks and hard-linked files, serializes concurrent initialization, and preserves existing configuration and credential contents.
Mantle never reads or copies tokens; [native Codex handles login and refresh](https://learn.chatgpt.com/docs/auth).

For a known work workspace, optionally add `forced_chatgpt_workspace_id = "YOUR_ACTUAL_WORK_WORKSPACE_ID"` at the top level of the work profile's `config.toml`.
Mantle cannot infer that ID, and managed restrictions still apply.
Keep the file credential store and ChatGPT login settings for independent subscription profiles; Codex diagnoses invalid configuration.
See the [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

## Prompt

Insert the literal `$(mantle prompt)` into your existing single-quoted `PS1` assignment, for example between the Git expression and `❯`.
Keep existing path, Git, and styling expressions.
Alternatively, this snippet prepends the segment to your current prompt and is safe to source repeatedly:

```sh
case "$PS1" in
  *'$(mantle prompt)'*) ;;
  *) PS1='$(mantle prompt) '"$PS1" ;;
esac
```

For themes that rebuild `PS1`, insert the expression in the theme's prompt definition.
`mantle prompt` reads only environment variables and prints exactly `(work)`, `(private)`, or nothing, without a newline.
It returns nothing after deactivation or when the effective home no longer matches the selection.
The labels occupy six and nine columns respectively; do not enclose visible text in Bash's `\[...\]` or Zsh's `%{...%}` nonprinting markers.
Color belongs in your existing prompt styling.

## Status and boundaries

`mantle status` reports the selection, effective home, and result of native `codex login status`.
It suppresses native output to avoid exposing credential details, and returns an error for missing Codex or a failed/interrupted login check.
Run `codex login status` yourself for native diagnostics.
Success does not verify a particular identity or freshly authenticate over the network.

Activation rejects nonempty `CODEX_ACCESS_TOKEN`, `CODEX_API_KEY`, `OPENAI_API_KEY`, or `CODEX_SQLITE_HOME`; unset these overrides yourself before switching.
Mantle does not print or remove their values.
See Codex's [environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables).

Separate homes isolate home-local authentication, configuration, and history.
Repository/system configuration, managed policies, and skills outside `CODEX_HOME` can still be shared.
Explicit shared remote servers, external storage paths such as `sqlite_home`, or a changed credential store can defeat separation.
Mantle preserves existing configuration and explicit Codex arguments; see [configuration layers and state locations](https://learn.chatgpt.com/docs/config-file/config-advanced).

## Validate

```sh
dune build @install
dune runtest
```

The installer, integration runner, and fake Codex are OCaml, using temporary homes and both shells.
The native `script` utility supplies the Bash terminal test.
Checks cover installation/upgrades, consent and repeated shell setup, failed builds, arguments/cwd, concurrent shells, running and inherited children, restoration, quoting, permissions, failures, and prompt rendering/width.

On 2026-09-08, installed `codex-cli 0.153.4` on macOS connected ordinary interactive invocations to separate temporary home-local control sockets.
The native daemon diagnostic hit the Unix socket length limit (104 bytes for the requested private-home socket under `/Users/christoffer`), while ordinary startup with an even longer home reached ChatGPT login.
Recheck this native behavior after Codex upgrades.
These unauthenticated probes and fake-process tests do not prove live account isolation.

Complete the real-account smoke test yourself:

1. Initialize two independent terminals and log into work and private separately, checking the browser account and the correct work Business workspace.
2. Start ordinary `codex` in both from the same disposable project and inspect native `/status`.
   Confirm workspace selection in the login UI or with the optional known workspace restriction if it is not shown.
3. Give each agent a different harmless message, leave both running, and switch a third shell between contexts.
   Verify that neither running agent changes account or workspace.
4. Exit and reopen each context, then check that its history picker contains its own conversation.
   Do not share authentication files.
5. Run `mantle off` and check the restored environment and cleared segment.

Real subscription identity, workspace isolation, independent native histories, and subsequent native credential refresh remain user-run acceptance checks.
