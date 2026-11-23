use serde_json::json;
use system_permissions::*;

fn permission(id: &str) -> Descriptor {
    Descriptor::built_in(id).unwrap()
}
fn update(permission: &Descriptor, token: u64, status: Status) -> Update {
    Update {
        permission: permission.clone(),
        token,
        result: PermissionResult::Supported { value: status },
    }
}
fn custom(requests: bool) -> Descriptor {
    serde_json::from_value(json!({"id":"com.host.custom","custom":{
        "capability":{"supportsStatusCheck":true,"supportsRequest":requests,"requiresRelaunch":false},
        "usageDescriptionKeys":[]
    }})).unwrap()
}

#[test]
fn latest_request_suppresses_refresh_until_finish_and_stale_finish_cannot_unblock_it() {
    let camera = permission("camera");
    let mut store = Store::new();
    store.track(std::slice::from_ref(&camera)).unwrap();
    let query = store.admit(&camera, WorkKind::Refresh).unwrap().unwrap();
    let first = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    let latest = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    assert!(query < first && first < latest);
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    assert_eq!(store.finish(first), Ok(false));
    assert_eq!(store.finish(query), Ok(false));
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    for stale in [query, first] {
        assert_eq!(
            store
                .apply(&[update(&camera, stale, Status::Denied)], false)
                .unwrap()
                .accepted,
            0
        );
    }
    for status in [Status::Granted, Status::Limited] {
        assert_eq!(
            store
                .apply(&[update(&camera, latest, status)], false)
                .unwrap()
                .accepted,
            1
        );
        assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    }
    assert_eq!(store.finish(latest), Ok(true));
    assert_eq!(store.finish(latest), Ok(false));
    assert_eq!(
        store.get(&camera).unwrap(),
        Some(PermissionResult::Supported {
            value: Status::Limited
        })
    );
    let next = store.admit(&camera, WorkKind::Refresh).unwrap().unwrap();
    assert_eq!(
        next,
        latest + 1,
        "Suppression must not consume reservation tokens"
    );
    assert_eq!(
        store
            .apply(&[update(&camera, latest, Status::Denied)], false)
            .unwrap()
            .accepted,
        0
    );
}

#[test]
fn cancelled_work_can_finish_without_resurrecting_old_tokens_or_changing_results() {
    let camera = permission("camera");
    let mut store = Store::new();
    store.track(std::slice::from_ref(&camera)).unwrap();
    let old = store.admit(&camera, WorkKind::Refresh).unwrap().unwrap();
    let request = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    let before = store.snapshot();
    assert_eq!(
        store
            .apply(&[update(&camera, request, Status::Granted)], true)
            .unwrap(),
        ApplyOutcome {
            changed: false,
            accepted: 0
        }
    );
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    assert_eq!(store.finish(request), Ok(true));
    for token in [old, request] {
        assert_eq!(
            store
                .apply(&[update(&camera, token, Status::Denied)], false)
                .unwrap()
                .accepted,
            0
        );
    }
    assert_eq!(store.snapshot(), before);
    let current = store.admit(&camera, WorkKind::Refresh).unwrap().unwrap();
    assert!(current > request);
    assert_eq!(store.finish(0), Err(Error::InvalidToken));
    assert_eq!(store.finish(u64::MAX), Ok(false));
    assert_eq!(
        store
            .apply(&[update(&camera, current, Status::Granted)], false)
            .unwrap()
            .accepted,
        1
    );
}

#[test]
fn manual_begin_overrides_typed_request_priority_and_tokens_remain_reusable() {
    let camera = permission("camera");
    let mut store = Store::new();
    store.track(std::slice::from_ref(&camera)).unwrap();
    let request = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    let manual = store.begin(&camera).unwrap().unwrap();
    assert!(manual > request);
    assert_eq!(store.finish(request), Ok(false));
    for status in [Status::Granted, Status::Denied] {
        assert_eq!(
            store
                .apply(&[update(&camera, manual, status)], false)
                .unwrap()
                .accepted,
            1
        );
    }
    let query = store.admit(&camera, WorkKind::Refresh).unwrap().unwrap();
    assert!(query > manual);
    assert_eq!(store.finish(manual), Ok(false));
    assert_eq!(store.finish(query), Ok(true));
    let manual = store.begin(&camera).unwrap().unwrap();
    assert_eq!(store.finish(manual), Ok(true));
    assert_eq!(
        store
            .apply(&[update(&camera, manual, Status::Granted)], false)
            .unwrap()
            .accepted,
        0
    );
}

