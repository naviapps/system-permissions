use crate::{
    Descriptor, Error, Identity, MAX_PERMISSIONS, Options, PermissionResult, PhotoAccessLevel,
    StoreRequest,
};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ValueEntry {
    pub permission: Descriptor,
    pub result: PermissionResult,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Snapshot {
    pub values: Vec<ValueEntry>,
}

/// A validated poll sample with the preceding result only when it changed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Observation {
    pub result: PermissionResult,
    pub previous_result: Option<PermissionResult>,
}

#[derive(Debug, Clone)]
pub struct Update {
    pub permission: Descriptor,
    pub token: u64,
    pub result: PermissionResult,
}

impl<'de> Deserialize<'de> for Update {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Fields {
            permission: Descriptor,
            token: u64,
            result: PermissionResult,
        }

        let Fields {
            permission,
            token,
            result,
        } = crate::model::object(deserializer)?;
        Ok(Self {
            permission,
            token,
            result,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ApplyOutcome {
    pub changed: bool,
    /// Number of current, tracked updates accepted, including unchanged results.
    pub accepted: usize,
}

/// Typed store work. Explicit requests take priority over passive refresh admission.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkKind {
    Refresh,
    Request,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RefreshAdmission {
    pub permission: Descriptor,
    pub token: u64,
}

/// Admission for an SDK operation whose result may belong to a separate scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ScopedAdmission {
    Untracked,
    InvalidOptions,
    Isolated,
    Suppressed,
    Stored { token: u64 },
}

impl<'de> Deserialize<'de> for WorkKind {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        match String::deserialize(decoder)?.as_str() {
            "refresh" => Ok(Self::Refresh),
            "request" => Ok(Self::Request),
            other => Err(serde::de::Error::unknown_variant(
                other,
                &["refresh", "request"],
            )),
        }
    }
}

#[derive(Debug, Clone)]
struct Entry {
    permission: Descriptor,
    result: PermissionResult,
    observed: Option<PermissionResult>,
    token: Option<u64>,
    work_kind: Option<WorkKind>,
}

/// Deterministic owned state; synchronization and native scheduling belong outside core.
#[derive(Debug, Default)]
pub struct Store {
    entries: Vec<Entry>,
    indices: HashMap<Identity, usize>,
    last_token: u64,
}
impl Store {
    pub fn new() -> Self {
        Self::default()
    }

    /// Atomically replace tracking, deduplicating in first-occurrence order.
    /// Retained entries keep results/work tokens; removed entries cannot revive on re-add.
    pub fn track(&mut self, permissions: &[Descriptor]) -> Result<Snapshot, Error> {
        if permissions.len() > MAX_PERMISSIONS {
            return Err(Error::LimitExceeded);
        }
        let mut entries: Vec<Entry> = Vec::new();
        let mut indices: HashMap<Identity, usize> = HashMap::new();
        for permission in permissions {
            let permission = permission.validated()?;
            let identity = permission.identity();
            if let Some(&index) = indices.get(&identity) {
                if entries[index].permission != permission {
                    return Err(Error::InconsistentMetadata);
                }
                continue;
            }
            let entry = if let Some(&index) = self.indices.get(&identity) {
                let entry = &self.entries[index];
                if entry.permission != permission {
                    return Err(Error::InconsistentMetadata);
                }
                entry.clone()
            } else {
                Entry {
                    permission,
                    result: PermissionResult::unknown(),
                    observed: None,
                    token: None,
                    work_kind: None,
                }
            };
            indices.insert(identity, entries.len());
            entries.push(entry);
        }
        self.entries = entries;
        self.indices = indices;
        Ok(self.snapshot())
    }

    fn index(&self, permission: &Descriptor) -> Result<Option<usize>, Error> {
        self.validated_index(&permission.validated()?)
    }

    fn validated_index(&self, permission: &Descriptor) -> Result<Option<usize>, Error> {
        match self.indices.get(&permission.identity()).copied() {
            Some(index) if self.entries[index].permission != *permission => {
                Err(Error::InconsistentMetadata)
            }
            index => Ok(index),
        }
    }

    pub fn get(&self, permission: &Descriptor) -> Result<Option<PermissionResult>, Error> {
        Ok(self
            .index(permission)?
            .map(|i| self.entries[i].result.clone()))
    }

    /// Record an independent poll result without using work admission or changing a stored status.
    pub fn record_observation(
        &mut self,
        permission: &Descriptor,
        result: PermissionResult,
    ) -> Result<Option<Observation>, Error> {
        result.validate()?;
        let Some(index) = self.index(permission)? else {
            return Ok(None);
        };
        let previous_result = self.entries[index]
            .observed
            .replace(result.clone())
            .filter(|previous| previous != &result);
        Ok(Some(Observation {
            result,
            previous_result,
        }))
    }

