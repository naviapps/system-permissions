# SystemPermissions

System permission contracts and native integrations for Rust, Swift, C and
.NET. Hosts own product requirements, explanations, prompt timing and recovery UI.

Start with [Swift](#swift), [Rust and C](#rust-c-and-net), or the
[.NET installation and usage guide](bindings/dotnet/README.md).

## Layout

| Path                                             | Contents                                                |
| ------------------------------------------------ | ------------------------------------------------------- |
| `crates/`                                        | Rust implementation and C API in `crates/ffi/include/`  |
| `crates/ffi/tests/c/`                            | C ABI tests                                             |
| `Sources/`, `Tests/`                             | Swift bindings and tests                                |
| `bindings/dotnet/src/<project>/`                 | Named .NET source projects                              |
| `bindings/dotnet/tests/SystemPermissions.Tests/` | .NET test project and fixtures                          |
| `Artifacts/`, `ThirdParty/`, `native.toml`       | Native packages, upstream notices and artifact settings |
| `fixtures/consumers/`                            | Independent package consumers                           |
| `distribution/`                                  | Package and native acceptance drivers                   |

## Responsibility

Rust owns descriptors, platform metadata, identifier/options/result validation,
access-state interpretation, direct status and request admission, stored work admission
and state generations.
Direct admission selects the operation capability and fills omitted options before any host
provider runs. Explicit options retain their values. The same store rejects stale
results in every binding. macOS and Windows adapters own their OS calls and native
scheduling. A permission status is an observation, not a guarantee that a subsequent
operation succeeds. DesktopActions retains its actual execution results.

Unknown, denied, unsupported and failed are distinct. No check implicitly requests
access, opens Settings, changes security policy, elevates the process or installs
helpers. Cancellation cannot dismiss an OS dialog or reverse a permission change.
Started work still supersedes older tokens even when later cancelled. Cancellation
observed before state application publishes no result; once synchronous application
starts, its committed outcome is retained. Swift awaits an uncooperative provider;
.NET can stop awaiting after cancellation while that provider finishes independently.
Direct Swift `PermissionChecker` status and request calls return
`.supported(.unknown)` when cancellation is observed before or after the provider
call. This discards the provider's observation without implying denial or
reversing an OS permission change.

Apple Events permission is scoped to a target application identifier. There is no
global granted Automation state. `PermissionType.builtIn` lists the domains that do
not require a target; construct `.automation(targetApplication:)` explicitly.
On macOS, a passive Automation check returns `.supported(.unknown)` when the
target is not running. It does not launch the target or prompt. An explicit
request for a stopped target still returns `.failed(.apiUnavailable)`.
Windows does not have equivalents for every macOS privacy domain. Unsupported
operations remain explicit. Input injection and protected/elevated targets have
separate OS restrictions and are not made available by this package.

## Notification option wire contract

`notificationOptions` is an unsigned 64-bit JSON integer shared by Swift, Rust/C
and .NET. Its named bits are SDK values, not native platform bit positions:

| Swift option                      | .NET option                       | Wire bit |
| --------------------------------- | --------------------------------- | -------- |
| `alert`                           | `Alert`                           | 1        |
| `badge`                           | `Badge`                           | 2        |
| `sound`                           | `Sound`                           | 4        |
| `criticalAlert`                   | `CriticalAlert`                   | 8        |
| `provisional`                     | `Provisional`                     | 16       |
| `providesAppNotificationSettings` | `ProvidesAppNotificationSettings` | 32       |

Combine named values with bitwise OR; alert plus sound is `5`. Raw values retain
all 64 bits, including unknown bits, through validation and serialization. Unknown
bits do not add native capabilities. The macOS adapter maps each supported named
option explicitly to `UNAuthorizationOptions`; it does not cast the raw mask.
Windows notification authorization remains unsupported.

Earlier .NET names used native Apple bit positions. Existing raw masks have no
version or origin information and remain unchanged; hosts migrating saved values
must translate only when their original meaning is known. There are no legacy
aliases or automatic reinterpretations. `CarPlay`, `Announcement` and
`TimeSensitive` are not named options in this portable contract.

## Swift

Use Swift 6.3 or later on macOS 26 or later. Add the repository at a completed full
commit revision and select `SystemPermissions`, `SystemPermissionsMacOS`, or both.
`Package.swift` ships the source-bound universal `CSystemPermissions.xcframework`;
consumers do not need Rust.

A normal host package can select both public products with the following manifest.
Replace `FULL_COMMIT_REVISION` with an accepted full 40-character commit revision;
it is a placeholder, not a published version or a usable pin.

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "PermissionHost",
  platforms: [.macOS(.v26)],
  dependencies: [
    .package(
      url: "https://github.com/naviapps/system-permissions.git",
      revision: "FULL_COMMIT_REVISION"),
  ],
  targets: [
    .executableTarget(
      name: "PermissionHost",
      dependencies: [
        .product(name: "SystemPermissions", package: "system-permissions"),
        .product(name: "SystemPermissionsMacOS", package: "system-permissions"),
      ]),
  ]
)
```

```swift
import SystemPermissions
import SystemPermissionsMacOS

