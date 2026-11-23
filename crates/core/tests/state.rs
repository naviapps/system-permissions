use serde_json::json;
use system_permissions::*;

fn permission(id: &str) -> Descriptor {
    Descriptor::built_in(id).unwrap()
}
fn result(status: Status) -> PermissionResult {
    PermissionResult::Supported { value: status }
}
fn update(permission: &Descriptor, token: u64, status: Status) -> Update {
    Update {
        permission: permission.clone(),
        token,
        result: result(status),
    }
}
fn custom(requests: bool) -> Descriptor {
    serde_json::from_value(json!({"id":"com.host.custom","custom":{
        "capability":{"supportsStatusCheck":true,"supportsRequest":requests,"requiresRelaunch":false},
        "usageDescriptionKeys":[]
    }})).unwrap()
}

#[test]
fn observation_changes_use_the_preceding_sample_for_each_permission() {
    let camera = permission("camera");
    let microphone = permission("microphone");
    let unknown = result(Status::Unknown);
    let granted = result(Status::Granted);
    let unavailable = PermissionResult::Failed {
        error: OperationError::ApiUnavailable,
    };
    let unsupported = |url: &str| PermissionResult::Unsupported {
        capability: Capability {
            supports_status_check: false,
            supports_request: false,
            system_settings_url: Some(url.to_owned()),
            requires_relaunch: false,
        },
    };
    let literal = unsupported("example:é");
    let escaped = unsupported("example:%C3%A9");
    let mut store = Store::new();
    store.track(&[camera.clone(), microphone.clone()]).unwrap();

    for (permission, sample, previous) in [
        (&camera, &unknown, None),
        (&microphone, &granted, None),
        (&camera, &unknown, None),
        (&camera, &granted, Some(&unknown)),
        (&camera, &granted, None),
        (&camera, &literal, Some(&granted)),
        (&camera, &escaped, Some(&literal)),
        (&camera, &unavailable, Some(&escaped)),
        (&microphone, &unknown, Some(&granted)),
        (&camera, &granted, Some(&unavailable)),
    ] {
        assert_eq!(
            store
                .record_observation(permission, sample.clone())
                .unwrap(),
            Some(Observation {
                result: sample.clone(),
                previous_result: previous.cloned(),
            })
        );
    }
}

#[test]
fn observation_rejection_and_tracking_are_independent_of_admitted_work() {
    let camera = permission("camera");
    let mut store = Store::new();
    let granted = result(Status::Granted);
    let denied = result(Status::Denied);
    assert_eq!(store.record_observation(&camera, granted.clone()), Ok(None));
    store.track(std::slice::from_ref(&camera)).unwrap();
    let token = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    store.record_observation(&camera, granted.clone()).unwrap();
    let invalid = PermissionResult::Unsupported {
        capability: Capability {
            supports_status_check: false,
            supports_request: false,
            system_settings_url: Some("relative/path".to_owned()),
            requires_relaunch: false,
        },
    };
    assert_eq!(
        store.record_observation(&camera, invalid),
        Err(Error::InvalidResult)
    );
    store.track(std::slice::from_ref(&camera)).unwrap();
    assert_eq!(
        store
            .record_observation(&camera, denied.clone())
            .unwrap()
            .unwrap()
            .previous_result,
        Some(granted)
    );
    assert_eq!(
        store.get(&camera).unwrap(),
        Some(PermissionResult::unknown())
    );
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    assert_eq!(
        store.apply(&[update(&camera, token, Status::Granted)], false),
        Ok(ApplyOutcome {
            changed: true,
            accepted: 1,
        })
    );
    store.track(&[]).unwrap();
    store.track(std::slice::from_ref(&camera)).unwrap();
    assert_eq!(
        store.record_observation(&camera, denied.clone()),
        Ok(Some(Observation {
            result: denied,
            previous_result: None,
        }))
    );
}

