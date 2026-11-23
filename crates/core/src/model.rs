use crate::metadata::BUILT_IN_IDS;
use serde::de::{MapAccess, Visitor, value::MapAccessDeserializer};
use serde::{Deserialize, Deserializer, Serialize};

pub(crate) const MAX_TEXT: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum IdentifierValidationError {
    Empty,
    Reserved,
    MissingNamespace,
    EmptySegment,
    InvalidSegmentBoundary,
    InvalidCharacter,
}

/// Protocol errors contain stable codes, never arbitrary input or native error text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "error", rename_all = "camelCase")]
pub enum Error {
    InvalidJson,
    InvalidUtf8,
    InvalidBuffer,
    InputTooLarge,
    LimitExceeded,
    InvalidIdentifier { reason: IdentifierValidationError },
    InvalidDescriptor,
    InvalidTargetApplication,
    InvalidOptions,
    OpenFailed,
    ApiUnavailable,
    InvalidResult,
    InconsistentMetadata,
    DuplicateUpdate,
    InvalidToken,
    TokenExhausted,
    StorePoisoned,
    Panic,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}

/// Reports exactly the old custom-identifier reasons, in the same precedence.
pub fn validate_identifier(id: &str) -> Option<IdentifierValidationError> {
    use IdentifierValidationError::*;
    if id.is_empty() {
        return Some(Empty);
    }
    if BUILT_IN_IDS.contains(&id) {
        return Some(Reserved);
    }
    if !id
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"_-.".contains(&b))
    {
        return Some(InvalidCharacter);
    }
    if !id.contains('.') {
        return Some(MissingNamespace);
    }
    let segments: Vec<_> = id.split('.').collect();
    if segments.iter().any(|s| s.is_empty()) {
        return Some(EmptySegment);
    }
    let boundary = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    if segments
        .iter()
        .any(|s| !boundary(s.as_bytes()[0]) || !boundary(s.as_bytes()[s.len() - 1]))
    {
        return Some(InvalidSegmentBoundary);
    }
    None
}

/// Apple Events takes an exact bundle/application identifier, never an executable or URL.
/// Uppercase ASCII is allowed (e.g. com.apple.TextEdit); inputs are not normalized.
pub fn validate_application_identifier(id: &str) -> bool {
    if id.is_empty() || id.len() > MAX_TEXT || !id.contains('.') {
        return false;
    }
    id.split('.').all(|s| {
        !s.is_empty()
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && s.as_bytes()[0].is_ascii_alphanumeric()
            && s.as_bytes()[s.len() - 1].is_ascii_alphanumeric()
    })
}

pub(crate) fn text_valid(s: &str) -> bool {
    !s.is_empty() && s.len() <= MAX_TEXT && !s.chars().any(char::is_control)
}

/// Validates usage description keys and preserves the first occurrence of each exact value.
pub(crate) fn canonicalize_usage_description_keys(keys: &mut Vec<String>) -> Result<(), Error> {
    if keys.len() > 64 {
        return Err(Error::LimitExceeded);
    }
    if keys.iter().any(|key| !text_valid(key) || key.trim() != key) {
        return Err(Error::InvalidDescriptor);
    }
    let mut seen = std::collections::HashSet::new();
    keys.retain(|key| seen.insert(key.clone()));
    Ok(())
}

// Optional means absent; explicit null is a malformed payload rather than absence.
pub(crate) fn present<'de, D, T>(d: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(d).map(Some)
}

// A derived struct visitor accepts positional arrays as well as maps.
pub(crate) fn object<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<T, D::Error> {
    struct ObjectVisitor<T>(std::marker::PhantomData<T>);

    impl<'de, T: Deserialize<'de>> Visitor<'de> for ObjectVisitor<T> {
        type Value = T;

        fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter.write_str("a JSON object")
        }

        fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<T, A::Error> {
            T::deserialize(MapAccessDeserializer::new(map))
        }
    }

    deserializer.deserialize_map(ObjectVisitor(std::marker::PhantomData))
}

