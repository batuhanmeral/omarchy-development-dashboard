PYTHON ?= python3
QML_BIN ?= /usr/lib/qt6/bin
OMARCHY_PATH ?= /usr/share/omarchy
export QML_BIN OMARCHY_PATH
export PYTHONDONTWRITEBYTECODE = 1
# omarchy-plugin-validate rejects every id under locales such as tr_TR, where "i" is outside [a-z].
export LC_ALL = C.UTF-8

.PHONY: setup check check-fast fix test qml-check semgrep
setup:
	@$(PYTHON) tools/check.py prerequisites

check-fast:
	ruff format --check .
	ruff check .
	pyright
	$(PYTHON) -m unittest discover -s tests -v
	node --test tests/model.test.cjs

qml-check:
	$(PYTHON) tools/qml_check.py

check: check-fast qml-check
	$(PYTHON) tools/check.py coverage
	$(PYTHON) tools/check.py dependencies
	gitleaks dir . --redact --no-banner

fix:
	ruff format .
	ruff check --fix .
	$(QML_BIN)/qmlformat -i *.qml tests/qml/*.qml tests/qml/imports/*/*/*.qml


# Optional SAST; downloads registry rules, so it is not part of `check`. semgrep raises the stack
# soft limit to a third of the hard limit; with an unlimited hard limit semgrep-core segfaults, so
# bound the hard limit inside this recipe's shell only.
semgrep:
	ulimit -Hs 1048576 && ulimit -s 65536 && semgrep scan --metrics=off --disable-version-check \
		--config p/python --config p/security-audit --config p/javascript --config p/secrets \
		--error backend Model.js $(wildcard *.qml)
