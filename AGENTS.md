# AGENTS.md

Hayden's plugins and tweaks for [Tern](https://docs.stencil.so/tern/) (the terminal app). Private repo: `github.com/Unravl/tern-plugins`, branch `main`.

## Commit and push automatically

This is a standing instruction; do not ask for confirmation.

- After every completed change (new plugin, feature, fix, tweak, docs), once it is verified: stage the intended files, commit, and push to `origin main`.
- One commit per logical change. Message: `<plugin-id>: <what changed>` (imperative, e.g. `sessions-sidebar: keep docked width identical across tabs`); repo-wide changes use `repo: …`.
- Never end a session with uncommitted or unpushed work. If a task stops partway, commit what is safe with a message that says what is unfinished, and push.
- If a push is rejected, `git pull --rebase` and push again. Never force-push, rewrite pushed history, or commit secrets, tokens, or generated files (see `.gitignore`).

## Layout

- One folder per plugin, named exactly as its `plugin.toml` `id` (e.g. `sessions-sidebar/`).
- Each plugin keeps its own `README.md` (features, install, limits, verification) and `tests/` scenarios.
- Update the plugin table in the root `README.md` whenever a plugin is added, renamed or removed.
- Bump `version` in `plugin.toml` for every user-visible change and keep the plugin README in step.

## Tern facts

- App and CLI: `/Applications/Tern.app/Contents/MacOS/tern` (Tern 0.7.3 when this repo started). `tern plugin --help` lists `list`, `reload`, `install`, `remove`, `link`, `unlink`, `types`.
- Hayden's Tern **links** plugins straight from this folder (`tern plugin link ~/Documents/tern-plugins/<id>`). Saving a file reloads it in his running Tern immediately, so a broken save breaks his live session: keep edits coherent, and test in an isolated window (below).
- New plugin: create `<id>/plugin.toml` and its entry files, then `tern plugin link ~/Documents/tern-plugins/<id>`; check `tern plugin list` shows it `ready`.
- Reload with the CLI `tern plugin reload`. In Tern 0.7.3 the palette's **Reload plugins** loses existing plugin canvases' state.
- SDK types: `tern plugin types <dir>` writes `<dir>/tern.d.luau` (gitignored). Docs: <https://docs.stencil.so/tern/>; append `.md` to page URLs for plain text.
- Plugins use public SDK APIs only. Window handlers have a 50 ms budget. Never persist window-local ids (pane, tab, session, host slot) in `tern.kv`; key saved data by stable values.

## Testing

- Never drive, inspect or close Hayden's own Tern windows or sessions.
- Isolated instance: make a temp dir `$d`, export `TERN_CONFIG_DIR`, `TERN_DAEMON_SOCKET` and `STENCIL_LOG_DIR` into it and `tern plugin link` the plugin there.
- Start it **hidden in the background** so it never takes focus or covers Hayden's work (never run `tern --control …` directly; that opens a frontmost window):

  ```sh
  open -g -j -n --env TERN_CONFIG_DIR="$d/config" --env TERN_DAEMON_SOCKET="$d/daemon.sock" \
    --env STENCIL_LOG_DIR="$d/logs" -a /Applications/Tern.app --args --control "$d/control.sock" /tmp
  ```

  Wait for `$d/control.sock` to exist before `tern ctl`. The hidden window runs plugins and takes every ctl command (`ready`, `tab new`, `carly lua`, scenarios), but `shot` fails because the app's working directory is `/`; check layout with `tree`, `dump` or `carly lua` instead.
- Drive it with `tern ctl --control <port> '<command>'` (a bare TCP port or a socket path, not `host:port`; pass each command as one argument). `tern help dev` lists the commands; `carly lua "return …"` runs window Lua; `remote loopback <address>` adds a fake remote host. `#` starts a comment in ctl commands, so Luau's length operator silently cuts a `carly lua` line short; count in a loop instead.
- Behavior changes need a native smoke run before committing; run the plugin's `tests/*.txt` scenarios with `tern ctl --control <port> --file <scenario>`.
- Afterwards stop it: `tern ctl --control "$d/control.sock" quit` closes the window but leaves an `open`-launched app running, so then `pkill -f "$d/control.sock"`, `pkill -f "tern daemon --socket $d/daemon.sock"` (app first, or it restarts the daemon) and delete the temp dir. `tern serve` is no substitute: its ephemeral session does not load linked plugins.

## Sharing a plugin

- People with access to the repo: `tern plugin install github.com/Unravl/tern-plugins/<id>` (`--force` to update).
- Anyone else: zip the plugin folder; they unzip it and run `tern plugin install <path-to-folder>`.
