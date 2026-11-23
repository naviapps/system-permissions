//! Windows effects for the current process. Construction and metadata never prompt.
//!
//! AppCapability is available from Windows 10 1903. This adapter conservatively requires
//! package identity; it does not infer grants for unpackaged desktop processes. Packaged
//! callers must declare webcam, microphone or location as appropriate. NotDeclaredByApp
//! maps to Restricted, independently of the user's privacy choice. Accessibility, input
//! injection and screen capture have no universal privacy toggle represented here.
//!
//! Desktop Windows hosts may open the privacy Settings page. Direct consent requests
//! are unsupported because the WinRT consent UI requires a UWP CoreWindow.
#[cfg(any(windows, test))]
use permissions_core::Status;
use permissions_core::{
    Descriptor, OperationError, Options, PermissionResult, Platform, SettingsAdmission,
    SettingsResult, admit_settings, metadata,
};

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

fn preflight(permission: &Descriptor, options: &Options) -> Result<&'static str, PermissionResult> {
    if let Some(name) = capability_name(permission) {
        return options
            .validate_for(permission)
            .map(|()| name)
            .map_err(|_| failed(OperationError::InvalidOptions));
    }
    Err(
        match metadata(permission, Platform::Windows, Some(options)) {
            Ok(value) => PermissionResult::Unsupported {
                capability: value.capability,
            },
            Err(_) => failed(OperationError::InvalidOptions),
        },
    )
}

/// Nonprompting privacy status for the current process only.
pub fn status(permission: &Descriptor, options: &Options) -> PermissionResult {
    let name = match preflight(permission, options) {
        Ok(name) => name,
        Err(result) => return result,
    };
    #[cfg(windows)]
    return native::status(name);
    #[cfg(not(windows))]
    {
        let _ = name;
        failed(OperationError::ApiUnavailable)
    }
}

/// Reports that this desktop adapter cannot request consent, without invoking the OS.
pub fn request(permission: &Descriptor, options: &Options) -> PermissionResult {
    match metadata(permission, Platform::Windows, Some(options)) {
        Ok(value) => {
            let mut capability = value.capability;
            capability.supports_request = false;
            PermissionResult::Unsupported { capability }
        }
        Err(_) => failed(OperationError::InvalidOptions),
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
    fn unsupported_desktop_privileges_do_not_report_status() {
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
    fn desktop_requests_never_prompt_and_preserve_settings() {
        for (id, page) in [
            ("camera", "ms-settings:privacy-webcam"),
            ("microphone", "ms-settings:privacy-microphone"),
            ("location", "ms-settings:privacy-location"),
        ] {
            let permission = Descriptor::built_in(id).unwrap();
            let PermissionResult::Unsupported { capability } = request(&permission, &Options::None)
            else {
                panic!("Windows desktop must report that direct requests are unsupported");
            };
            assert!(!capability.supports_request);
            assert!(capability.supports_status_check);
            assert_eq!(capability.system_settings_url.as_deref(), Some(page));
        }
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
        assert_eq!(
            request(&permission, &options),
            failed(OperationError::InvalidOptions)
        );
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
