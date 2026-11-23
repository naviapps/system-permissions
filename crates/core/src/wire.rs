use crate::{
    BUILT_IN_IDS, Descriptor, Error, Options, PermissionResult, Platform, SettingsResult, Status,
    Update, WorkKind, admit_access, admit_settings, metadata, validate_identifier,
};
use serde::Deserialize;
use serde_json::{Value, json};

pub const MAX_INPUT_BYTES: usize = 1024 * 1024;
pub const MAX_PERMISSIONS: usize = 1024;

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", deny_unknown_fields)]
pub enum Request {
    Metadata {
        platform: Platform,
        permission: Descriptor,
        #[serde(default, deserialize_with = "crate::model::present")]
        options: Option<Options>,
    },
    AdmitAccess {
        platform: Platform,
        permission: Descriptor,
        request: bool,
        #[serde(default, deserialize_with = "crate::model::present")]
        options: Option<Options>,
    },
    AdmitSettings {
        platform: Platform,
        permission: Descriptor,
        #[serde(default, deserialize_with = "crate::model::present")]
        options: Option<Options>,
    },
    ValidateDescriptor {
        permission: Descriptor,
    },
    ValidateOptions {
        permission: Descriptor,
        options: Options,
    },
    AllowsAccess {
        status: Status,
    },
    ResultAllowsAccess {
        result: PermissionResult,
    },
    ValidateIdentifier {
        identifier: String,
    },
    ValidateUsageDescriptionKeys {
        keys: Vec<String>,
    },
    StoreBatchLimit {},
    BuiltIns {},
    ValidateResult {
        result: PermissionResult,
    },
    ValidateSettingsResult {
        result: SettingsResult,
    },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", deny_unknown_fields)]
pub enum StoreRequest {
    Track {
        permissions: Vec<Descriptor>,
    },
    Get {
        permission: Descriptor,
    },
    RecordObservation {
        permission: Descriptor,
        result: PermissionResult,
    },
    Begin {
        permission: Descriptor,
    },
    Admit {
        permission: Descriptor,
        kind: WorkKind,
    },
    AdmitScoped {
        permission: Descriptor,
        options: Options,
        kind: WorkKind,
        cancelled: bool,
    },
    AdmitAllRefreshes {},
    Finish {
        token: u64,
    },
    Apply {
        updates: Vec<Update>,
        cancelled: bool,
    },
    Snapshot {},
}

/// Shared strict, bounded UTF-8 JSON decoding for platform-specific command extensions.
pub fn decode<T: serde::de::DeserializeOwned>(input: &[u8]) -> Result<T, Error> {
    if input.len() > MAX_INPUT_BYTES {
        return Err(Error::InputTooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| Error::InvalidUtf8)?;
    serde_json::from_str(text).map_err(|_| Error::InvalidJson)
}
pub fn parse(input: &[u8]) -> Result<Request, Error> {
    decode(input)
}
pub fn parse_store(input: &[u8]) -> Result<StoreRequest, Error> {
    decode(input)
}

impl Request {
    pub fn dispatch(self) -> Result<Value, Error> {
        Ok(match self {
            Self::Metadata {
                platform,
                permission,
                options,
            } => json!(metadata(&permission, platform, options.as_ref())?),
            Self::AdmitAccess {
                platform,
                permission,
                request,
                options,
            } => json!(admit_access(
                &permission,
                platform,
                request,
                options.as_ref()
            )?),
            Self::AdmitSettings {
                platform,
                permission,
                options,
            } => json!(admit_settings(&permission, platform, options.as_ref())?),
            Self::ValidateDescriptor { permission } => json!(permission.validated()?),
            Self::ValidateOptions {
                permission,
                options,
            } => {
                options.validate_for(&permission)?;
                json!(options)
            }
            Self::AllowsAccess { status } => json!(status.allows_access()),
            Self::ResultAllowsAccess { result } => {
                result.validate()?;
                json!(result.allows_access())
            }
            Self::ValidateIdentifier { identifier } => {
                if identifier.len() > crate::model::MAX_TEXT {
                    return Err(Error::LimitExceeded);
                }
                match validate_identifier(&identifier) {
                    Some(reason) => json!({"error": reason}),
                    None => json!({}),
                }
            }
            Self::ValidateUsageDescriptionKeys { mut keys } => {
                crate::model::canonicalize_usage_description_keys(&mut keys)?;
                json!(keys)
            }
            Self::StoreBatchLimit {} => json!(MAX_PERMISSIONS),
            Self::BuiltIns {} => json!(
                BUILT_IN_IDS
                    .iter()
                    .filter(|&&id| id != "automation")
                    .map(|id| Descriptor::built_in(id))
                    .collect::<Result<Vec<_>, _>>()?
            ),
            Self::ValidateResult { result } => {
                result.validate()?;
                json!(result)
            }
            Self::ValidateSettingsResult { result } => {
                result.validate()?;
                json!(result)
            }
        })
    }
}

pub fn call(input: &[u8]) -> Result<Value, Error> {
    parse(input)?.dispatch()
}
