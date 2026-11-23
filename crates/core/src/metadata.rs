use crate::{
    Capability, Descriptor, Error, OperationError, Options, PermissionResult, PhotoAccessLevel,
    Platform, SettingsResult,
};
use serde::Serialize;

/// Stable built-in identifiers, including target-dependent Apple Events.
pub const BUILT_IN_IDS: [&str; 24] = [
    "accessibility",
    "input_monitoring",
    "screen_recording",
    "camera",
    "microphone",
    "contacts",
    "calendars",
    "reminders",
    "photos",
    "speech_recognition",
    "notifications",
    "location",
    "bluetooth",
    "local_network",
    "media_library",
    "system_audio_capture",
    "desktop_folder",
    "documents_folder",
    "downloads_folder",
    "network_volumes",
    "removable_volumes",
    "file_provider_domain",
    "full_disk_access",
    "automation",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    pub default_options: Options,
    pub usage_description_keys: Vec<String>,
    pub capability: Capability,
}

/// Decision for a direct status check or request without running its provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum AccessAdmission {
    Proceed { options: Options },
    Complete { result: PermissionResult },
}

/// Resolves admission and the options to pass to a host provider.
/// Omitted options use the metadata default; explicit None remains explicit.
pub fn admit_access(
    permission: &Descriptor,
    platform: Platform,
    request: bool,
    options: Option<&Options>,
) -> Result<AccessAdmission, Error> {
    let permission = permission.validated()?;
    let metadata = match validated_metadata(permission, platform, options.unwrap_or(&Options::None))
    {
        Ok(metadata) => metadata,
        Err(Error::InvalidOptions) => {
            return Ok(AccessAdmission::Complete {
                result: PermissionResult::Failed {
                    error: OperationError::InvalidOptions,
                },
            });
        }
        Err(error) => return Err(error),
    };
    let capability = metadata.capability;
    let supported = if request {
        capability.supports_request
    } else {
        capability.supports_status_check
    };
    Ok(if supported {
        AccessAdmission::Proceed {
            options: options.cloned().unwrap_or(metadata.default_options),
        }
    } else {
        AccessAdmission::Complete {
            result: PermissionResult::Unsupported { capability },
        }
    })
}

/// Outcome of resolving an explicit Settings request without opening a destination.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum SettingsAdmission {
    Open { capability: Capability },
    Complete { result: SettingsResult },
}

/// Validate and canonicalize Settings input before an adapter starts any effects.
pub fn admit_settings(
    permission: &Descriptor,
    platform: Platform,
    options: Option<&Options>,
) -> Result<SettingsAdmission, Error> {
    let permission = permission.validated()?;
    let options = options.unwrap_or(&Options::None);
    let capability = match validated_metadata(permission, platform, options) {
        Ok(metadata) => metadata.capability,
        Err(Error::InvalidOptions) => {
            return Ok(SettingsAdmission::Complete {
                result: SettingsResult::Failed {
                    error: OperationError::InvalidOptions,
                },
            });
        }
        Err(error) => return Err(error),
    };
    if capability.system_settings_url.is_none() {
        return Ok(SettingsAdmission::Complete {
            result: SettingsResult::Unsupported { capability },
        });
    }
    Ok(SettingsAdmission::Open { capability })
}

/// Platform-specific capability, never an observed authorization state.
/// Custom metadata belongs to the host and is not remapped between platforms.
pub fn metadata(
    permission: &Descriptor,
    platform: Platform,
    options: Option<&Options>,
) -> Result<Metadata, Error> {
    let permission = permission.validated()?;
    validated_metadata(permission, platform, options.unwrap_or(&Options::None))
}

