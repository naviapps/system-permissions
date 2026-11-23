.DEFAULT_GOAL := check
SWIFT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
.PHONY: check check-source test-managed check-distribution lint native native-verify test test-consumer test-installed-consumers test-rust test-bindings test-windows-tool docs
check: check-source test test-consumer

check-source: lint test-rust test-managed
check-distribution: native-verify test-bindings test-windows-tool
lint:
	mise run lint
native:
	python3 tools/native.py
native-verify:
	python3 tools/native.py --verify
test:
	swift test $(SWIFT_FLAGS)
test-consumer:
	mise run sdk-tooling -- swift-consumer
test-installed-consumers:
	mise run sdk-tooling -- installed-consumers
test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline
test-bindings:
	python3 tools/bindings.py
test-windows-tool:
	python3 -B -m unittest discover -s tools/tests -v
docs:
	mise run sdk-tooling -- docs

.PHONY: format
format:
	mise run format

test-managed:
	dotnet run --configuration Release --project bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj -- --notification-options-only
