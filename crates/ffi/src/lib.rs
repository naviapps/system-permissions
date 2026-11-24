//! C ownership and synchronization boundary; native effects never run under this mutex.
use permissions_core::{Error, MAX_INPUT_BYTES, Request, Store, decode, parse_store};
use serde::Deserialize;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Mutex;

mod windows;

/// Native C ABI version.
pub const SYSTEM_PERMISSIONS_ABI_VERSION: u32 = 2u32;

#[derive(Deserialize)]
#[serde(untagged)]
enum Command {
    Core(Request),
    Windows(windows::NativeCommand),
}

fn dispatch(input: &[u8]) -> Result<serde_json::Value, Error> {
    match decode(input)? {
        Command::Core(request) => request.dispatch(),
        Command::Windows(request) => request.dispatch(),
    }
}

pub struct SystemPermissionsResult {
    status: u32,
    data: Vec<u8>,
}

pub struct SystemPermissionsStore {
    state: Mutex<Store>,
}

#[cfg(test)]
#[path = "../tests/ownership.rs"]
mod ownership;

fn owned(result: Result<serde_json::Value, Error>) -> *mut SystemPermissionsResult {
    let (status, data) = match result {
        Ok(value) => (0, serde_json::to_vec(&value)),
        Err(error) => (1, serde_json::to_vec(&error)),
    };
    // All possible values have infallible JSON representations (no floats or custom serializers).
    let data = data.unwrap_or_else(|_| br#"{"error":"panic"}"#.to_vec());
    Box::into_raw(Box::new(SystemPermissionsResult { status, data }))
}

fn contained(f: impl FnOnce() -> Result<serde_json::Value, Error>) -> *mut SystemPermissionsResult {
    owned(catch_unwind(AssertUnwindSafe(f)).unwrap_or(Err(Error::Panic)))
}

#[unsafe(no_mangle)]
pub extern "C" fn system_permissions_abi_version() -> u32 {
    SYSTEM_PERMISSIONS_ABI_VERSION
}

unsafe fn input<'a>(data: *const u8, len: usize) -> Result<&'a [u8], Error> {
    if len > MAX_INPUT_BYTES {
        return Err(Error::InputTooLarge);
    }
    if data.is_null() {
        return Err(Error::InvalidBuffer);
    }
    // SAFETY: The foreign caller guarantees a readable allocation; u8 has alignment one.
    Ok(unsafe { std::slice::from_raw_parts(data, len) })
}

/// Dispatches a stateless request encoded as UTF-8 JSON, up to 1 MiB.
///
/// The result is owned. Status 0 holds success JSON. Status 1 holds
/// `{"error":"typedCode",...}`. A valid `validateIdentifier` operation returns
/// success even for an invalid identifier. Its value is
/// `{"error":"validationReason"}` for an invalid identifier and `{}` otherwise.
///
/// Every request object includes an `op` containing the operation name.
/// Permission descriptors, capabilities and update entries are JSON objects.
/// Supported stateless operations and request fields follow.
///
/// - `metadata {platform,permission,options?}`
/// - `validateDescriptor {permission}`
/// - `validateOptions {permission,options}`
/// - `allowsAccess {status}`
/// - `resultAllowsAccess {result}` validates a status result before checking access.
/// - `validateIdentifier {identifier}`
/// - `builtIns`
/// - `validateResult {result}`
/// - `admitAccess {platform,permission,request:bool,options?}` returns `{options}` when
///   admitted or `{result:status result}` for an unsupported or mismatched request.
///   Omitted options use the platform default. No host provider is called.
/// - `admitSettings {platform,permission,options?}` returns `{capability}` when
///   a destination exists or `{result:boolean Settings result}` for an unsupported
///   operation or options for a different permission. Admission returns a
///   destination or result without opening Settings.
/// - `validateSettingsResult {result}` checks a Settings result with a boolean supported value.
/// - `storeBatchLimit` returns the advisory entry limit for track and apply arrays.
///
/// Core operations have no OS effects or implicit prompting. Explicit Windows
/// operations run on the calling thread outside any store lock and are unavailable
/// on other platforms. The operations are listed below.
///
/// - `windowsStatus {permission,options}` returns a status result.
/// - `windowsRequest {permission,options}` returns `{result:status result}`.
///   Desktop Windows reports direct requests as unsupported without calling the OS.
/// - `windowsOpenSettings {permission,options}` returns a boolean Settings result.
///   Calling it explicitly opens the Settings destination for a supported capability.
///
/// Panic unwinding is contained. Allocation exhaustion is subject to the process
/// allocator and is not recoverable.
///
/// # Safety
/// A nonnull input must remain readable for len bytes until this call returns.
/// The returned result owns its bytes and must be freed once, after copying its view.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn system_permissions_call(
    data: *const u8,
    len: usize,
) -> *mut SystemPermissionsResult {
    contained(|| dispatch(unsafe { input(data, len)? }))
}

/// Reads the result status. A null result returns status 1.
///
/// # Safety
/// Result is null or a live result allocated by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn system_permissions_result_status(
    result: *const SystemPermissionsResult,
) -> u32 {
    if result.is_null() || !result.is_aligned() {
        return 1;
    }
    unsafe { (*result).status }
}

/// Borrows the result bytes. A null result returns a null pointer.
///
/// # Safety
/// Result is null or live. Copy the length-delimited bytes before calling
/// result_free. No NUL terminator is supplied.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn system_permissions_result_data(
    result: *const SystemPermissionsResult,
) -> *const u8 {
    if result.is_null() || !result.is_aligned() {
        return std::ptr::null();
    }
    unsafe { (*result).data.as_ptr() }
}

