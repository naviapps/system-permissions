# ``SystemPermissions``

Shared permission values, validation and observation backed by Rust.

Use `PermissionChecker` with an injected `PermissionEnvironment` or import
SystemPermissionsMacOS for live system operations. `PermissionType` identifies a
permission; Automation additionally requires its receiving application identifier.
`PermissionOperationResult` separates a supported state from an unavailable
operation and an API failure. `PermissionStatus` retains unknown and limited
states. Hosts choose required domains and request timing.

`PermissionEnvironment` accepts a platform for injected effects. The checker
uses Rust's capabilities and Settings destinations for that platform. The
initializer without a platform uses macOS. A host that selects Windows supplies
its own effects.

``PermissionStatusChecking`` supplies only status checks, including the
`status(for:)` convenience using defaults for the checker's platform. Custom
status providers do not need request or Settings methods.
``PermissionStatusObserver`` uses this capability for all observation streams.
Rust validates the descriptor list and removes duplicates in first-occurrence
order. An invalid list finishes without invoking the options or status providers.
Status checks must never prompt or open Settings.
``PermissionChecking`` inherits the status capability and adds explicit requests
and Settings navigation. ``PermissionChecker`` supports both.

Use `openSystemSettings(for:options:)` to validate an explicit Settings action
before dispatch. Pass `.none` when there are no options. An unavailable
destination returns its capability and incompatible options produce
`.failed(.invalidOptions)`. Invalid descriptors or results throw a
`PermissionContractError`. Task cancellation throws `CancellationError`;
after dispatch the effect might still complete. A successful launch is
a Boolean acknowledgement and has no effect on stored permission status.
The default implementation for custom checkers delegates to their synchronous
Settings operation after validating admission.

The streams buffer the newest events up to the number of unique permissions.
Use `updates` or `throwingUpdates` for current status. Each poll repeats stable
samples. Use `changes` or `throwingChanges` for best-effort transitions. A slow
consumer can miss transitions, and the previous result describes the preceding poll.
Rust validates each result and compares it with the preceding poll for the same permission. A rejected
result stops polling and the stream delivers any buffered valid events.
`throwingUpdates` and `throwingChanges` then throw a ``PermissionContractError``.
`updates` and `changes` finish normally after the buffered delivery.
Unsupported and failed OS results are observations in both forms.

`PermissionType/metadata(on:options:)` supplies platform-specific capability and
usage-description information. Missing usage descriptions belong to the host app.
The capability's `systemSettingsURLString` preserves the exact Settings
destination for Codable, equality, and tracking. Its `systemSettingsURL` property
provides the Foundation URL for opening Settings.
Use `PermissionType.decodeJSON(_:)` on original UTF-8 descriptor data from an
external source. Rust validates the full object, including duplicate keys and
nested object shapes. The `Codable` conformance also supports embedding the type
in host serialization.
``UsageDescriptionKey`` includes the predefined macOS keys and accepts
Rust-validated host keys through `init(rawValue:)`. The key's spelling is
preserved in both the descriptor and its JSON representation.
Cancelling observation stops subsequent checks and discards an outstanding check's
result. An uncooperative provider may finish that check before the producer releases
it. Cancellation never undoes a system change.

`PermissionContractError` reports native contract failures separately from OS
permission results. The state store never reports a rejected oversized update as
an unchanged successful batch.

## Topics

### Permission values and metadata

- ``PermissionType``
- ``PermissionStatus``
- ``PermissionOperationResult``
- ``PermissionCapability``
- ``PermissionOptions``
- ``UsageDescriptionKey``
- ``NotificationRequestOptions``
- ``PermissionContractError``

### Checking and observation

- ``PermissionStatusChecking``
- ``PermissionChecking``
- ``PermissionChecker``
- ``PermissionEnvironment``
- ``PermissionStatusObserver``
