//! Request ownership and capacity only. All supplied closures run outside the state lock.
use permissions_core::{OperationError, PermissionResult};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub(super) struct Pending {
    poll: Box<dyn Fn() -> Result<Option<PermissionResult>, OperationError> + Send + Sync>,
    cancel: Box<dyn Fn() + Send + Sync>,
    cancelled: AtomicBool,
}
impl Pending {
    pub(super) fn new(
        poll: impl Fn() -> Result<Option<PermissionResult>, OperationError> + Send + Sync + 'static,
        cancel: impl Fn() + Send + Sync + 'static,
    ) -> Arc<Self> {
        Arc::new(Self {
            poll: Box::new(poll),
            cancel: Box::new(cancel),
            cancelled: AtomicBool::new(false),
        })
    }
    fn cancel(&self) {
        if !self.cancelled.swap(true, Ordering::AcqRel) {
            (self.cancel)();
        }
    }
}
impl Drop for Pending {
    fn drop(&mut self) {
        self.cancel();
    }
}

#[derive(Default)]
struct State {
    sequence: u64,
    // None is a capacity reservation made before starting any native UI.
    values: BTreeMap<u64, Option<Arc<Pending>>>,
}
#[derive(Default)]
pub(super) struct Requests(Mutex<State>);

impl Requests {
    pub(super) fn reserve(&self) -> Result<Reservation<'_>, OperationError> {
        let token = {
            let mut state = self.0.lock().map_err(|_| OperationError::ApiUnavailable)?;
            if state.values.len() >= 128 {
                return Err(OperationError::ApiUnavailable);
            }
            let token = state
                .sequence
                .checked_add(1)
                .ok_or(OperationError::ApiUnavailable)?;
            state.sequence = token;
            state.values.insert(token, None);
            token
        };
        Ok(Reservation {
            requests: self,
            token,
            committed: false,
        })
    }

    pub(super) fn poll(&self, token: u64) -> Result<Option<PermissionResult>, OperationError> {
        let pending = {
            let state = self.0.lock().map_err(|_| OperationError::ApiUnavailable)?;
            state
                .values
                .get(&token)
                .and_then(Option::as_ref)
                .cloned()
                .ok_or(OperationError::InvalidOptions)?
        };
        if pending.cancelled.load(Ordering::Acquire) {
            return Err(OperationError::InvalidOptions);
        }
        let result = (pending.poll)();
        if !matches!(result, Ok(None)) {
            let removed = {
                let mut state = self.0.lock().map_err(|_| OperationError::ApiUnavailable)?;
                state.values.remove(&token)
            };
            if removed.is_none() {
                return Err(OperationError::InvalidOptions);
            }
            drop(removed);
        }
        result
    }

    pub(super) fn cancel(&self, token: u64) -> Result<(), OperationError> {
        let removed = {
            let mut state = self.0.lock().map_err(|_| OperationError::ApiUnavailable)?;
            state
                .values
                .remove(&token)
                .ok_or(OperationError::InvalidOptions)?
        };
        if let Some(pending) = removed {
            pending.cancel();
        }
        Ok(())
    }
}

pub(super) struct Reservation<'a> {
    requests: &'a Requests,
    token: u64,
    committed: bool,
}
impl Reservation<'_> {
    pub(super) fn commit(mut self, pending: Arc<Pending>) -> Result<u64, OperationError> {
        {
            let mut state = self
                .requests
                .0
                .lock()
                .map_err(|_| OperationError::ApiUnavailable)?;
            let value = state
                .values
                .get_mut(&self.token)
                .ok_or(OperationError::InvalidOptions)?;
            *value = Some(pending);
        }
        self.committed = true;
        Ok(self.token)
    }
}
impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        if !self.committed {
            let removed = {
                let Ok(mut state) = self.requests.0.lock() else {
                    return;
                };
                state.values.remove(&self.token)
            };
            drop(removed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use permissions_core::Status;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn failed_start_releases_capacity_without_reusing_tokens() {
        let requests = Requests::default();
        let mut reservations = Vec::new();
        for _ in 0..128 {
            reservations.push(requests.reserve().unwrap());
        }
        assert!(requests.reserve().is_err());
        drop(reservations.pop());
        let next = requests.reserve().unwrap();
        assert_eq!(next.token, 129);
    }

    #[test]
    fn native_callbacks_can_reenter_registry_and_completion_releases_once() {
        let requests = Arc::new(Requests::default());
        let polls = Arc::clone(&requests);
        let cancels = Arc::clone(&requests);
        let count = Arc::new(AtomicUsize::new(0));
        let cancelled = Arc::clone(&count);
        let pending = Pending::new(
            move || {
                drop(polls.reserve().unwrap());
                Ok(Some(PermissionResult::Supported {
                    value: Status::Denied,
                }))
            },
            move || {
                drop(cancels.reserve().unwrap());
                cancelled.fetch_add(1, Ordering::SeqCst);
            },
        );
        let token = requests.reserve().unwrap().commit(pending).unwrap();
        assert!(requests.poll(token).unwrap().is_some());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert_eq!(requests.poll(token), Err(OperationError::InvalidOptions));
    }

    #[test]
    fn cancelling_a_reservation_wins_over_late_native_start() {
        let requests = Requests::default();
        let reservation = requests.reserve().unwrap();
        requests.cancel(reservation.token).unwrap();
        let count = Arc::new(AtomicUsize::new(0));
        let cancelled = Arc::clone(&count);
        let pending = Pending::new(
            || Ok(None),
            move || {
                cancelled.fetch_add(1, Ordering::SeqCst);
            },
        );
        assert_eq!(
            reservation.commit(pending),
            Err(OperationError::InvalidOptions)
        );
        assert_eq!(count.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn concurrent_reservations_enforce_capacity() {
        let requests = Requests::default();
        std::thread::scope(|scope| {
            let handles: Vec<_> = (0..256)
                .map(|_| scope.spawn(|| requests.reserve()))
                .collect();
            let reservations: Vec<_> = handles
                .into_iter()
                .filter_map(|h| h.join().unwrap().ok())
                .collect();
            assert_eq!(reservations.len(), 128);
            let unique: std::collections::HashSet<_> =
                reservations.iter().map(|r| r.token).collect();
            assert_eq!(unique.len(), 128);
        });
        assert!(requests.reserve().is_ok());
    }
}
