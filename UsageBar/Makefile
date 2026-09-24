.PHONY: build test check package install
INSTALL_DIR ?= /Applications
build:
	swift build -c release --product UsageBar
test:
	swift test
	python3 -m unittest discover -s scripts -p 'test_*.py'
	python3 -m unittest discover -s host -p 'test_*.py'
check:
	../Scripts/install_lint_tools.sh swiftformat swiftlint
	../.build/lint-tools/bin/swiftformat Sources Tests Package.swift --lint
	../.build/lint-tools/bin/swiftlint lint --strict --config .swiftlint.yml
	bash -n scripts/package.sh
	python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("host/metrics.py").read_text())'
package:
	./scripts/package.sh
# Quit the running copy, replace it with a fresh package, and relaunch so the live app matches the source.
install: package
	osascript -e 'quit app id "com.btuckerc.UsageBar"' 2>/dev/null || true
	for _ in 1 2 3 4 5; do pgrep -x UsageBar >/dev/null || break; sleep 1; done; pkill -x UsageBar || true
	ditto "dist/Usage Bar.app" "$(INSTALL_DIR)/Usage Bar.app"
	codesign --verify --strict "$(INSTALL_DIR)/Usage Bar.app"
	open "$(INSTALL_DIR)/Usage Bar.app"