    /// Begins manually ordered work, superseding prior work and typed request priority.
    /// Tokens remain reusable by apply until superseded or explicitly finished.
    pub fn begin(&mut self, permission: &Descriptor) -> Result<Option<u64>, Error> {
        let Some(index) = self.index(permission)? else {
            return Ok(None);
        };
        self.reserve(index, None).map(Some)
    }

    /// Admits typed work without invoking a provider. A current typed request suppresses
    /// refreshes for its permission; a new request always supersedes previous work.
    /// None denotes an untracked permission or a suppressed refresh. Descriptor and
    /// tracked metadata validation still occur before suppression.
    pub fn admit(&mut self, permission: &Descriptor, kind: WorkKind) -> Result<Option<u64>, Error> {
        let Some(index) = self.index(permission)? else {
            return Ok(None);
        };
        self.admit_tracked(index, kind)
    }

    /// Rejects mismatched options before reserving work. Add-only Photos operations
    /// observe a separate scope and never replace a read/write reservation or result.
    pub fn admit_scoped(
        &mut self,
        permission: &Descriptor,
        options: &Options,
        kind: WorkKind,
        cancelled: bool,
    ) -> Result<ScopedAdmission, Error> {
        let Some(index) = self.index(permission)? else {
            return Ok(ScopedAdmission::Untracked);
        };
        match options.validate_for_validated(&self.entries[index].permission) {
            Err(Error::InvalidOptions) => return Ok(ScopedAdmission::InvalidOptions),
            result => result?,
        }
        if matches!(
            options,
            Options::Photos {
                photo_access_level: PhotoAccessLevel::AddOnly
            }
        ) {
            return Ok(ScopedAdmission::Isolated);
        }
        if cancelled {
            return Ok(ScopedAdmission::Suppressed);
        }
        Ok(match self.admit_tracked(index, kind)? {
            Some(token) => ScopedAdmission::Stored { token },
            None => ScopedAdmission::Suppressed,
        })
    }

    fn admit_tracked(&mut self, index: usize, kind: WorkKind) -> Result<Option<u64>, Error> {
        if kind == WorkKind::Refresh && self.entries[index].work_kind == Some(WorkKind::Request) {
            return Ok(None);
        }
        self.reserve(index, Some(kind)).map(Some)
    }

    /// Admits refreshes in tracking order, leaving scopes with pending requests untouched.
    /// Token exhaustion leaves every scope unchanged.
    pub fn admit_all_refreshes(&mut self) -> Result<Vec<RefreshAdmission>, Error> {
        let count = self
            .entries
            .iter()
            .filter(|entry| entry.work_kind != Some(WorkKind::Request))
            .count();
        self.last_token
            .checked_add(count as u64)
            .ok_or(Error::TokenExhausted)?;
        let mut admissions = Vec::with_capacity(count);
        for index in 0..self.entries.len() {
            if self.entries[index].work_kind == Some(WorkKind::Request) {
                continue;
            }
            let token = self.reserve(index, Some(WorkKind::Refresh))?;
            admissions.push(RefreshAdmission {
                permission: self.entries[index].permission.clone(),
                token,
            });
        }
        Ok(admissions)
    }

    fn reserve(&mut self, index: usize, kind: Option<WorkKind>) -> Result<u64, Error> {
        // One sequence across every reservation prevents removal/re-add ABA races.
        let token = self
            .last_token
            .checked_add(1)
            .ok_or(Error::TokenExhausted)?;
        self.entries[index].token = Some(token);
        self.entries[index].work_kind = kind;
        self.last_token = token;
        Ok(token)
    }

    /// Retires matching current work without changing its result or reviving older work.
    /// Cleanup needs no descriptor and a stale nonzero token is a harmless no-op.
    pub fn finish(&mut self, token: u64) -> Result<bool, Error> {
        if token == 0 {
            return Err(Error::InvalidToken);
        }
        let Some(entry) = self
            .entries
            .iter_mut()
            .find(|entry| entry.token == Some(token))
        else {
            return Ok(false);
        };
        entry.token = None;
        entry.work_kind = None;
        Ok(true)
    }

