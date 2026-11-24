SDK_TOOLING ?= mise run sdk-tooling --
MACOS_LIBRARY := $(CURDIR)/Artifacts/CSystemPermissions.xcframework/macos-arm64_x86_64/CSystemPermissions.framework/CSystemPermissions

.DEFAULT_GOAL := check
SWIFT_FLAGS := -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
.PHONY: check check-source test-managed check-distribution lint native native-verify check-header generate-header test test-consumer test-installed-consumers test-rust test-bindings test-distribution-tools clean
check: check-source test test-consumer

check-source: lint check-header test-rust test-managed
check-distribution: native-verify test-bindings test-distribution-tools
clean:
	$(SDK_TOOLING) clean .build target .native-build build/bindings build/windows \
	  bindings/dotnet/runtimes \
	  bindings/dotnet/src/NaviApps.SystemPermissions/bin bindings/dotnet/src/NaviApps.SystemPermissions/obj \
	  bindings/dotnet/src/NaviApps.SystemPermissions.Windows/bin bindings/dotnet/src/NaviApps.SystemPermissions.Windows/obj \
	  bindings/dotnet/tests/SystemPermissions.Tests/bin bindings/dotnet/tests/SystemPermissions.Tests/obj
lint:
	mise run lint
native: generate-header
	$(SDK_TOOLING) xcframework
native-verify: check-header
	$(SDK_TOOLING) xcframework --verify
check-header:
	$(SDK_TOOLING) c-headers check
generate-header:
	$(SDK_TOOLING) c-headers generate
test:
	swift test $(SWIFT_FLAGS)
test-consumer:
	$(SDK_TOOLING) swift-consumer
test-installed-consumers:
	$(SDK_TOOLING) rust-c-consumers
test-rust:
	cargo clippy --workspace --all-targets --locked --offline -- -D warnings
	cargo test --workspace --locked --offline
test-bindings:
	$(SDK_TOOLING) python distribution/verify_bindings.py
test-distribution-tools:
	$(SDK_TOOLING) python -m unittest discover -s distribution/tests -v
.PHONY: format
format:
	mise run format

test-managed:
	dotnet run --configuration Release --project bindings/dotnet/tests/SystemPermissions.Tests/SystemPermissions.Tests.csproj \
		-p:SystemPermissionsNativeLibrary="$(MACOS_LIBRARY)"
