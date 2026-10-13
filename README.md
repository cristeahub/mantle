# mantle

![Mantle: one core, many states](assets/mantle.png)

Switch between named Codex and Claude Code profiles in Bash or Zsh, then keep running ordinary `codex` or `claude`.
Each selection switches both tools together.
`work` and `private` are the default profiles; you can create more.

```text
~/project (main) (work) ❯ codex
~/project (main) (private) ❯ claude
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
Installation does not create profiles.

Ensure `~/.local/bin` and the native CLI you use (`codex`, `claude`, or both) are on `PATH`.
Neither native CLI is required to create or select a profile.
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

## Profiles and login

```sh
mantle list                   # List all profile names, alphabetically.
mantle create client-a        # Create a profile without switching this shell.
mantle client-a               # Select it just like work or private.
codex login                   # Log into this profile's Codex account once.
claude auth login --claudeai   # Log into its Claude subscription account once.
codex                         # Run whichever tool you use.
claude
mantle off
```

Every profile uses `~/.local/share/mantle/profiles/NAME/codex/` for its Codex home and `~/.local/share/mantle/profiles/NAME/claude/` for its Claude configuration directory.
The profile directories are the profile store; there is no separate registry to migrate or synchronize.
`mantle list` always includes `private` and `work`, even before their first use, and does not create or change files.
Default homes are initialized when selected or explicitly created.
Selecting an unknown name reports an error; use `mantle create NAME` first.
Creating an existing profile again preserves its configuration, credentials, and history.

Names must start with a lowercase letter, use only `a-z`, `0-9`, `-`, or `_`, and contain at most 32 characters.
The command names `init`, `list`, `create`, `off`, `status`, and `prompt` are reserved.

Existing `work` and `private` profiles are recognized in place, preserving their current homes, logins, configuration, and history.
After upgrading, open a new terminal or reload shell integration with `eval "$(mantle init bash)"` or `eval "$(mantle init zsh)"`, then select a profile again to activate both tools.
Reloading an active Codex-only shell preserves its original Codex restoration snapshot; Claude's snapshot starts when you next select a profile.
Existing Claude state outside Mantle is not copied or migrated; log into each new Claude profile separately.

| Command | Selected `CODEX_HOME` | Selected `CLAUDE_CONFIG_DIR` |
| --- | --- | --- |
| `mantle work` | `~/.local/share/mantle/profiles/work/codex/` | `~/.local/share/mantle/profiles/work/claude/` |
| `mantle private` | `~/.local/share/mantle/profiles/private/codex/` | `~/.local/share/mantle/profiles/private/claude/` |

Log in once per context:

```sh
mantle work
codex login                    # Select your work account and correct Business workspace.
claude auth login --claudeai    # Select your work Claude account and organization.
mantle status
codex
claude

mantle private
codex login                    # Select your personal account and workspace.
claude auth login --claudeai    # Select your personal Claude account.
mantle status
codex
claude

mantle off
```

Each shell and its future children keep their own selection; already-running agents retain their original environment.
A fresh independent shell keeps its existing environment until activated.
Child shells inherit both the selection and the original restoration snapshot, including across Bash and Zsh.
`mantle off` restores the original value and export state of both `CODEX_HOME` and `CLAUDE_CONFIG_DIR`, including empty or unset values, and clears the prompt segment.
Repeated switches preserve that original snapshot.

Invalid commands, readonly variables, and setup failures leave the previous shell environment intact.
Failed setup may leave private directories behind.
Calling the executable directly to switch contexts reports that shell integration is required.
Mantle's `_MANTLE_*`, `MANTLE_CONTEXT`, and `_mantle_*` names are reserved.

Fresh Codex homes use native `config.toml`:

```toml
cli_auth_credentials_store = "file"
forced_login_method = "chatgpt"
```

Profile directories are mode `0700`; configuration and existing credentials are secured to `0600`.
Setup rejects symlinks and hard-linked files, serializes concurrent initialization, and preserves existing configuration and credential contents.
Fresh Claude directories use native `settings.json`:

```json
{
  "forceLoginMethod": "claudeai"
}
```

This guides subscription login and disables keyless Console sign-in for that directory.
The terminal's interactive login screen only preselects the method; it does not enforce it.
Use `claude auth login --claudeai` and check native `/status` to confirm your account and organization.
A `forceLoginOrgUUID` in user settings only preselects an organization; enforcing it requires managed settings.
See Claude's [login settings](https://code.claude.com/docs/en/settings-reference#forceloginmethod).

Mantle never reads or copies tokens; native [Codex](https://learn.chatgpt.com/docs/auth) and [Claude Code](https://code.claude.com/docs/en/authentication) handle login and refresh.
Claude uses directory-specific macOS Keychain entries, with a private `.credentials.json` fallback when Keychain writes fail; on Linux, credentials live in the selected directory's `.credentials.json`.
Mantle secures existing Claude `settings.json`, `.claude.json`, and `.credentials.json` files to `0600` without reading their contents.

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
`mantle prompt` reads only environment variables and prints `(NAME)` for the selected profile, or nothing when inactive, without a newline.
It returns nothing after deactivation or when either tool's shell home variable no longer matches the selection.
Labels occupy the profile name's length plus two columns, such as six for `(work)` and nine for `(private)`; do not enclose visible text in Bash's `\[...\]` or Zsh's `%{...%}` nonprinting markers.
Color belongs in your existing prompt styling.

## Status and boundaries

`mantle status` reports the selection, both shell-selected homes, and the results of native `codex login status` and `claude auth status`.
It checks both CLIs independently and suppresses their output to avoid exposing credential details.
A missing CLI is reported as not installed and is skipped if the other is available.
Status fails when neither is available, or when any installed CLI's login check fails or is interrupted; it returns the first failed check's exit code.
An installed Claude CLI that has not been logged into the selected profile therefore makes status fail even if Codex is authenticated.
Run `codex login status` or `claude auth status` yourself for native diagnostics.
Success does not verify a particular identity, subscription login method, or freshly authenticate over the network.

Activation rejects nonempty `CODEX_ACCESS_TOKEN`, `CODEX_API_KEY`, `OPENAI_API_KEY`, or `CODEX_SQLITE_HOME`; unset these overrides yourself before switching.
Mantle does not print or remove their values.
See Codex's [environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables).
Claude activation also rejects nonempty `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_PROFILE`, `ANTHROPIC_FEDERATION_RULE_ID`, `ANTHROPIC_ORGANIZATION_ID`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_ANTHROPIC_AWS`, and `CLAUDE_CODE_USE_MANTLE`.
Unset these overrides yourself; Mantle never prints or removes their values, and `mantle off` still restores the homes when an override is present.
See Claude's [authentication precedence](https://code.claude.com/docs/en/authentication#authentication-precedence) and [environment variables](https://code.claude.com/docs/en/env-vars).

