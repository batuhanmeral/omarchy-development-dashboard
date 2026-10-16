# Development Ports

A read-only Omarchy bar widget for local TCP listeners, Docker containers, images,
volumes and database discovery. It runs inside the existing Omarchy Quickshell
process with an on-demand Python collector.

Requires Omarchy's Quattro plugin API, Quickshell/Qt 6, Python 3.11+ and `ss`
(iproute2). Docker is optional; access to its socket grants powerful host
privileges even though this widget only reads data. Optional actions use
`wl-copy` and `xdg-open`.

From the repository root, check existing development tools and run validation:

```bash
make setup
make check
omarchy plugin validate ./devports
```

`make setup` checks prerequisites without installing anything. Development checks
also require Make, Ruff, Pyright, Node.js, Gitleaks and Qt's `qmlformat`, `qmllint`
and `qmltestrunner`. Run a collector smoke check without enabling Docker:

```bash
python3 devports/backend/collector.py ports --no-docker
```

For local installation, settings, manual tests and environment limitations, see
[the Turkish setup guide](.docs/kurulum.md). The `.docs/` directory is local and
intentionally excluded from Git; keep it alongside this checkout.

Licensed under [MIT](LICENSE).
