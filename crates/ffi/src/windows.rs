//! Explicit Windows calls execute on the calling thread, outside the Store mutex.
#[cfg(not(windows))]
use permissions_core::SettingsResult;
use permissions_core::{Descriptor, Error, OperationError, Options, PermissionResult};
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
    Start {
        permission: Descriptor,
        options: Options,
    },
    #[serde(rename = "windowsPollRequest")]
    Poll { token: u64 },
    #[serde(rename = "windowsCancelRequest")]
    Cancel { token: u64 },
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

fn token_valid(token: u64) -> Result<(), Error> {
    if token == 0 {
        Err(Error::InvalidToken)
    } else {
        Ok(())
    }
}

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
            Self::Start {
                permission,
                options,
            } => {
                let permission = validate(permission, &options)?;
                #[cfg(windows)]
                {
                    use system_permissions_windows::RequestStart;
                    match system_permissions_windows::request(&permission, &options) {
                        RequestStart::Complete(result) => json!({"result":result}),
                        RequestStart::Pending(token) => json!({"token":token}),
                    }
                }
                #[cfg(not(windows))]
                {
                    let _ = permission;
                    json!({"result":failed(OperationError::ApiUnavailable)})
                }
            }
            Self::Poll { token } => {
                token_valid(token)?;
                #[cfg(windows)]
                {
                    match system_permissions_windows::poll_request(token) {
                        Ok(Some(result)) => json!({"result":result}),
                        Ok(None) => json!({}),
                        Err(error) => json!({"result": failed(error)}),
                    }
                }
                #[cfg(not(windows))]
                {
                    json!({"result":failed(OperationError::ApiUnavailable)})
                }
            }
            Self::Cancel { token } => {
                token_valid(token)?;
                #[cfg(windows)]
                {
                    system_permissions_windows::cancel_request(token).map_err(Error::from)?;
                    json!({})
                }
                #[cfg(not(windows))]
                {
                    return Err(Error::ApiUnavailable);
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