    /// Validate the entire batch (including stale/cancelled entries) before committing.
    /// Cancellation never restores an older token superseded by begin or admit.
    pub fn apply(&mut self, updates: &[Update], cancelled: bool) -> Result<ApplyOutcome, Error> {
        if updates.len() > MAX_PERMISSIONS {
            return Err(Error::LimitExceeded);
        }
        let mut seen = HashSet::new();
        let mut pending = Vec::new();
        for update in updates {
            let permission = update.permission.validated()?;
            update.result.validate()?;
            if update.token == 0 {
                return Err(Error::InvalidToken);
            }
            if !seen.insert(permission.identity()) {
                return Err(Error::DuplicateUpdate);
            }
            if let Some(index) = self.validated_index(&permission)?
                && self.entries[index].token == Some(update.token)
            {
                pending.push((index, update.result.clone()));
            }
        }
        if cancelled {
            return Ok(ApplyOutcome {
                changed: false,
                accepted: 0,
            });
        }
        let changed = pending
            .iter()
            .any(|(index, result)| self.entries[*index].result != *result);
        let accepted = pending.len();
        for (index, result) in pending {
            self.entries[index].result = result;
        }
        Ok(ApplyOutcome { changed, accepted })
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            values: self
                .entries
                .iter()
                .map(|e| ValueEntry {
                    permission: e.permission.clone(),
                    result: e.result.clone(),
                })
                .collect(),
        }
    }

    pub fn dispatch(&mut self, request: StoreRequest) -> Result<Value, Error> {
        Ok(match request {
            StoreRequest::Track { permissions } => json!(self.track(&permissions)?),
            StoreRequest::Get { permission } => json!(self.get(&permission)?),
            StoreRequest::RecordObservation { permission, result } => {
                json!(self.record_observation(&permission, result)?)
            }
            StoreRequest::Begin { permission } => json!({"token": self.begin(&permission)?}),
            StoreRequest::Admit { permission, kind } => {
                json!({"token": self.admit(&permission, kind)?})
            }
            StoreRequest::AdmitScoped {
                permission,
                options,
                kind,
                cancelled,
            } => {
                json!(self.admit_scoped(&permission, &options, kind, cancelled)?)
            }
            StoreRequest::AdmitAllRefreshes {} => json!(self.admit_all_refreshes()?),
            StoreRequest::Finish { token } => json!({"finished": self.finish(token)?}),
            StoreRequest::Apply { updates, cancelled } => json!(self.apply(&updates, cancelled)?),
            StoreRequest::Snapshot {} => json!(self.snapshot()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn token_exhaustion_does_not_overwrite_current_work() {
        let permission = Descriptor::built_in("camera").unwrap();
        let mut store = Store::new();
        store.track(std::slice::from_ref(&permission)).unwrap();
        let current = store.begin(&permission).unwrap();
        store.last_token = u64::MAX;
        assert_eq!(store.begin(&permission), Err(Error::TokenExhausted));
        assert_eq!(store.entries[0].token, current);
        assert_eq!(store.entries[0].work_kind, None);
    }

    #[test]
    fn typed_exhaustion_preserves_priority_and_does_not_reserve_suppressed_work() {
        let permission = Descriptor::built_in("camera").unwrap();
        let mut store = Store::new();
        store.track(std::slice::from_ref(&permission)).unwrap();
        let token = store
            .admit(&permission, WorkKind::Request)
            .unwrap()
            .unwrap();
        store.last_token = u64::MAX;
        assert_eq!(store.begin(&permission), Err(Error::TokenExhausted));
        assert_eq!(
            store.admit(&permission, WorkKind::Request),
            Err(Error::TokenExhausted)
        );
        assert_eq!(store.admit(&permission, WorkKind::Refresh), Ok(None));
        assert_eq!(store.entries[0].token, Some(token));
        assert_eq!(store.entries[0].work_kind, Some(WorkKind::Request));
        assert_eq!(store.finish(token), Ok(true));
        assert_eq!(
            store.admit(&permission, WorkKind::Refresh),
            Err(Error::TokenExhausted)
        );
        assert_eq!(store.entries[0].token, None);
        assert_eq!(store.entries[0].work_kind, None);
    }

    #[test]
    fn batch_exhaustion_preserves_every_current_token() {
        let camera = Descriptor::built_in("camera").unwrap();
        let microphone = Descriptor::built_in("microphone").unwrap();
        let mut store = Store::new();
        store.track(&[camera.clone(), microphone]).unwrap();
        let camera_token = store.begin(&camera).unwrap();
        store.last_token = u64::MAX - 1;

        assert_eq!(store.admit_all_refreshes(), Err(Error::TokenExhausted));
        assert_eq!(store.last_token, u64::MAX - 1);
        assert_eq!(store.entries[0].token, camera_token);
        assert_eq!(store.entries[0].work_kind, None);
        assert_eq!(store.entries[1].token, None);
    }
}
