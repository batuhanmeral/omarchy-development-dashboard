PYTHON ?= python3
QML_BIN ?= /usr/lib/qt6/bin
OMARCHY_PATH ?= /usr/share/omarchy
export QML_BIN OMARCHY_PATH
export PYTHONDONTWRITEBYTECODE = 1
# omarchy-plugin-validate rejects every id under locales such as tr_TR, where "i" is outside [a-z].
export LC_ALL = C.UTF-8

.PHONY: setup check check-fast fix test qml-check
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
	$(QML_BIN)/qmlformat -i *.qml tests/qml/*.qml tests/qml/imports/qs/*/*.qml