let checker = PermissionChecker()
let status = await checker.status(for: .screenRecording)
let target = PermissionType.automation(targetApplication: "com.example.editor")
let automationStatus = await checker.status(for: target)

// Invoke only after the host decides that a user-initiated request is appropriate.
let requested = await checker.requestAccess(for: target)
```

A `PermissionEnvironment` injects status, request and Settings effects for tests or
host-specific providers. The closure initializer uses macOS metadata by default.
An explicit `platform: .windows` selects Rust's Windows capability, default
options and Settings destinations for a host-supplied backend. The distributed
Swift package includes live effects for macOS. Validate capability and result
information instead of assuming that every domain has a reliable public status
API. Native notification operations require an app-bundle process. Command-line
processes return an API unavailable result. Usage descriptions remain the host's
Info.plist responsibility.
After a macOS notification request completes, the result reflects the app's current
authorization settings, including `provisional` authorization.

`PermissionStatusObserver` requires only `PermissionStatusChecking`.
A custom status provider implements
`status(for:options:)` without request or Settings methods; the protocol also supplies
`status(for:)` using Rust's default options for the checker's platform. Custom
status providers default to macOS and can specify a `platform`. Status checks
must never prompt or open Settings. `PermissionChecking` inherits this capability
and adds explicit request and Settings operations, so `PermissionChecker`
supports both observation and interactive workflows.

For an explicit Settings action, use
`try await checker.openSystemSettings(for: .camera, options: .none)` to check
options and the platform destination through Rust before dispatch. It returns
`.failed(.invalidOptions)` for incompatible options, `.unsupported` when the
platform has no destination, and `.supported(true)` when the effect opens it.
Contract failures and task cancellation throw. Cancellation observed before
dispatch prevents the effect. Cancellation after dispatch can discard the
acknowledgement. A launch acknowledgement conveys only whether Settings opened.

`UsageDescriptionKey(rawValue:)` accepts a host-defined Info.plist key when it
passes the shared Rust validation. Predefined constants such as `.camera` are
listed by `UsageDescriptionKey.allCases`. Keys encode as JSON strings and keep
their exact spelling. Custom permission metadata removes exact duplicates in
first-occurrence order. `PermissionType.metadata(on:options:)` returns the
platform's capabilities and usage-description requirements. Use
`systemSettingsURL` to open a capability's Settings destination and
`systemSettingsURLString` for the exact string used in encoding and equality.
Use `PermissionType.decodeJSON(_:)` for external UTF-8 JSON to validate the original
object, including duplicate keys and nested object shapes. Its `Codable`
conformance supports embedding permission descriptors in host serialization.

The observation streams buffer the newest events up to the number of unique
permissions. For a current-status view, use `updates` or `throwingUpdates`.
Each poll repeats stable samples. For best-effort transitions, use `changes`
or `throwingChanges`. A slow consumer can miss events, and the previous
result describes the preceding poll.

```swift
func statusUpdates(
  using checker: any PermissionStatusChecking
) -> AsyncThrowingStream<PermissionStatusObserver.Update, any Error> {
  PermissionStatusObserver.throwingUpdates(for: [.accessibility], using: checker)
}
```

Observation cancellation stops subsequent checks and discards an outstanding
check's result. An uncooperative status provider may finish that check before the
producer releases it.

Before polling, Rust validates the entire descriptor list and deduplicates it in
first-occurrence order. Rejected descriptors stop observation before either provider runs.
Rust validates each provider result, remembers the preceding sample per
permission, and identifies changes. The stream adapter schedules polling
and delivers events. An observer's sample history is independent of admitted
work and stored statuses.
A rejected result stops polling and the stream delivers any buffered valid events.
`throwingUpdates` and `throwingChanges` then report the `PermissionContractError`
to a `for try await` consumer. `updates` and `changes` finish normally after the
buffered delivery. Supported, unsupported, and failed OS observations remain
values in all four streams.

```swift
@MainActor
func makeStore() throws -> SystemPermissionsStore {
  try SystemPermissionsStore(trackedTypes: [.accessibility, .screenRecording])
}
```

The observable dictionary is a projection of Rust state. A cancelled batch commits
none of its updates. Refreshes skip permissions with a pending explicit request for
their stored scope and return the last stored values for those entries. A batch still
refreshes other permissions. Among operations that start for the same permission,
the newer operation supersedes the older one. Refresh and request methods throw
`PermissionContractError` for native contract failures, including an oversized
atomic batch. Such failures preserve all previous states and are distinct from an
unchanged update or an OS denial. Handle the error explicitly; a subsequent
single-permission refresh can still succeed. Invalid descriptors and conflicting
metadata fail construction before any OS operation. Explicitly select tracked types
and call `refreshAll()` before using current status; initial results are supported/unknown.

The store reports Photos read/write status through `status(for:)` and
`allowsAccess(_:)`. Pass `.photos(.addOnly)` to `refresh(_:options:)` or
`requestAccess(for:options:)` for a separate result that leaves read/write
status and pending work intact. A cancelled add-only operation returns unknown.
Use `refresh(.photos)` for a read/write observation. Options that do not apply to
the permission return `.failed(.invalidOptions)` before invoking the checker or
changing tracked results or ordering.

## Rust, C and .NET

The `system-permissions` Rust crate has no OS side effects. The Windows crate
provides native Windows operations. The C header at
`crates/ffi/include/system_permissions.h` owns operation and memory contracts.
Results own their bytes; copy borrowed views before releasing the result. Store
calls serialize state access and do not call host code while holding a lock.
Freeing a store requires exclusive ownership and no concurrent callers.

Rust coordinates stored-scope refreshes and explicit requests through `admit` and
`finish`. `admitScoped` also validates options before reservation and identifies
isolated Photos add-only operations without reserving any stored work.
`admitAllRefreshes` reserves work for all tracked scopes in one call,
skipping scopes with pending requests. A pending request suppresses a passive
refresh without invoking its checker. A newer request supersedes earlier work.
Finish every admitted token, including after cancellation, provider failure or a
rejected commit. Stale cleanup cannot retire a newer request. Cancellation does
not revive earlier tokens or reverse an OS effect. Adapters retain their native
task and thread scheduling.

The lower-level `begin` and `apply` operations provide explicit manual ordering.
Manual begin supersedes existing work, including pending request protection.
An applied token remains reusable until superseded, removed or explicitly finished.
Use one store's tokens only with that same store. Independent checkers and status
observers do not participate in a store's admission lifecycle.

For a separate Rust application, replace `<FULL_PUBLISHED_COMMIT_SHA>` with the
complete published SDK revision:

```toml
[dependencies]
system-permissions = { git = "https://github.com/naviapps/system-permissions.git", rev = "<FULL_PUBLISHED_COMMIT_SHA>" }
```

On macOS 26 or later, a C application can install `CSystemPermissions.framework`
from the universal slice of `Artifacts/CSystemPermissions.xcframework` with its
retained notices. Include `<CSystemPermissions/system_permissions.h>` and link
with `-framework CSystemPermissions`, using `-F` and a runtime search path that
select the installed framework's parent directory. The installed C client needs
neither Rust nor an SDK source checkout.

.NET uses `NaviApps.SystemPermissions` for shared contracts/state and
`NaviApps.SystemPermissions.Windows` for Windows integration. Standalone Windows
builds produce `win-x64` native assets and local NuGet packages.
See the [.NET guide](https://github.com/naviapps/system-permissions/blob/main/bindings/dotnet/README.md) for
the ARM64-hosted x64 build, local package installation and managed usage.

## Development and verification

Rust tests cover the full metadata, access, option validation and store ordering
contracts. Binding tests exercise typed values and errors across the native
boundary, installed package consumption, async cancellation and native effects.

Use Rust 1.99.1 and .NET 10 with repository/task-specific tool selection. Rebuild
native artifacts after Rust, header, native build or upstream-notice changes.
[`native.toml`](native.toml) declares the build settings.
`Artifacts/native-build.json` binds the build inputs to the tracked framework. Required
upstream notices and Rust runtime provenance remain under `ThirdParty/`. The
macOS builder combines the original notice bodies verbatim in
`Resources/ThirdPartyNotices.txt`; NuGet packages retain the original notice files.

Review `mise.toml` before trusting it, then run these commands from the repository
root. `mise install` can download the pinned developer tools.

```sh
mise trust mise.toml
mise install
mise exec -- cargo fetch --locked
mise exec -- make check
```

`make check` runs source lint, Rust tests and Clippy, and the Swift and .NET
binding suites against the tracked framework. It also runs an external Swift
consumer. The Cargo fetch primes the cache for the locked offline checks.
The checks use synthetic effects.

### Distribution verification

[SDK Tooling](https://github.com/naviapps/sdk-tooling) runs the shared checks.
The `sdk-tooling` task in [`mise.toml`](mise.toml) pins its exact commit. The
regular checks fetch that version automatically.

Run local distribution checks with the same pinned tooling:

```sh
mise exec -- make check-distribution
```

Run the hosted macOS and Windows distribution checks from the SDK checkout at
the intended commit on `main`:

```sh
gh workflow run check-sdk-distribution.yml -R naviapps/sdk-tooling \
  -f sdk=system-permissions -f "revision=$(git rev-parse HEAD)"