#[test]
fn admission_validates_descriptors_and_tracked_metadata_before_suppression() {
    let permission = custom(true);
    let conflicting = custom(false);
    let invalid: Descriptor =
        serde_json::from_value(json!({"id":"automation","targetApplication":"invalid target"}))
            .unwrap();
    let mut store = Store::new();
    store.track(std::slice::from_ref(&permission)).unwrap();
    let token = store
        .admit(&permission, WorkKind::Request)
        .unwrap()
        .unwrap();
    for kind in [WorkKind::Refresh, WorkKind::Request] {
        assert_eq!(
            store.admit(&conflicting, kind),
            Err(Error::InconsistentMetadata)
        );
        assert_eq!(
            store.admit(&invalid, kind),
            Err(Error::InvalidTargetApplication)
        );
        assert_eq!(
            store.admit(&Descriptor::built_in("camera").unwrap(), kind),
            Ok(None)
        );
    }
    assert_eq!(store.admit(&permission, WorkKind::Refresh), Ok(None));
    assert_eq!(store.finish(token), Ok(true));
    assert_eq!(
        store.admit(&permission, WorkKind::Refresh),
        Ok(Some(token + 1))
    );
}

#[test]
fn requests_do_not_block_unrelated_permissions_or_automation_targets() {
    let camera = permission("camera");
    let microphone = permission("microphone");
    let first: Descriptor =
        serde_json::from_value(json!({"id":"automation","targetApplication":"com.example.First"}))
            .unwrap();
    let second: Descriptor =
        serde_json::from_value(json!({"id":"automation","targetApplication":"com.example.Second"}))
            .unwrap();
    let mut store = Store::new();
    store
        .track(&[
            camera.clone(),
            microphone.clone(),
            first.clone(),
            second.clone(),
        ])
        .unwrap();
    let camera_token = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    let first_token = store.admit(&first, WorkKind::Request).unwrap().unwrap();
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    assert_eq!(store.admit(&first, WorkKind::Refresh), Ok(None));
    let microphone_token = store
        .admit(&microphone, WorkKind::Refresh)
        .unwrap()
        .unwrap();
    let second_token = store.admit(&second, WorkKind::Refresh).unwrap().unwrap();
    assert_eq!(
        [camera_token, first_token, microphone_token, second_token],
        [1, 2, 3, 4]
    );
    assert_eq!(
        store
            .apply(
                &[
                    update(&microphone, microphone_token, Status::Granted),
                    update(&second, second_token, Status::Denied)
                ],
                false
            )
            .unwrap()
            .accepted,
        2
    );
    assert_eq!(
        store.get(&camera).unwrap(),
        Some(PermissionResult::unknown())
    );
    assert_eq!(
        store.get(&first).unwrap(),
        Some(PermissionResult::unknown())
    );
}

#[test]
fn tracking_preserves_retained_request_ownership_and_removal_cannot_revive_it() {
    let camera = permission("camera");
    let microphone = permission("microphone");
    let mut store = Store::new();
    store.track(&[camera.clone(), microphone.clone()]).unwrap();
    let old = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    store
        .track(&[microphone.clone(), camera.clone(), camera.clone()])
        .unwrap();
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    store.track(std::slice::from_ref(&microphone)).unwrap();
    assert_eq!(store.finish(old), Ok(false));
    store.track(&[camera.clone(), microphone]).unwrap();
    let current = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    assert!(current > old);
    assert_eq!(store.finish(old), Ok(false));
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    assert_eq!(
        store
            .apply(&[update(&camera, old, Status::Granted)], false)
            .unwrap()
            .accepted,
        0
    );
    assert_eq!(store.finish(current), Ok(true));
    assert!(store.admit(&camera, WorkKind::Refresh).unwrap().is_some());
}

#[test]
fn batch_admits_current_refresh_scopes_in_tracking_order_and_preserves_requests() {
    let camera = permission("camera");
    let microphone = permission("microphone");
    let location = permission("location");
    let mut store = Store::new();
    store
        .track(&[microphone.clone(), camera.clone(), location.clone()])
        .unwrap();
    let request = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    let old = store
        .admit(&microphone, WorkKind::Refresh)
        .unwrap()
        .unwrap();
    let admissions = store.admit_all_refreshes().unwrap();
    assert_eq!(
        admissions,
        [
            RefreshAdmission {
                permission: microphone,
                token: old + 1,
            },
            RefreshAdmission {
                permission: location,
                token: old + 2,
            },
        ]
    );
    assert_eq!(store.finish(old), Ok(false));
    assert_eq!(store.admit(&camera, WorkKind::Refresh), Ok(None));
    assert_eq!(store.finish(request), Ok(true));
    assert_eq!(store.admit_all_refreshes().unwrap().len(), 3);
}