/// Reads the byte length. A null result returns zero.
///
/// # Safety
/// Result is null or a live result allocated by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn system_permissions_result_len(
    result: *const SystemPermissionsResult,
) -> usize {
    if result.is_null() || !result.is_aligned() {
        return 0;
    }
    unsafe { (*result).data.len() }
}

/// # Safety
/// Result is null or exclusively owned, live, allocated by this library and freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn system_permissions_result_free(result: *mut SystemPermissionsResult) {
    if !result.is_null() && result.is_aligned() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(result) })));
    }
}

/// Creates an empty store.
#[unsafe(no_mangle)]
pub extern "C" fn system_permissions_store_new() -> *mut SystemPermissionsStore {
    catch_unwind(|| {
        Box::into_raw(Box::new(SystemPermissionsStore {
            state: Mutex::new(Store::new()),
        }))
    })
    .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// Store is null or exclusively owned/live, with no concurrent calls or outstanding users.
/// Other store operations may be concurrent; freeing the store must be externally synchronized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn system_permissions_store_free(store: *mut SystemPermissionsStore) {
    if !store.is_null() && store.is_aligned() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(store) })));
    }
}

/// Dispatches a store request using the same JSON and owned result contract as
/// `system_permissions_call`. Calls serialize access. No callbacks or OS effects
/// run under lock.
///
/// Supported store operations and request fields follow.
///
/// - `track {permissions}` returns `{values:[{permission,result}]}`. It replaces
///   the set, preserves retained entries and deduplicates in order.
/// - `get {permission}` returns a result or null.
/// - `begin {permission}` returns `{token:uint64 or null}`.
/// - `recordObservation {permission,result}` returns `{result,previousResult}`
///   or null for an untracked permission. `previousResult` is null for an initial
///   or unchanged sample. Poll samples leave admitted work and stored status intact.
/// - `admit {permission,kind:"refresh"|"request"}` returns `{token:uint64 or null}`.
/// - `admitScoped {permission,options,kind:"refresh"|"request",cancelled:bool}`
///   returns `{kind:"untracked"|"invalidOptions"|"isolated"|"suppressed"}` or
///   `{kind:"stored",token:uint64}`.
/// - `admitAllRefreshes` returns `[{permission,token:uint64}]` in tracking order.
/// - `finish {token:uint64}` returns `{finished:bool}`.
/// - `apply {updates:[{permission,token,result}],cancelled:bool}` returns
///   `{changed,accepted}`.
/// - `snapshot` returns `{values:[{permission,result}]}`.
///
/// Inconsistent metadata or duplicate update identities fail atomically.
/// `begin` is explicit manual ordering. It supersedes prior work and clears
/// typed request priority, even when its eventual apply is cancelled. Typed
/// admission validates the descriptor and metadata before suppressing a refresh
/// while the latest typed request is active. A typed request always supersedes
/// prior work. A null admission token denotes suppression or an untracked
/// permission. Use `get` to distinguish them. All reservations share one
/// store-global token sequence.
///
/// `admitScoped` validates options before reserving. Add-only Photos operations
/// identify an isolated scope with no token. Cancellation suppresses stored work.
/// Adapters skip provider calls for cancelled operations. `admitAllRefreshes`
/// skips pending requests and admits the remaining scopes together. Token
/// exhaustion leaves all existing work unchanged.
///
/// `finish` retires only matching current work and preserves its result. It never
/// revives earlier tokens. A stale or missing nonzero token returns false and
/// zero fails. `apply` keeps tokens reusable until superseded or finished, even
/// after a cancelled apply. Adapters finish on every terminal path. `accepted`
/// counts matching tokens, including unchanged values. Untracked or stale
/// results are filtered after full validation. Tokens are scoped to their store.
///
/// # Safety
/// Store is live for the entire call. Input is readable for len bytes. The result
/// is owned and independent of both inputs and outlives the store.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn system_permissions_store_call(
    store: *mut SystemPermissionsStore,
    data: *const u8,
    len: usize,
) -> *mut SystemPermissionsResult {
    contained(|| {
        if store.is_null() || !store.is_aligned() {
            return Err(Error::InvalidBuffer);
        }
        let request = parse_store(unsafe { input(data, len)? })?;
        // The mutable state is only accessed through this mutex; no &mut aliases to the handle.
        let mut state = unsafe { &*store }
            .state
            .lock()
            .map_err(|_| Error::StorePoisoned)?;
        state.dispatch(request)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unwinding_is_a_typed_error_and_poison_does_not_resume_mutation() {
        unsafe {
            let result = contained(|| panic!("owned test panic"));
            assert_eq!(system_permissions_result_status(result), 1);
            let bytes = std::slice::from_raw_parts(
                system_permissions_result_data(result),
                system_permissions_result_len(result),
            );
            assert_eq!(bytes, br#"{"error":"panic"}"#);
            system_permissions_result_free(result);
            let store = system_permissions_store_new();
            let _ = catch_unwind(AssertUnwindSafe(|| {
                let _guard = (*store).state.lock().unwrap();
                panic!("owned poison test");
            }));
            let request = br#"{"op":"snapshot"}"#;
            let result = system_permissions_store_call(store, request.as_ptr(), request.len());
            assert_eq!((*result).data, br#"{"error":"storePoisoned"}"#);
            system_permissions_result_free(result);
            system_permissions_store_free(store);
        }
    }
}
