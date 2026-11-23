SDK_TOOLING ?= mise run sdk-tooling --
MACOS_LIBRARY := $(CURDIR)/Artifacts/CSystemPermissions.xcframework/macos-arm64_x86_64/CSystemPermissions.framework/CSystemPermissions

.DEFAULT_GOAL := check
SWIFT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
.PHONY: check check-source test-managed check-distribution lint native native-verify test test-consumer test-installed-consumers test-rust test-bindings test-windows-fixtures docs
check: check-source test test-consumer

check-source: lint test-rust test-managed
check-distribution: native-verify test-bindings test-windows-fixtures docs
lint:
	mise run lint
native:
	$(SDK_TOOLING) native
native-verify:
	$(SDK_TOOLING) native --verify
test:
	swift test $(SWIFT_FLAGS)
test-consumer:
	$(SDK_TOOLING) swift-consumer
test-installed-consumers:
	$(SDK_TOOLING) installed-consumers
test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline
test-bindings:
	$(SDK_TOOLING) python fixtures/distribution/bindings.py
test-windows-fixtures:
	$(SDK_TOOLING) python -m unittest discover -s fixtures/distribution/tests -v
docs:
	$(SDK_TOOLING) docs

.PHONY: format
format:
	mise run format

test-managed:
	SYSTEM_PERMISSIONS_NATIVE_LIBRARY="$(MACOS_LIBRARY)" \
		dotnet run --configuration Release --project bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj
