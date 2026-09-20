.PHONY: build test check package
build:
	swift build -c release --product UsageBar
test:
	swift test
check:
	../Scripts/install_lint_tools.sh swiftformat swiftlint
	../.build/lint-tools/bin/swiftformat Sources Tests Package.swift --lint
	../.build/lint-tools/bin/swiftlint lint --strict --config .swiftlint.yml
	bash -n scripts/package.sh
	python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("host/metrics.py").read_text())'
package:
	./scripts/package.sh