fn validated_metadata(
    permission: Descriptor,
    platform: Platform,
    options: &Options,
) -> Result<Metadata, Error> {
    options.validate_for_validated(&permission)?;
    if let Some(custom) = permission.custom {
        return Ok(Metadata {
            default_options: Options::None,
            usage_description_keys: custom.usage_description_keys,
            capability: custom.capability,
        });
    }
    let default_options = match permission.id.as_str() {
        "notifications" => Options::Notifications {
            notification_options: 7,
        },
        "photos" => Options::Photos {
            photo_access_level: PhotoAccessLevel::ReadWrite,
        },
        _ => Options::None,
    };
    if platform == Platform::Windows {
        // The Windows adapter implements these AppCapability APIs. Runtime availability
        // (including package identity) remains a native result, not an inferred grant.
        // Other macOS domains deliberately have no invented Windows TCC counterpart.
        let url = match permission.id.as_str() {
            "camera" => Some("ms-settings:privacy-webcam"),
            "microphone" => Some("ms-settings:privacy-microphone"),
            "location" => Some("ms-settings:privacy-location"),
            _ => None,
        };
        let direct = url.is_some();
        return Ok(Metadata {
            default_options,
            usage_description_keys: vec![],
            capability: Capability {
                supports_status_check: direct,
                supports_request: direct,
                system_settings_url: url.map(str::to_owned),
                requires_relaunch: false,
            },
        });
    }
    let (direct, pane, usage_key, relaunch) = match permission.id.as_str() {
        "accessibility" => (true, "Accessibility", None, false),
        "input_monitoring" => (true, "ListenEvent", None, true),
        "screen_recording" => (true, "ScreenCapture", None, true),
        "camera" => (true, "Camera", Some("NSCameraUsageDescription"), false),
        "microphone" => (
            true,
            "Microphone",
            Some("NSMicrophoneUsageDescription"),
            false,
        ),
        "contacts" => (true, "Contacts", Some("NSContactsUsageDescription"), false),
        "calendars" => (
            true,
            "Calendars",
            Some("NSCalendarsFullAccessUsageDescription"),
            false,
        ),
        "reminders" => (
            true,
            "Reminders",
            Some("NSRemindersFullAccessUsageDescription"),
            false,
        ),
        "photos" => (
            true,
            "Photos",
            Some(
                if matches!(
                    options,
                    Options::Photos {
                        photo_access_level: PhotoAccessLevel::AddOnly
                    }
                ) {
                    "NSPhotoLibraryAddUsageDescription"
                } else {
                    "NSPhotoLibraryUsageDescription"
                },
            ),
            false,
        ),
        "speech_recognition" => (
            true,
            "SpeechRecognition",
            Some("NSSpeechRecognitionUsageDescription"),
            false,
        ),
        "notifications" => (true, "", None, false),
        "location" => (
            false,
            "LocationServices",
            Some("NSLocationUsageDescription"),
            false,
        ),
        "bluetooth" => (
            false,
            "Bluetooth",
            Some("NSBluetoothAlwaysUsageDescription"),
            false,
        ),
        "local_network" => (
            false,
            "LocalNetwork",
            Some("NSLocalNetworkUsageDescription"),
            false,
        ),
        "media_library" => (false, "Media", Some("NSAppleMusicUsageDescription"), false),
        "system_audio_capture" => (
            false,
            "SystemAudioRecording",
            Some("NSAudioCaptureUsageDescription"),
            false,
        ),
        "desktop_folder" => (
            false,
            "FilesAndFolders",
            Some("NSDesktopFolderUsageDescription"),
            false,
        ),
        "documents_folder" => (
            false,
            "FilesAndFolders",
            Some("NSDocumentsFolderUsageDescription"),
            false,
        ),
        "downloads_folder" => (
            false,
            "FilesAndFolders",
            Some("NSDownloadsFolderUsageDescription"),
            false,
        ),
        "network_volumes" => (
            false,
            "FilesAndFolders",
            Some("NSNetworkVolumesUsageDescription"),
            false,
        ),
        "removable_volumes" => (
            false,
            "FilesAndFolders",
            Some("NSRemovableVolumesUsageDescription"),
            false,
        ),
        "file_provider_domain" => (
            false,
            "FilesAndFolders",
            Some("NSFileProviderDomainUsageDescription"),
            false,
        ),
        "full_disk_access" => (false, "AllFiles", None, true),
        "automation" => (
            true,
            "Automation",
            Some("NSAppleEventsUsageDescription"),
            false,
        ),
        _ => return Err(Error::InvalidDescriptor),
    };
    let url = if permission.id == "notifications" {
        "x-apple.systempreferences:com.apple.preference.notifications?Notifications".to_owned()
    } else {
        format!("x-apple.systempreferences:com.apple.preference.security?Privacy_{pane}")
    };
    Ok(Metadata {
        default_options,
        usage_description_keys: usage_key.map(str::to_owned).into_iter().collect(),
        capability: Capability {
            supports_status_check: direct,
            supports_request: direct,
            system_settings_url: Some(url),
            requires_relaunch: relaunch,
        },
    })
}