#[test]
fn scoped_admission_does_not_reserve_isolated_invalid_or_cancelled_work() {
    let photos = permission("photos");
    let camera = permission("camera");
    let add_only = Options::Photos {
        photo_access_level: PhotoAccessLevel::AddOnly,
    };
    let mut store = Store::new();
    store.track(&[photos.clone(), camera.clone()]).unwrap();
    let token = store.admit(&photos, WorkKind::Request).unwrap().unwrap();

    for kind in [WorkKind::Refresh, WorkKind::Request] {
        for cancelled in [false, true] {
            assert_eq!(
                store.admit_scoped(&photos, &add_only, kind, cancelled),
                Ok(ScopedAdmission::Isolated)
            );
        }
        assert_eq!(
            store.admit_scoped(&camera, &add_only, kind, false),
            Ok(ScopedAdmission::InvalidOptions)
        );
        assert_eq!(
            store.admit_scoped(&photos, &Options::None, kind, true),
            Ok(ScopedAdmission::Suppressed)
        );
    }
    assert_eq!(
        store.admit_scoped(&photos, &Options::None, WorkKind::Refresh, false),
        Ok(ScopedAdmission::Suppressed)
    );
    assert_eq!(
        store.admit_scoped(
            &permission("contacts"),
            &Options::None,
            WorkKind::Refresh,
            false
        ),
        Ok(ScopedAdmission::Untracked)
    );
    assert_eq!(store.finish(token), Ok(true));
    assert_eq!(
        store.admit_scoped(&photos, &Options::None, WorkKind::Refresh, false),
        Ok(ScopedAdmission::Stored { token: token + 1 })
    );
}

#[test]
fn admission_and_finish_wire_shapes_preserve_typed_errors_and_token_values() {
    let mut store = Store::new();
    store.track(&[permission("camera")]).unwrap();
    for (input, expected) in [
        (
            json!({"op":"admit","permission":{"id":"camera"},"kind":"request"}),
            json!({"token":1}),
        ),
        (
            json!({"op":"admit","permission":{"id":"camera"},"kind":"refresh"}),
            json!({"token":null}),
        ),
        (json!({"op":"admitAllRefreshes"}), json!([])),
        (
            json!({"op":"admitScoped","permission":{"id":"camera"},"options":{"kind":"photos","photoAccessLevel":"addOnly"},"kind":"request","cancelled":false}),
            json!({"kind":"invalidOptions"}),
        ),
        (
            json!({"op":"finish","token":999}),
            json!({"finished":false}),
        ),
        (json!({"op":"finish","token":1}), json!({"finished":true})),
        (
            json!({"op":"admit","permission":{"id":"camera"},"kind":"refresh"}),
            json!({"token":2}),
        ),
        (
            json!({"op":"admit","permission":{"id":"microphone"},"kind":"request"}),
            json!({"token":null}),
        ),
        (
            json!({"op":"admitAllRefreshes"}),
            json!([{"permission":{"id":"camera"},"token":3}]),
        ),
    ] {
        assert_eq!(
            store
                .dispatch(parse_store(&serde_json::to_vec(&input).unwrap()).unwrap())
                .unwrap(),
            expected
        );
    }
    for input in [
        json!({"op":"admit","permission":{"id":"camera"}}),
        json!({"op":"admit","permission":{"id":"camera"},"kind":"query"}),
        json!({"op":"admit","permission":{"id":"camera"},"kind":null}),
        json!({"op":"admit","permission":{"id":"camera"},"kind":0}),
        json!({"op":"admit","permission":{"id":"camera"},"kind":{"refresh":null}}),
        json!({"op":"admit","permission":{"id":"camera"},"kind":"request","extra":true}),
        json!({"op":"admitAllRefreshes","extra":true}),
        json!({"op":"finish","token":1,"permission":{"id":"camera"}}),
        json!({"op":"finish","token":null}),
    ] {
        assert_eq!(
            parse_store(&serde_json::to_vec(&input).unwrap()).unwrap_err(),
            Error::InvalidJson
        );
    }
    assert_eq!(
        store.dispatch(StoreRequest::Finish { token: 0 }),
        Err(Error::InvalidToken)
    );
    assert_eq!(serde_json::to_value(WorkKind::Refresh).unwrap(), "refresh");
    assert_eq!(serde_json::to_value(WorkKind::Request).unwrap(), "request");
}