#[test]
fn tracking_deduplicates_in_first_order_and_preserves_retained_results() {
    let (a, b, c) = (
        permission("camera"),
        permission("microphone"),
        permission("photos"),
    );
    let mut store = Store::new();
    assert!(store.snapshot().values.is_empty());
    assert_eq!(store.get(&a).unwrap(), None);
    assert_eq!(store.begin(&a).unwrap(), None);
    let snapshot = store.track(&[a.clone(), b.clone(), a.clone()]).unwrap();
    assert_eq!(
        snapshot
            .values
            .iter()
            .map(|e| &e.permission)
            .collect::<Vec<_>>(),
        vec![&a, &b]
    );
    assert!(
        snapshot
            .values
            .iter()
            .all(|e| e.result == PermissionResult::unknown())
    );
    let token = store.begin(&b).unwrap().unwrap();
    assert_eq!(
        store
            .apply(&[update(&b, token, Status::Granted)], false)
            .unwrap(),
        ApplyOutcome {
            changed: true,
            accepted: 1
        }
    );
    store.track(&[b.clone(), c, a.clone()]).unwrap();
    assert_eq!(store.get(&b).unwrap(), Some(result(Status::Granted)));
    assert_eq!(
        store
            .apply(&[update(&b, token, Status::Granted)], false)
            .unwrap(),
        ApplyOutcome {
            changed: false,
            accepted: 1
        }
    );
}

#[test]
fn cancelled_new_work_still_supersedes_previous_work() {
    let a = permission("camera");
    let mut store = Store::new();
    store.track(std::slice::from_ref(&a)).unwrap();
    let old = store.begin(&a).unwrap().unwrap();
    let current = store.begin(&a).unwrap().unwrap();
    assert!(current > old);
    assert_eq!(
        store
            .apply(&[update(&a, current, Status::Granted)], true)
            .unwrap(),
        ApplyOutcome {
            changed: false,
            accepted: 0
        }
    );
    assert_eq!(
        store
            .apply(&[update(&a, old, Status::Denied)], false)
            .unwrap()
            .accepted,
        0
    );
    assert_eq!(store.get(&a).unwrap(), Some(PermissionResult::unknown()));
    assert_eq!(
        store
            .apply(&[update(&a, current, Status::Limited)], false)
            .unwrap()
            .accepted,
        1
    );
}

#[test]
fn removal_readdition_never_reuses_tokens_and_untracked_results_are_filtered() {
    let a = permission("camera");
    let b = permission("microphone");
    let mut store = Store::new();
    store.track(std::slice::from_ref(&a)).unwrap();
    let old = store.begin(&a).unwrap().unwrap();
    store.track(&[]).unwrap();
    assert_eq!(
        store
            .apply(&[update(&a, old, Status::Denied)], false)
            .unwrap()
            .accepted,
        0
    );
    store.track(std::slice::from_ref(&a)).unwrap();
    assert_eq!(
        store
            .apply(&[update(&a, old, Status::Granted)], false)
            .unwrap()
            .accepted,
        0
    );
    let new = store.begin(&a).unwrap().unwrap();
    assert!(new > old);
    assert_eq!(
        store
            .apply(
                &[
                    update(&a, new, Status::Granted),
                    update(&b, new, Status::Denied)
                ],
                false
            )
            .unwrap()
            .accepted,
        1
    );
}

#[test]
fn independent_automation_targets_have_independent_state_and_tokens() {
    let a: Descriptor =
        serde_json::from_value(json!({"id":"automation","targetApplication":"com.apple.Safari"}))
            .unwrap();
    let b: Descriptor =
        serde_json::from_value(json!({"id":"automation","targetApplication":"com.apple.TextEdit"}))
            .unwrap();
    let mut store = Store::new();
    store.track(&[a.clone(), b.clone()]).unwrap();
    let at = store.begin(&a).unwrap().unwrap();
    let bt = store.begin(&b).unwrap().unwrap();
    store
        .apply(
            &[
                update(&a, at, Status::Granted),
                update(&b, bt, Status::Denied),
            ],
            false,
        )
        .unwrap();
    assert_eq!(store.get(&a).unwrap(), Some(result(Status::Granted)));
    assert_eq!(store.get(&b).unwrap(), Some(result(Status::Denied)));
    assert_eq!(store.snapshot().values[1].permission, b);
}

