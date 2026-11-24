# SystemPermissions for .NET

`NaviApps.SystemPermissions` provides Rust-backed permission contracts, checking
and state. `NaviApps.SystemPermissions.Windows` supplies the Windows effects.
The [shared permission contract](https://github.com/naviapps/system-permissions/blob/main/README.md#responsibility)
defines permission states, operation admission and the host's responsibilities.

## Install

Use .NET 10 and download the core `system-permissions-nuget-<revision>-<attempt>`
artifact from a successful
[SDK distribution workflow](https://github.com/naviapps/sdk-tooling/actions/workflows/check-sdk-distribution.yml).
Check the package's SHA-256 against its receipt and place the `.nupkg` in a
local feed. The core includes `osx-arm64` and `osx-x64` for macOS 26 or later,
and `win-x64` for Windows. On Windows 11 ARM64, use x64 .NET under emulation.

For Windows host calls, also download the adapter artifact
`system-permissions-nuget-companions-<revision>-<attempt>` from the same run.
Verify its package against the Windows receipt and place it beside the core in
the local feed. Reference `NaviApps.SystemPermissions.Windows` to install the
adapter and its exact core dependency.

### Try the installed package

Run the commands in a new directory using the package's .NET architecture.
Replace `LOCAL_PACKAGE_DIRECTORY` with the absolute feed path and use the
downloaded version. For the adapter, substitute its package name. Restore to a
fresh cache when switching between candidate builds with the same version.

```sh
dotnet new console --framework net10.0 --no-restore
dotnet package add NaviApps.SystemPermissions --version "[0.1.0]" --no-restore
dotnet restore --source "LOCAL_PACKAGE_DIRECTORY" --packages .nuget-packages
```

Replace `Program.cs` with this portable check to verify that the native
contract loads without querying the OS or changing permission state.

```csharp
using NaviApps.SystemPermissions;

var camera = PermissionContract.DecodeDescriptorJson("{\"id\":\"camera\"}"u8);
Console.WriteLine(camera == PermissionDescriptor.Camera);
```

```sh
dotnet run --no-restore
```

The check prints `True`. For package builds and acceptance tests, see the
[maintainer's distribution guide](https://github.com/naviapps/system-permissions/blob/main/README.md#distribution-verification).

## Usage

`NotificationRequestOptions` represents the
[shared 64-bit wire mask](https://github.com/naviapps/system-permissions/blob/main/README.md#notification-option-wire-contract).
Use the SDK values in managed code and follow that contract when migrating raw
masks from earlier .NET versions.

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

The dispatcher must be created on the application's STA UI thread.

```csharp
using NaviApps.SystemPermissions;
using NaviApps.SystemPermissions.Windows;

var dispatcher = new SynchronizationContextPermissionDispatcher(
    SynchronizationContext.Current ?? throw new InvalidOperationException());
var checker = new PermissionChecker(new WindowsPermissionEnvironment(dispatcher));
using var store = new PermissionStore();
store.Track([PermissionDescriptor.Camera]);
await store.RefreshAsync(checker, PermissionDescriptor.Camera);
// Call from an explicit user action.
await checker.OpenSettingsAsync(PermissionDescriptor.Camera);
```

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
