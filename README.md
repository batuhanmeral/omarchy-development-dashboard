# Development Dashboard

*Your development environment, one panel.*

An Omarchy bar widget for the things you run while you develop: listening TCP ports and
the processes behind them, Docker containers, images and volumes, databases, your Git
projects, and the AI coding assistants installed on your machine. It is a single bar icon
and a keyboard-driven popup; there is no separate window, daemon or background service.

Nothing changes unless you ask. Starting, stopping or restarting containers and stopping
your own development processes are **management actions**: each one starts only when you
trigger it, and stopping or restarting asks for confirmation first. They are available by
default; turn **Management actions** off in settings for a strictly read-only panel.

![Panel preview](preview.png)

## Install

```bash
omarchy plugin add https://github.com/batuhanmeral/omarchy-development-dashboard.git --enable
```

Omarchy clones the repository into
`~/.config/omarchy/plugins/io.github.batuhanmeral.development-dashboard` and asks where to
place the widget (default: right side of the bar). Click the icon to open the panel,
right-click to refresh.

Under a Turkish (or similar) locale, Omarchy's validator rejects every plugin id; run the
command as `LC_ALL=C.UTF-8 omarchy plugin add ...`.

Update: `omarchy plugin update io.github.batuhanmeral.development-dashboard`
Remove: `omarchy plugin remove io.github.batuhanmeral.development-dashboard`

Removing the plugin deletes only its own folder. Its settings entry in
`~/.config/omarchy/shell.json` is left in place, as with any Omarchy widget.

To toggle the panel from a custom key binding, use
`omarchy-shell io.github.batuhanmeral.development-dashboard toggle`.

### Requirements

| | Required | Used for |
| --- | --- | --- |
| Omarchy 4.5+ (Quickshell, Qt 6) | yes | the widget itself |
| Python 3.11+, `ss` (iproute2) | yes | port and process inventory (present on Omarchy) |
| Docker CLI + local Unix socket | optional | Docker sections and container actions |
| `git` | optional | branch and working-tree status of projects |
| `wl-copy`, `xdg-open` | optional | copying, opening URLs and folders |
| `xdg-terminal-exec` or alacritty, foot, ghostty, kitty | optional | opening projects and AI tools in a terminal |
| Claude Code, OpenAI Codex CLI, Gemini CLI, OpenCode | optional | AI Tools section; never installed by the plugin |

No Python or JavaScript packages are installed.

## Sections

| Key | Section | What it shows |
| --- | --- | --- |
| `1` | Ports | Listening TCP ports, exposure (local / LAN / all interfaces), process, PID, owner, command |
| `2` | Docker | Containers (running and stopped), health, CPU/memory, published and exposed ports, logs |
| `3` | Images | Images and volumes, and whether they are in use |
| `4` | DBs | Databases found by process or image name, plus SQLite files you list |
| `5` | Projects | Git repositories inside the folders you register: branch, ahead/behind, changes, related services |
| `6` | AI | Detected AI coding CLIs; launch one in a terminal inside a selected project |

## Keyboard

| Key | Action |
| --- | --- |
| `↑` `↓` / `j` `k` | Move through the list |
| `←` `→` / `h` `l` | Switch section; in details `→` opens container logs, `←` goes back |
| `Enter` | Open details (in AI Tools: launch the selected tool) |
| `Esc` | Back, clear the search, then close |
| `/` | Search |
| `1`–`6` | Jump to a section |
| `r` | Refresh now |
| `s` | Settings |
| `c` | Copy the URL, address, name or project path |
| `o` | Open a known web service in the browser |
| `t` / `e` / `f` | Project: open in terminal / editor / file manager |
| `a` | Project: pick an AI tool for this project |
| `u` | Container: start\* |
| `x` / `Delete` | Container: stop\*; port: stop the process\* |
| `R` | Container: restart\* |
| `y` | Confirm in a confirmation dialog (it opens with **Cancel** selected) |

\* Management action: hidden when **Management actions** is turned off in settings.

## Settings