#[test]
fn metadata_conflicts_and_invalid_batches_are_atomic_even_if_cancelled_or_stale() {
    let a = permission("camera");
    let c = custom(false);
    let other = custom(true);
    let mut store = Store::new();
    store.track(&[a.clone(), c.clone()]).unwrap();
    let token = store.begin(&a).unwrap().unwrap();
    let before = store.snapshot();
    assert_eq!(
        store.track(&[a.clone(), c.clone(), other.clone()]),
        Err(Error::InconsistentMetadata)
    );
    assert_eq!(store.snapshot(), before);
    assert_eq!(
        store.track(std::slice::from_ref(&other)),
        Err(Error::InconsistentMetadata)
    );
    assert_eq!(store.begin(&other), Err(Error::InconsistentMetadata));
    assert_eq!(store.get(&other), Err(Error::InconsistentMetadata));
    let bad = Update {
        permission: other,
        token: 999,
        result: result(Status::Granted),
    };
    for cancelled in [false, true] {
        assert_eq!(
            store.apply(
                &[update(&a, token, Status::Granted), bad.clone()],
                cancelled
            ),
            Err(Error::InconsistentMetadata)
        );
        assert_eq!(store.snapshot(), before);
    }
    assert_eq!(
        store.apply(
            &[
                update(&a, token, Status::Granted),
                update(&a, token, Status::Denied)
            ],
            false
        ),
        Err(Error::DuplicateUpdate)
    );
    assert_eq!(
        store.apply(&[update(&a, 0, Status::Granted)], false),
        Err(Error::InvalidToken)
    );
    let invalid = Update {
        permission: c,
        token: 1,
        result: PermissionResult::Unsupported {
            capability: Capability {
                supports_status_check: false,
                supports_request: false,
                system_settings_url: Some("bad url".into()),
                requires_relaunch: false,
            },
        },
    };
    assert_eq!(
        store.apply(&[update(&a, token, Status::Granted), invalid], false),
        Err(Error::InvalidResult)
    );
    assert_eq!(store.snapshot(), before);
    assert!(
        store
            .apply(&[update(&a, token, Status::Granted)], false)
            .unwrap()
            .changed
    );
}

#[test]
fn store_wire_shapes_reject_unknown_fields_and_preserve_descriptor_in_snapshot() {
    let mut store = Store::new();
    let mut dispatch = |value| {
        store
            .dispatch(parse_store(&serde_json::to_vec(&value).unwrap()).unwrap())
            .unwrap()
    };
    assert_eq!(
        dispatch(json!({"op":"track","permissions":[{"id":"camera"}]})),
        json!({"values":[{"permission":{"id":"camera"},"result":{"kind":"supported","value":"unknown"}}]})
    );
    assert_eq!(
        dispatch(json!({"op":"get","permission":{"id":"microphone"}})),
        json!(null)
    );
    assert_eq!(
        dispatch(json!({"op":"begin","permission":{"id":"microphone"}})),
        json!({"token":null})
    );
    for input in [
        json!({"op":"snapshot","extra":0}),
        json!({"op":"track","permissions":[],"extra":0}),
        json!({"op":"apply","updates":[],"cancelled":null}),
        json!({"op":"apply","updates":[{"permission":{"id":"camera"},"token":1,"result":{"kind":"supported","value":"granted"},"extra":1}],"cancelled":false}),
        json!({"op":"apply","updates":[],"cancelled":false,"permission":{"id":"camera"}}),
    ] {
        assert!(
            parse_store(&serde_json::to_vec(&input).unwrap()).is_err(),
            "{input}"
        );
    }
    let before = store.snapshot();
    assert_eq!(
        store.track(&vec![permission("camera"); MAX_PERMISSIONS + 1]),
        Err(Error::LimitExceeded)
    );
    assert_eq!(store.snapshot(), before);
}