```

`make check-distribution` verifies the tracked framework and tests C ownership,
managed bindings and clean local NuGet consumption. Use `mise exec -- make native` when the framework needs rebuilding.

`make test-consumer` builds and runs `fixtures/consumers/swift/` against a disposable
SDK containing only `Package.swift`, `Sources`, `Tests`, `Artifacts` and `ThirdParty`.
It imports both public products, loads native metadata and descriptor validation,
round-trips notification masks including all 64 bits, validates Settings navigation
with a fake effect and projects injected success and API-failure results through
`SystemPermissionsStore`. Invalid options and an
invalid Automation target must fail before provider dispatch. Every checker is
explicitly injected; no live permission query, request or Settings operation runs.
The consumer check isolates SwiftPM configuration, caches and build output,
excludes Rust and developer tools, and uses the tracked framework without rebuilding
it. Run `mise run sdk-tooling -- swift-consumer --distribution` for the full dependency graph
check. `--git-config` and `--mirror-config` select explicit dependency settings
for that mode.

`mise exec -- make test-installed-consumers` runs the independent Rust Git and
installed C clients on macOS with the pinned toolchain available from the
temporary consumer directory. Both exercise notification options and rejection
of mismatched input without permission requests or OS settings access. The Rust
client resolves a fresh Cargo lock and may fetch public registry crates into an
empty cache before it builds and runs offline. The gate checks each Git dependency
against the declared sources and uses a copied framework. SDK Tooling runs it
in the macOS distribution job.

From a shallow checkout, pass a complete local mirror or bundle that contains the
exact SDK commit. The optional evidence path must be unused and outside the SDK
checkout:

```sh
mise run sdk-tooling -- rust-c-consumers \
  --git-source /path/to/system-permissions.bundle \
  --evidence /path/to/new/installed-consumers.json
```

Default Swift tests use injected providers for requests and Settings opening. Live
smoke tests only query nonprompting status. GitHub Actions runs the same strict
Swift tests and standalone Swift consumer on macOS 26 and 27. The public Windows
x64 job runs Rust and managed binding tests. The SDK Tooling distribution jobs
cover packages and native consumers. Use owned isolated fixtures for requests,
system UI and Windows ARM64 emulation.

This succeeds the local PermissionsKit integration. The old GitHub repository and
its published source/history are unchanged. The host retains product-specific
permission selection, localized copy, onboarding, guidance suppression and behavior
after denial or cancellation. Stored preferences, Keychain contents and OS grants
are not migrated or modified by installing this SDK.

## Static checks

`mise install` prepares pinned developer tools. Run `mise run lint` before builds
or `mise run format` to format owned source. Compiler and native acceptance remain
in the existing check targets. Formatting excludes vendored code, native artifacts
and original notices.

## License

This SDK is licensed under the [MIT License](LICENSE). Keep the
[third-party notices](ThirdParty/) with redistributed artifacts.
