//! Portable permission contracts. No native calls, locks, callbacks or prompt policy.
mod metadata;
mod model;
mod store;
mod wire;

pub use metadata::{
    AccessAdmission, BUILT_IN_IDS, Metadata, SettingsAdmission, admit_access, admit_settings,
    metadata,
};
pub use model::{
    Capability, Custom, Descriptor, Error, IdentifierValidationError, Identity, OperationError,
    Options, PermissionResult, PhotoAccessLevel, Platform, SettingsResult, Status,
    validate_application_identifier, validate_identifier,
};
pub use store::{
    ApplyOutcome, Observation, RefreshAdmission, ScopedAdmission, Snapshot, Store, Update,
    ValueEntry, WorkKind,
};
pub use wire::{
    MAX_INPUT_BYTES, MAX_PERMISSIONS, Request, StoreRequest, call, decode, parse, parse_store,
};
