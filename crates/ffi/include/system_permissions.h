#ifndef SYSTEM_PERMISSIONS_H
#define SYSTEM_PERMISSIONS_H
#define SYSTEM_PERMISSIONS_ABI_VERSION 2U
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct SystemPermissionsResult SystemPermissionsResult;
typedef struct SystemPermissionsStore SystemPermissionsStore;

uint32_t system_permissions_abi_version(void);

/* UTF-8 JSON, at most 1 MiB. Nonnull inputs must be readable for length bytes.
   The result is owned. status 0 = success JSON, 1 = {"error":"typedCode",...}.
   A valid validateIdentifier operation returns status 0 even for an invalid
   identifier: its success JSON is {"error":"validationReason"}, or {} if valid.
   Core operations have no OS effects or implicit prompting. Explicit windows*
   operations call the native adapter only on Windows, on the calling thread,
   never under the Store mutex. Panic unwinding is contained; allocation
   exhaustion is subject to the process allocator and is not a recoverable error. */
SystemPermissionsResult *system_permissions_call(const uint8_t *data, size_t length);

/* Views borrow the result; copy before free. No NUL terminator. Null result:
   status 1, data NULL, len 0. A nonnull result must be live from this library. */
uint32_t system_permissions_result_status(const SystemPermissionsResult *result);
const uint8_t *system_permissions_result_data(const SystemPermissionsResult *result);
size_t system_permissions_result_len(const SystemPermissionsResult *result);
void system_permissions_result_free(SystemPermissionsResult *result);

/* Store starts empty. Calls serialize access and never invoke callbacks while
   locked. Each call's returned result outlives the store. Free accepts NULL;
   otherwise it requires unique ownership and no concurrent users/calls. */
SystemPermissionsStore *system_permissions_store_new(void);
void system_permissions_store_free(SystemPermissionsStore *store);
SystemPermissionsResult *system_permissions_store_call(SystemPermissionsStore *store,
                                                       const uint8_t *data, size_t length);

/* Stateless operations:
   metadata {platform,permission,options?}; validateDescriptor {permission};
   validateOptions {permission,options}; allowsAccess {status};
   resultAllowsAccess {result} (validates a status result before checking access);
   validateIdentifier {identifier}; builtIns; validateResult {result};
   admitAccess {platform,permission,request:bool,options?} -> {options} when
     admitted, or {result:status result} when unsupported or mismatched.
     Omitted options use the platform default. No host provider is called.
   admitSettings {platform,permission,options?} -> {capability} when a
     destination exists, or {result:boolean Settings result} for an unsupported
     operation or options for a different permission. Does not open Settings.
   validateSettingsResult {result} (supported value is bool, not a status string).
   storeBatchLimit -> advisory entry limit for track and apply arrays.
   Each request object also has "op" with the operation name above.
   Permission descriptors, capabilities and update entries are JSON objects.

   Store operations:
   track {permissions} -> {values:[{permission,result}]};
   get {permission} -> result or null; begin {permission} -> {token:uint64 or null};
   recordObservation {permission,result} -> {result,previousResult} or null
     for an untracked permission. previousResult is null on the first or
     unchanged sample. Poll samples do not affect admitted work or stored status.
   admit {permission,kind:"refresh"|"request"} -> {token:uint64 or null};
   admitScoped {permission,options,kind:"refresh"|"request",cancelled:bool}
     -> {kind:"untracked"|"invalidOptions"|"isolated"|"suppressed"}
        or {kind:"stored",token:uint64};
   admitAllRefreshes -> [{permission,token:uint64}] in tracking order;
   finish {token:uint64} -> {finished:bool};
   apply {updates:[{permission,token,result}],cancelled:bool} -> {changed,accepted};
   snapshot -> {values:[{permission,result}]}.
   track replaces the set, preserves retained entries and deduplicates in order.
   Inconsistent metadata or duplicate update identities fail atomically.
   begin is explicit manual ordering: it supersedes prior work and clears typed
   request priority, even when its eventual apply is cancelled. Typed admit
   validates descriptor/metadata first, then suppresses refresh while the latest
   typed request is active. A typed request always supersedes prior work. A null
   admission token denotes either suppression or an untracked permission; get
   distinguishes them. All reservations share one store-global token sequence.
   admitScoped validates options before reserving. Add-only Photos operations
   identify an isolated scope, which has no token. Cancellation suppresses
   stored work. Adapters skip provider calls if the operation was cancelled.
   admitAllRefreshes skips pending requests and admits the remaining scopes
   together. Token exhaustion leaves all existing work unchanged.
   finish retires only matching current work without changing its result or
   reviving older tokens. Stale/missing nonzero tokens return false; zero fails.
   apply does not finish work: tokens remain reusable until superseded/finished,
   including after cancelled apply. Adapters finish on every terminal path.
   accepted counts matching tokens, including unchanged values; stale/untracked
   results are filtered after full validation. Tokens are scoped to their store.

   Explicit Windows operations (unavailable on other platforms):
   windowsStatus {permission,options} -> status result;
   windowsRequest {permission,options} -> {result:status result};
   windowsOpenSettings {permission,options} -> boolean Settings result.
   Desktop Windows reports direct requests as unsupported without calling the OS.
   A caller can explicitly open the Settings destination for a supported capability. */
#ifdef __cplusplus
}
#endif
#endif
