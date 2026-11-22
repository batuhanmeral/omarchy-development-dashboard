# Development Dashboard

*Your development environment, one panel.*

A small panel for the Omarchy bar. Click its icon and you see what is running on your
machine while you work: open ports and the programs behind them, Docker containers,
databases, your projects, and the AI coding assistants you have installed.

![Panel preview](preview.png)

## What it does

- **Ports:** which programs are listening, and whether only you or your whole network can
  reach them.
- **Docker:** your containers, images and volumes; start, stop or restart a container and
  read its logs.
- **Databases:** databases running on your machine.
- **Projects:** your Git projects, their branch and unsaved changes. Open one in a
  terminal, editor or file manager.
- **AI tools:** coding assistants such as Claude Code or Codex, ready to launch inside a
  project.

Everything works from the keyboard: number keys switch sections, `/` searches, `s` opens
settings, `Esc` goes back.

## Requirements

- Omarchy 4.5 or newer. Everything else it needs comes with Omarchy.
- Optional: Docker for the Docker sections, Git for project status, and any AI coding
  assistant you want to launch (Claude Code, Codex, Gemini CLI, OpenCode). The panel
  never installs these for you.

## Install

```bash
omarchy plugin add https://github.com/batuhanmeral/omarchy-development-dashboard.git --enable
```

Click the icon to open the panel, right-click to refresh. If your system language is
Turkish and the install fails, put `LC_ALL=C.UTF-8` in front of the command.

To update or remove it:

```bash
omarchy plugin update io.github.batuhanmeral.development-dashboard
omarchy plugin remove io.github.batuhanmeral.development-dashboard
```

## Development

```bash
make check   # run all tests and checks
```

## License

[MIT](LICENSE)
