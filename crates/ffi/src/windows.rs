//! Explicit Windows calls execute on the calling thread, outside the Store mutex.
use permissions_core::{Descriptor, Error, Options};
#[cfg(not(windows))]
use permissions_core::{OperationError, PermissionResult, SettingsResult};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", deny_unknown_fields)]
pub(super) enum NativeCommand {
    #[serde(rename = "windowsStatus")]
    Status {
        permission: Descriptor,
        options: Options,
    },
    #[serde(rename = "windowsRequest")]
    Request {
        permission: Descriptor,
        options: Options,
    },
    #[serde(rename = "windowsOpenSettings")]
    OpenSettings {
        permission: Descriptor,
        options: Options,
    },
}

fn validate(permission: Descriptor, options: &Options) -> Result<Descriptor, Error> {
    let permission = permission.validated()?;
    options.validate_for(&permission)?;
    Ok(permission)
}

#[cfg(not(windows))]
fn failed(error: OperationError) -> PermissionResult {
    PermissionResult::Failed { error }
}

impl NativeCommand {
    pub(super) fn dispatch(self) -> Result<Value, Error> {
        Ok(match self {
            Self::Status {
                permission,
                options,
            } => {
                let permission = validate(permission, &options)?;
                #[cfg(windows)]
                {
                    json!(system_permissions_windows::status(&permission, &options))
                }
                #[cfg(not(windows))]
                {
                    let _ = permission;
                    json!(failed(OperationError::ApiUnavailable))
                }
            }
            Self::Request {
                permission,
                options,
            } => {
                let permission = validate(permission, &options)?;
                #[cfg(windows)]
                {
                    json!({"result": system_permissions_windows::request(&permission, &options)})
                }
                #[cfg(not(windows))]
                {
                    let _ = permission;
                    json!({"result":failed(OperationError::ApiUnavailable)})
                }
            }
            Self::OpenSettings {
                permission,
                options,
            } => {
                let permission = validate(permission, &options)?;
                #[cfg(windows)]
                {
                    json!(system_permissions_windows::open_settings(
                        &permission,
                        &options
                    ))
                }
                #[cfg(not(windows))]
                {
                    let _ = permission;
                    json!(SettingsResult::Failed {
                        error: OperationError::ApiUnavailable
                    })
                }
            }
        })
    }
}