fn present_object<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    d: D,
) -> Result<Option<T>, D::Error> {
    object(d).map(Some)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Macos,
    Windows,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Capability {
    pub supports_status_check: bool,
    pub supports_request: bool,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub system_settings_url: Option<String>,
    pub requires_relaunch: bool,
}
impl Capability {
    pub fn validate(&self) -> Result<(), Error> {
        if let Some(url) = &self.system_settings_url {
            let Some((scheme, remainder)) = url.split_once(':') else {
                return Err(Error::InvalidDescriptor);
            };
            if !text_valid(url)
                || url.chars().any(char::is_whitespace)
                || remainder.is_empty()
                || !scheme
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphabetic)
                || !scheme
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"+-.".contains(&b))
            {
                return Err(Error::InvalidDescriptor);
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Custom {
    #[serde(deserialize_with = "object")]
    pub capability: Capability,
    pub usage_description_keys: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Descriptor {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_application: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom: Option<Custom>,
}

impl<'de> Deserialize<'de> for Descriptor {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Fields {
            id: String,
            #[serde(default, deserialize_with = "present")]
            target_application: Option<String>,
            #[serde(default, deserialize_with = "present_object")]
            custom: Option<Custom>,
        }

        let Fields {
            id,
            target_application,
            custom,
        } = object(deserializer)?;
        Ok(Self {
            id,
            target_application,
            custom,
        })
    }
}

/// Metadata is not identity; Apple Events' target is identity.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Identity {
    pub id: String,
    pub target_application: Option<String>,
}
impl Descriptor {
    pub fn built_in(id: &str) -> Result<Self, Error> {
        Self {
            id: id.into(),
            target_application: None,
            custom: None,
        }
        .validated()
    }

    /// Returns an owned canonical descriptor; duplicate usage keys retain their first position.
    pub fn validated(&self) -> Result<Self, Error> {
        if self.id.len() > MAX_TEXT {
            return Err(Error::LimitExceeded);
        }
        if self.id == "automation" {
            if self.custom.is_some() {
                return Err(Error::InvalidDescriptor);
            }
            if !self
                .target_application
                .as_deref()
                .is_some_and(validate_application_identifier)
            {
                return Err(Error::InvalidTargetApplication);
            }
        } else if BUILT_IN_IDS.contains(&self.id.as_str()) {
            if self.target_application.is_some() || self.custom.is_some() {
                return Err(Error::InvalidDescriptor);
            }
        } else {
            if let Some(reason) = validate_identifier(&self.id) {
                return Err(Error::InvalidIdentifier { reason });
            }
            if self.target_application.is_some() || self.custom.is_none() {
                return Err(Error::InvalidDescriptor);
            }
        }
        let mut canonical = self.clone();
        if let Some(custom) = &mut canonical.custom {
            custom.capability.validate()?;
            canonicalize_usage_description_keys(&mut custom.usage_description_keys)?;
        }
        Ok(canonical)
    }

    pub fn identity(&self) -> Identity {
        Identity {
            id: self.id.clone(),
            target_application: self.target_application.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    Granted,
    Limited,
    Provisional,
    Ephemeral,
    Denied,
    Restricted,
    NotDetermined,
    Unknown,
}
impl Status {
    pub fn allows_access(self) -> bool {
        matches!(
            self,
            Self::Granted | Self::Limited | Self::Provisional | Self::Ephemeral
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PhotoAccessLevel {
    ReadWrite,
    AddOnly,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum Options {
    None,
    Notifications {
        #[serde(rename = "notificationOptions")]
        notification_options: u64,
    },
    Photos {
        #[serde(rename = "photoAccessLevel")]
        photo_access_level: PhotoAccessLevel,
    },
}
impl<'de> Deserialize<'de> for Options {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // Internally tagged unit variants ignore extra fields even with deny_unknown_fields.
        // An empty struct variant makes {kind:none,...} obey the same strict payload rule.
        #[derive(Deserialize)]
        #[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
        enum Payload {
            None {},
            Notifications {
                #[serde(rename = "notificationOptions")]
                notification_options: u64,
            },
            Photos {
                #[serde(rename = "photoAccessLevel")]
                photo_access_level: PhotoAccessLevel,
            },
        }
        Ok(match Payload::deserialize(deserializer)? {
            Payload::None {} => Self::None,
            Payload::Notifications {
                notification_options,
            } => Self::Notifications {
                notification_options,
            },
            Payload::Photos { photo_access_level } => Self::Photos { photo_access_level },
        })
    }
}
impl Options {
    /// None is valid for every descriptor and keeps its explicit default-behavior meaning.
    pub fn validate_for(&self, permission: &Descriptor) -> Result<(), Error> {
        permission.validated()?;
        self.validate_for_validated(permission)
    }

    pub(crate) fn validate_for_validated(&self, permission: &Descriptor) -> Result<(), Error> {
        match self {
            Self::None => Ok(()),
            Self::Notifications { .. } if permission.id == "notifications" => Ok(()),
            Self::Photos { .. } if permission.id == "photos" => Ok(()),
            _ => Err(Error::InvalidOptions),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OperationError {
    InvalidOptions,
    OpenFailed,
    ApiUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum PermissionResult<T = Status> {
    Supported {
        value: T,
    },
    Unsupported {
        #[serde(deserialize_with = "object")]
        capability: Capability,
    },
    Failed {
        error: OperationError,
    },
}
impl PermissionResult {
    pub fn unknown() -> Self {
        Self::Supported {
            value: Status::Unknown,
        }
    }

    /// Only supported observations can report access.
    pub fn allows_access(&self) -> bool {
        matches!(self, Self::Supported { value } if value.allows_access())
    }
}

/// Opening Settings returns a boolean acknowledgement, never an authorization status.
pub type SettingsResult = PermissionResult<bool>;

impl<T> PermissionResult<T> {
    pub fn validate(&self) -> Result<(), Error> {
        if let Self::Unsupported { capability } = self {
            capability.validate().map_err(|_| Error::InvalidResult)?;
        }
        Ok(())
    }
}

impl From<OperationError> for Error {
    fn from(error: OperationError) -> Self {
        match error {
            OperationError::InvalidOptions => Self::InvalidOptions,
            OperationError::OpenFailed => Self::OpenFailed,
            OperationError::ApiUnavailable => Self::ApiUnavailable,
        }
    }
}
