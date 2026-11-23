# SystemPermissions for .NET

`NaviApps.SystemPermissions` contains thin Rust C bindings,
public values, a checker and an owned deterministic store.
`NaviApps.SystemPermissions.Windows` supplies Windows native effects.
Metadata, descriptor and options validation, identity, access semantics and stale
update rejection are shared Rust behavior, not managed policy tables.

## Install

Use .NET 10. The repository's scripts pack from a local checkout.
The selected native asset is one of `osx-arm64`, `osx-x64` or `win-x64`.
macOS requires version 26 or later. The Windows adapter uses Windows 10 version
1903 or later APIs. On Windows 11 ARM64, run the installed package in an x64
.NET process under emulation.

From the repository root, prepare the pinned tools described in the
[developer setup](../../README.md#development-and-verification).
On macOS, run:

```sh
mise exec -- make test-bindings
```

This uses the tracked framework, runs C and managed fixtures and packs both
projects into `build/bindings/packages/` for the current Mac architecture.

On Windows 11 ARM64, build x64 from an ARM64 PowerShell with native ARM64
Python and Rust, the ARM64-hosted x64 MSVC toolset, and the x64 .NET SDK version
pinned in [`global.json`](../../global.json).
Visual Studio supplies the cross-target compiler under `HostARM64\x64`.
[ARM64 Visual Studio compiler paths](https://learn.microsoft.com/visualstudio/install/visual-studio-on-arm-devices).
Microsoft installs the x64 SDK in the `x64` subfolder alongside ARM64 .NET.
[Install .NET on Windows](https://learn.microsoft.com/dotnet/core/install/windows).
On a VM Runner worker that was prepared with both SDKs, use its
`ToolsRoot\dotnet-x64\dotnet.exe` for `DOTNET_BIN`.

From the SDK root, use the SDK Tooling task pinned in [`mise.toml`](../../mise.toml).

```powershell
$env:DOTNET_BIN = 'C:\Program Files\dotnet\x64\dotnet.exe'
rustup target add x86_64-pc-windows-msvc
mise run sdk-tooling -- windows distribution/verify_windows.py
```

The script selects ARM64-hosted x64 MSVC on an ARM64 worker and native x64 MSVC
on an x64 worker. Keep `DOTNET_BIN` set to the absolute x64 executable on ARM64.

The script places both packages and their receipt in `build/windows/win-x64/`.
On ARM64, Windows executes the x64 Rust and C fixtures and the x64 .NET process
through emulation. The C fixture, managed fixture and NuGet package use the
same staged DLL. The receipt records its SHA-256, target, host, execution mode
and SHA-256 hashes of the pinned distribution tooling.
When `VM_RUNNER_ARTIFACTS_DIR` is set, it writes the verified pair and receipt directly
into that directory's `win-x64` subdirectory.
The public Windows x64 workflow runs Rust and managed binding tests. SDK Tooling's
hosted distribution check also installs an owned, temporary x64 MSIX to check
package identity, nonprompting status, unsupported direct consent and Settings
admission. The fixture removes its package and signing certificate after the test.
The local command also supports x64 emulation on Windows ARM64.

In a .NET 10 host project, point `LOCAL_PACKAGE_DIRECTORY` at that package folder
or an approved private feed containing both packages:

```sh
dotnet add package NaviApps.SystemPermissions.Windows --version 0.1.0 --source "LOCAL_PACKAGE_DIRECTORY"
```

The Windows package brings in `NaviApps.SystemPermissions`. A host that only needs
shared contracts and injected effects can reference `NaviApps.SystemPermissions`
instead. Packages carry the native asset and required notices. The .NET runtime
resolves the native asset after restore.

## Usage

`NotificationRequestOptions` uses these shared SDK wire bits:
`Alert=1`, `Badge=2`, `Sound=4`, `CriticalAlert=8`, `Provisional=16` and
`ProvidesAppNotificationSettings=32`. These are not native platform bit positions.
Arbitrary raw `ulong` masks, including unknown bits, remain exact through JSON and
Rust validation. They do not enable Windows notification authorization.
Earlier .NET masks require host-controlled translation only when their origin and
meaning are known; the SDK cannot infer a version from a raw integer and supplies
no compatibility aliases or automatic migration.

```csharp
using NaviApps.SystemPermissions;
using NaviApps.SystemPermissions.Windows;

// Capture on the application's existing STA UI thread.
var dispatcher = new SynchronizationContextPermissionDispatcher(
    SynchronizationContext.Current ?? throw new InvalidOperationException());
var checker = new PermissionChecker(new WindowsPermissionEnvironment(dispatcher));
using var store = new PermissionStore();
store.Track([PermissionDescriptor.Camera]);
await store.RefreshAsync(checker, PermissionDescriptor.Camera);
// Only call from an explicit user action:
await checker.OpenSettingsAsync(PermissionDescriptor.Camera);
```

`RefreshAsync` and `RefreshAllAsync` take `IPermissionStatusChecking` so read-only
providers only implement `StatusAsync`. A batch checks the tracked permissions
whose stored scopes have no pending request, then commits the current results
together through Rust. The returned snapshot includes all permissions currently
tracked by the store. Cancellation or a provider or validation failure leaves
the batch's results unpublished. A newer operation may supersede a batch entry
without preventing other current entries from committing.
Scoped refresh and request callbacks also receive the validated descriptor.
The store invokes the provider with custom usage description keys deduplicated
by Rust.
When options are omitted, `PermissionChecker` supplies the selected platform's
Rust-defined defaults to its status and request providers.

`PermissionContract.ValidateUsageDescriptionKey` validates a host-defined
Info.plist key and returns its exact spelling. Custom permission descriptors use
the same Rust validation for `UsageDescriptionKeys` and keep only the first
occurrence of each exact key. Strings with unpaired UTF-16 surrogates are
rejected with the `invalidJson` error before native dispatch.

Use `PermissionContract.DecodeDescriptorJson` to validate an external descriptor
directly from its original UTF-8 JSON bytes. Rust validates the full object,
including duplicate keys and nested object shapes, and returns a typed descriptor.

A `CustomPermission` copies its usage description keys at construction and
in a `with` assignment. Descriptor value equality compares the capability
and key order, including keys from independent native round trips. Use
`PermissionDescriptor.HasSameIdentity` to compare the exact ID and target
application used for tracking, like Swift's `PermissionType` equality. Rust
still validates supplied descriptors and rejects conflicting metadata for a
tracked identity.

For a read-only status view, enumerate `PermissionStatusObserver.Updates`.
For transitions, use `PermissionStatusObserver.Changes`:

```csharp
await foreach (var sample in PermissionStatusObserver.Updates(
    [PermissionDescriptor.Camera, PermissionDescriptor.Microphone], checker,
    cancellationToken: cancellationToken))
{
    RenderStatus(sample.Permission, sample.Result);
}
```

Each enumeration starts an independent poll. The observer validates and
deduplicates descriptors through Rust, then checks them in first-occurrence
order. Invalid descriptors or conflicting metadata reject the entire list before
any options or status callbacks. Empty inputs finish immediately. Polling starts
when enumeration starts, then waits two seconds after each pass by default. Intervals below 250
milliseconds are clamped to 250 milliseconds. Waiting between polls remains
cancellable for any positive interval. Option callbacks and status providers
run on the polling worker. Omit the callback to use the checker's
default options, or supply explicit options for each permission.

The store and observer examine caller enumerables only through the first item
beyond the Rust store's 1,024-entry limit. Rust validates the captured batch
before changing tracked state or starting observation.

`Updates` emits initial and unchanged samples, including failed and unsupported
observations. `Changes` emits differences between consecutive polls. Both
streams keep the newest buffered events, up to the number of unique permissions.
A slow reader can miss events. A change's previous result always describes the
preceding sample, even if the reader missed it. Cancelling or disposing the
enumerator stops later checks and discards any outstanding result. A cancelled
enumeration reports cancellation. Rust validates each result and compares it with
the preceding poll for the same permission. A provider exception or a malformed result ends the stream
with the corresponding error after any buffered valid events.

`StatusAsync` never prompts. For a completed check, cancellation is sampled once
at synchronous apply entry. A captured cancellation
discards the update after Rust validation; validation failures retain their typed
error. Cancellation arriving after that sample returns the resulting stored status.
The store uses Rust admission/apply/finish tokens. A refresh for a scope with a
pending explicit request returns its stored status without invoking the checker;
other scopes continue refreshing. A new request supersedes earlier work. Every
admitted operation retires its token after completion, cancellation or failure,
without restoring earlier tokens or clearing a newer request. Public `Begin` and
`Apply` retain explicit caller-controlled ordering: a manual begin supersedes
earlier work, including a pending request. Removal/re-add also rejects late results.
Hosts supply their own explanations, timing and recovery UI.
Refresh/request on an untracked permission throws before invoking the checker.
Completed tracked work returns the current stored result, including when its own
completion was superseded. Settings results cannot be applied to permission state.
The stored Photos entry represents read/write access. An explicit add-only check
or request returns its own scoped result without publishing it or superseding
pending read/write work. Rust validates options before reserving a token. Options
for a different permission return `Failed(InvalidOptions)` without invoking the
provider, changing stored results or superseding earlier operations.

### Windows privacy

Windows 10 version 1903 or newer provides AppCapability. This adapter checks
`webcam`, `microphone` and `location` when the current process has package identity
and the native API is available. Packaged callers declare the relevant capability.
`NotDeclaredByApp` and system restrictions map to `restricted`; user denial maps
to `denied`. Unpackaged processes and unavailable APIs return `apiUnavailable`.
This conservative limitation does not assert that unpackaged applications lack
device access through other Windows APIs. A status check never opens a device.

For Windows desktop applications, `RequestAsync` returns `Unsupported` for direct
consent and preserves the corresponding Settings destination. The native consent UI
requires a UWP CoreWindow. Call `OpenSettingsAsync` explicitly with the user's intent
to open that destination. An injected host environment can still implement its own
validated custom operations.
[Windows desktop API compatibility](https://learn.microsoft.com/windows/apps/desktop/modernize/winrt-api-desktop-app-support).

Accessibility, input monitoring, general screen recording, Apple Events automation
and the other macOS-only built-ins remain unsupported on Windows. No synthetic
grant, elevation, UIAccess modification or UIPI bypass is attempted. Explicit
Settings navigation is available only for built-in destinations known to Rust;
successful launch returns `PermissionSettingsResult.Supported(true)`. The
`PermissionChecker.OpenSettingsAsync` method shares Rust's Settings admission
with Swift's options-taking overload. It checks descriptor and options before
dispatch, returns a structured unsupported result when the platform has no
destination, and throws on cancellation. Injected environments may handle
their own validated custom destinations. Settings results are Boolean
operation outcomes and cannot be applied to the permission store.

## Validation

The platform binding tools validate C ownership and deterministic .NET contracts,
then pack and consume both NuGet packages using a fresh local-only package cache.
They do not start a VM or request permissions. Source checks use the
`SystemPermissionsNativeLibrary` MSBuild property to copy the selected native
library beside the managed output.

macOS validation consumes the tracked CSystemPermissions framework binary without rebuilding
or modifying it. Local NuGet staging preserves those bytes under the portable native
filename. Windows packages use the source-built DLL for the selected process architecture.