Claude support targets claude.ai subscription accounts (Pro, Max, Team, or Enterprise).
Keyless Claude Console sign-ins use shared Anthropic profile storage outside `CLAUDE_CONFIG_DIR` and are not isolated by Mantle.
Separate homes isolate home-local authentication, configuration, and history.
Repository/system configuration, managed policies, and skills outside the selected homes can still be shared.
Settings such as Claude's `apiKeyHelper` or `env` can override authentication or routing after Mantle checks the shell environment.
Explicit shared remote servers, external storage paths such as `sqlite_home`, or a changed credential store can defeat separation.
Mantle preserves existing configuration and explicit native CLI arguments; see Codex's [configuration layers and state locations](https://learn.chatgpt.com/docs/config-file/config-advanced) and Claude's [settings scopes](https://code.claude.com/docs/en/settings).
This integration applies to shell-launched CLIs and their children; separately launched GUI apps do not inherit that shell's selection.

## Validate

```sh
dune build @install
dune runtest
```

The installer, integration runner, and fake Codex/Claude CLIs are OCaml, using temporary homes and both shells.
The native `script` utility supplies the Bash terminal test.
Checks cover installation/upgrades (including active Codex-only shells), consent and repeated shell setup, profile listing/creation and existing-profile adoption, failed builds, both CLIs' arguments/cwd, concurrent shells, running and inherited children, independent restoration of both variables, quoting, permissions, rejected links/overrides, status failures and missing CLIs, and prompt rendering/width.

On 2026-09-08, installed `codex-cli 0.153.4` on macOS connected ordinary interactive invocations to separate temporary home-local control sockets.
The native daemon diagnostic hit the Unix socket length limit (104 bytes for the requested private-home socket under `/Users/christoffer`), while ordinary startup with an even longer home reached ChatGPT login.
Recheck this native behavior after Codex upgrades.
On 2026-10-13, native Claude Code 2.1.296 probes in temporary profiles confirmed that `claude auth status` reports each profile's `configDirectory` and creates separate `.claude.json` files inside those directories.
These unauthenticated probes and fake-process tests do not prove live account isolation.

Complete the real-account smoke test yourself:

1. Initialize two independent terminals and log into work and private separately for each CLI you use, checking browser accounts, the correct work Business workspace, and Claude organization.
2. Start ordinary `codex` or `claude` in both from the same disposable project and inspect native `/status`.
   Confirm Codex workspace selection in the login UI or with the optional known workspace restriction if it is not shown.
3. Give each agent a different harmless message, leave both running, and switch a third shell between contexts.
   Verify that neither running agent changes account or workspace.
4. Exit and reopen each context, then check that its history picker contains its own conversation.
   Do not share authentication files.
5. For Claude, log out in one profile with `claude auth logout`, verify the other profile still works, then log in again and verify subsequent native credential refresh.
   If you use Claude background agents, confirm each profile's `claude agents` view contains only its own sessions.
6. Run `mantle off` and check both restored variables and the cleared segment.

Real subscription identity, workspace/organization isolation, independent native histories, logout/refresh behavior, background-agent isolation, and native Linux behavior remain user-run acceptance checks.
