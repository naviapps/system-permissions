//! Windows effects for the current process. Construction and metadata never prompt.
//!
//! AppCapability is available from Windows 10 1903. This adapter conservatively requires
//! package identity; it does not infer grants for unpackaged desktop processes. Packaged
//! callers must declare webcam, microphone or location as appropriate. NotDeclaredByApp
//! maps to Restricted, independently of the user's privacy choice. Accessibility, input
//! injection and screen capture have no universal privacy toggle represented here.
//!
//! RequestAccessAsync must start on the host's existing STA UI thread. `request` returns
//! promptly; callers poll off the UI thread and always cancel abandoned tokens. No message
//! pumping, elevation, UIAccess changes or UIPI bypass is performed by this crate.
#[cfg(any(windows, test))]
use permissions_core::Status;
use permissions_core::{
    Descriptor, OperationError, Options, PermissionResult, Platform, SettingsAdmission,
    SettingsResult, admit_settings, metadata,
};

#[derive(Debug)]
pub enum RequestStart {
    Complete(PermissionResult),
    Pending(u64),
}

fn failed(error: OperationError) -> PermissionResult {
    PermissionResult::Failed { error }
}

fn capability_name(permission: &Descriptor) -> Option<&'static str> {
    if permission.custom.is_some() {
        return None;
    }
    match permission.id.as_str() {
        "camera" => Some("webcam"),
        "microphone" => Some("microphone"),
        "location" => Some("location"),
        _ => None,
    }
}

// The numerical values are the published AppCapabilityAccessStatus contract. Unknown
// future values stay unknown; an absent declaration never means the user granted access.
#[cfg(any(windows, test))]
fn access_status(value: i32) -> Status {
    match value {
        0 | 1 => Status::Restricted,
        2 => Status::Denied,
        3 => Status::NotDetermined,
        4 => Status::Granted,
        _ => Status::Unknown,
    }
}

fn preflight(permission: &Descriptor, options: &Options) -> Option<PermissionResult> {
    if options.validate_for(permission).is_err() {
        return Some(failed(OperationError::InvalidOptions));
    }
    if capability_name(permission).is_none() {
        return Some(unsupported(permission, options));
    }
    None
}

fn unsupported(permission: &Descriptor, options: &Options) -> PermissionResult {
    match metadata(permission, Platform::Windows, Some(options)) {
        Ok(value) => PermissionResult::Unsupported {
            capability: value.capability,
        },
        Err(_) => failed(OperationError::InvalidOptions),
    }
}

/// Nonprompting privacy status for the current process only.
pub fn status(permission: &Descriptor, options: &Options) -> PermissionResult {
    if let Some(result) = preflight(permission, options) {
        return result;
    }
    #[cfg(windows)]
    return native::status(capability_name(permission).expect("preflight"));
    #[cfg(not(windows))]
    failed(OperationError::ApiUnavailable)
}

/// Explicit user request. Call on the application's existing STA UI thread.
/// A pending token must be polled until complete or cancelled, including on host disposal.
pub fn request(permission: &Descriptor, options: &Options) -> RequestStart {
    if let Some(result) = preflight(permission, options) {
        return RequestStart::Complete(result);
    }
    #[cfg(windows)]
    return native::request(capability_name(permission).expect("preflight"));
    #[cfg(not(windows))]
    RequestStart::Complete(failed(OperationError::ApiUnavailable))
}

/// Returns None only while a valid owned request is in progress. Completion consumes it.
pub fn poll_request(token: u64) -> Result<Option<PermissionResult>, OperationError> {
    #[cfg(windows)]
    return native::poll_request(token);
    #[cfg(not(windows))]
    {
        let _ = token;
        Err(OperationError::ApiUnavailable)
    }
}

/// Cancels and releases an abandoned request. This cannot undo an OS prompt already shown.
pub fn cancel_request(token: u64) -> Result<(), OperationError> {
    #[cfg(windows)]
    return native::cancel_request(token);
    #[cfg(not(windows))]
    {
        let _ = token;
        Err(OperationError::ApiUnavailable)
    }
}

/// Opens only the built-in permission's shared Rust settings URL, on explicit host call.
/// A successful launch returns true and is never stored as permission status.
pub fn open_settings(permission: &Descriptor, options: &Options) -> SettingsResult {
    let capability = match admit_settings(permission, Platform::Windows, Some(options)) {
        Ok(SettingsAdmission::Open { capability, .. }) => capability,
        Ok(SettingsAdmission::Complete { result }) => return result,
        Err(_) => {
            return SettingsResult::Failed {
                error: OperationError::InvalidOptions,
            };
        }
    };
    if permission.custom.is_some() {
        return SettingsResult::Unsupported { capability };
    }
    let Some(url) = capability.system_settings_url else {
        return SettingsResult::Unsupported { capability };
    };
    if !url.starts_with("ms-settings:") || url.contains('\0') {
        return SettingsResult::Failed {
            error: OperationError::OpenFailed,
        };
    }
    #[cfg(windows)]
    return native::open_settings(&url);
    #[cfg(not(windows))]
    SettingsResult::Failed {
        error: OperationError::ApiUnavailable,
    }
}

#[cfg(windows)]
mod native;
#[cfg(any(windows, test))]
mod requests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_all_access_states_without_inventing_grants() {
        assert_eq!(access_status(0), Status::Restricted);
        assert_eq!(access_status(1), Status::Restricted);
        assert_eq!(access_status(2), Status::Denied);
        assert_eq!(access_status(3), Status::NotDetermined);
        assert_eq!(access_status(4), Status::Granted);
        assert_eq!(access_status(5), Status::Unknown);
        assert_eq!(access_status(-1), Status::Unknown);
    }

    #[test]
    fn unsupported_desktop_privileges_never_call_an_os_request() {
        for id in [
            "accessibility",
            "input_monitoring",
            "screen_recording",
            "full_disk_access",
        ] {
            let permission = Descriptor::built_in(id).unwrap();
            assert!(matches!(
                status(&permission, &Options::None),
                PermissionResult::Unsupported { .. }
            ));
            assert!(matches!(
                request(&permission, &Options::None),
                RequestStart::Complete(PermissionResult::Unsupported { .. })
            ));
        }
        let automation = Descriptor {
            id: "automation".into(),
            target_application: Some("com.example.fixture".into()),
            custom: None,
        };
        assert!(matches!(
            status(&automation, &Options::None),
            PermissionResult::Unsupported { .. }
        ));
    }

    #[test]
    fn invalid_options_stop_before_any_effect() {
        let permission = Descriptor::built_in("camera").unwrap();
        let options = Options::Notifications {
            notification_options: 1,
        };
        assert_eq!(
            status(&permission, &options),
            failed(OperationError::InvalidOptions)
        );
        assert_eq!(
            open_settings(&permission, &options),
            SettingsResult::Failed {
                error: OperationError::InvalidOptions
            }
        );
        assert!(matches!(
            request(&permission, &options),
            RequestStart::Complete(PermissionResult::Failed {
                error: OperationError::InvalidOptions
            })
        ));
    }

    #[test]
    fn capability_names_are_exact_windows_manifest_names() {
        for (id, name) in [
            ("camera", "webcam"),
            ("microphone", "microphone"),
            ("location", "location"),
        ] {
            assert_eq!(
                capability_name(&Descriptor::built_in(id).unwrap()),
                Some(name)
            );
        }
    }
}
