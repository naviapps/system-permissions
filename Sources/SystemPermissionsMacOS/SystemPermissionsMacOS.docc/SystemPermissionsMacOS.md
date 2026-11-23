# ``SystemPermissionsMacOS``

Native macOS permission integrations and an observable Rust-backed state store.

The default SystemPermissions.PermissionChecker initializer uses public macOS
APIs. Queries never prompt. Requests and Settings navigation are explicit calls;
only the host can decide when they are appropriate. Apple Events requests are
scoped to the selected target application.
An Automation status check does not launch its target. If the target is not
running, the status is supported but unknown. An explicit request in the same
situation still reports `apiUnavailable`.

`SystemPermissionsStore` publishes selected permission states. Its throwing
initializer validates descriptors without OS effects. Refresh batches publish
atomically, and cancellation discards pending results. While an explicit request
for a stored permission scope is pending, refreshes skip that entry so a passive
check cannot supersede the request. A batch can still refresh other permissions.
A newer explicit request can supersede an older one. Swift owns scheduling and
observation; Rust owns state acceptance.

The Photos entry represents read/write access. A request with `.photos(.addOnly)`
returns its scoped result without publishing it or superseding a pending read/write
refresh. A cancelled add-only request returns unknown for that scope.

State refresh/request methods throw on native contract failures. An atomic batch
that exceeds the shared input budget leaves the whole prior snapshot unchanged;
callers must handle the error instead of treating the prior snapshot as a fresh
permission observation.

## Topics

### Observable permission state

- ``SystemPermissionsStore``