Settings are stored in the widget's entry in `~/.config/omarchy/shell.json` and change only
when you press **Save**.

| Setting | Default | Notes |
| --- | --- | --- |
| Docker | on | Read Docker containers, images and volumes |
| Management actions | on | Container start/stop/restart and stopping your own processes; turn off for read-only |
| Refresh interval | 5 s | While the panel is open; 2–120 s |
| Show ports | all | Filter by exposure |
| Hidden ports | empty | Exclude selected port numbers |
| Sort | port | Sort by port, name or state |
| Compact rows | on | Use denser list rows |
| Visible tabs | all | Choose which sections appear in the panel |
| SQLite files | empty | Absolute paths; contents are never read |
| Project folders | empty | Absolute paths, one per line, at most 16. Nothing is scanned until you add one |
| Scan depth | 3 | 1–4 folder levels below each project folder |
| Terminal | default | `xdg-terminal-exec` (Omarchy's default terminal), alacritty, foot, ghostty or kitty |
| Editor | Omarchy default | Empty uses `omarchy-launch-editor`; otherwise a program and fixed arguments, e.g. `code --new-window` |
| Custom AI tools | empty | Up to 8 lines: `Name \| executable \| arguments`, e.g. `Aider \| aider \| --no-auto-commits` |

## Security and privacy

- **Monitoring and changes are separate.** Monitoring code (`backend/collector.py`) never
  changes anything. State-changing and launch operations live in `backend/actions.py`. Each
  one is a named operation with validated arguments, started only by you; stop, restart and
  process termination ask for confirmation (the dialog opens on **Cancel**). Turn
  **Management actions** off to hide them entirely.
- **No shell.** Every command is run with a fixed argument list (`shell=False`), a timeout
  and an output limit. Settings, names and paths are never pasted into a command string,
  and there are no command templates.
- **Docker socket access is root-equivalent.** If your user can reach the Docker socket,
  anything you run, this plugin included, can control the host through it. The plugin
  only talks to a **local Unix socket**; remote contexts (`tcp://`, `ssh://`) are refused.
  Its only Docker changes are start, stop (10 s grace period) and restart of a container
  you pick. It never removes containers, images, volumes or networks.
- **Stopping a process** works only for a process that belongs to you (not root), is
  still listening on the port you selected, is not a known session or system process
  (shell, compositor, D-Bus, PipeWire, Docker daemon and others), and is not the panel
  itself. The kernel process handle (`pidfd`) and the process start time are checked
  just before signalling, so a reused PID cannot be hit. Only `SIGTERM` is sent; there is
  no automatic `SIGKILL`.
- **Projects.** Only folders you register are scanned, with a depth limit, without
  following symlinks, and skipping hidden and dependency folders. Project files are never
  modified or deleted. Git status runs with optional locks and fsmonitor disabled, and
  against a private Git directory, so it never loads the repository's own config
  (only validated status settings such as `core.fileMode` are copied) or
  `info/attributes`. Repositories whose config defines filters or includes are skipped
  because their status would be inaccurate. Even so,
  `git status` is not safe on untrusted repositories, the same as in a shell prompt. Do
  not register folders that contain repositories you do not trust.
- **AI tools** are detected, never installed, and start only when you launch one. The
  plugin sends nothing to them and stores no tokens; each CLI handles its own sign-in
  in the terminal it opens. Executables must be regular files owned by you or root and
  not writable by others.
- **Logs and command lines.** Container logs are fetched only when you open them and are
  never written to disk. Process command lines are shown with password-, token- and
  key-like arguments masked. Masking is best effort, so treat the details view as
  sensitive.

## Development

```bash
make setup   # checks that the tools exist; installs nothing
make check   # Ruff, Pyright, Python/Node/QML tests, qmllint, manifest validation, coverage, Gitleaks
make fix     # apply Ruff and qmlformat formatting
```

To try a change in the running shell, copy the working tree over the installed plugin
directory and run `omarchy restart shell`.

See [the local `.docs/` directory](.docs/) for more development notes in Turkish.

## License

[MIT](LICENSE)
