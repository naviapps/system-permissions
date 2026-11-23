use crate::*;
use permissions_core::{MAX_INPUT_BYTES, MAX_PERMISSIONS};
use serde_json::{Value, json};

unsafe fn copied_bytes(result: *mut SystemPermissionsResult) -> (u32, Vec<u8>) {
    assert!(!result.is_null());
    unsafe {
        let status = system_permissions_result_status(result);
        let bytes = std::slice::from_raw_parts(
            system_permissions_result_data(result),
            system_permissions_result_len(result),
        )
        .to_vec();
        system_permissions_result_free(result);
        (status, bytes)
    }
}

unsafe fn copied(result: *mut SystemPermissionsResult) -> (u32, Value) {
    let (status, bytes) = unsafe { copied_bytes(result) };
    (status, serde_json::from_slice(&bytes).unwrap())
}
fn expect_wire(input: &str, status: u32, response: &str) {
    let (actual_status, actual_response) =
        unsafe { copied_bytes(system_permissions_call(input.as_ptr(), input.len())) };
    assert_eq!(actual_status, status, "{input}");
    assert_eq!(actual_response, response.as_bytes(), "{input}");
}

unsafe fn store_query(store: *mut SystemPermissionsStore, value: Value) -> (u32, Value) {
    let data = serde_json::to_vec(&value).unwrap();
    unsafe {
        copied(system_permissions_store_call(
            store,
            data.as_ptr(),
            data.len(),
        ))
    }
}

#[test]
fn result_owns_a_copy_of_input_and_multiple_results_are_independent() {
    unsafe {
        let first = {
            let input = br#"{"op":"validateDescriptor","permission":{"id":"camera"}}"#.to_vec();
            system_permissions_call(input.as_ptr(), input.len())
        };
        let access_queries = [
            (r#"{"op":"allowsAccess","status":"limited"}"#, "true"),
            (r#"{"op":"allowsAccess","status":"unknown"}"#, "false"),
        ];
        for (input, response) in access_queries.into_iter().cycle().take(1_000) {
            expect_wire(input, 0, response);
        }
        assert_eq!(copied(first), (0, json!({"id":"camera"})));
    }
}

#[test]
fn status_and_settings_results_have_distinct_supported_payloads() {
    for (status, access) in [
        ("granted", "true"),
        ("limited", "true"),
        ("provisional", "true"),
        ("ephemeral", "true"),
        ("denied", "false"),
        ("restricted", "false"),
        ("notDetermined", "false"),
        ("unknown", "false"),
    ] {
        let result = format!(r#"{{"kind":"supported","value":"{status}"}}"#);
        expect_wire(
            &format!(r#"{{"op":"allowsAccess","status":"{status}"}}"#),
            0,
            access,
        );
        expect_wire(
            &format!(r#"{{"op":"validateResult","result":{result}}}"#),
            0,
            &result,
        );
        expect_wire(
            &format!(r#"{{"op":"resultAllowsAccess","result":{result}}}"#),
            0,
            access,
        );
        expect_wire(
            &format!(r#"{{"op":"validateSettingsResult","result":{result}}}"#),
            1,
            r#"{"error":"invalidJson"}"#,
        );
    }
    for value in ["true", "false"] {
        let result = format!(r#"{{"kind":"supported","value":{value}}}"#);
        expect_wire(
            &format!(r#"{{"op":"validateSettingsResult","result":{result}}}"#),
            0,
            &result,
        );
        for op in ["validateResult", "resultAllowsAccess"] {
            expect_wire(
                &format!(r#"{{"op":"{op}","result":{result}}}"#),
                1,
                r#"{"error":"invalidJson"}"#,
            );
        }
    }
}

#[test]
fn unsupported_and_failed_results_keep_their_payload_without_granting_access() {
    for result in [
        r#"{"error":"invalidOptions","kind":"failed"}"#,
        r#"{"error":"openFailed","kind":"failed"}"#,
        r#"{"error":"apiUnavailable","kind":"failed"}"#,
        r#"{"capability":{"requiresRelaunch":true,"supportsRequest":false,"supportsStatusCheck":true},"kind":"unsupported"}"#,
        r#"{"capability":{"requiresRelaunch":false,"supportsRequest":false,"supportsStatusCheck":true,"systemSettingsUrl":"example:é"},"kind":"unsupported"}"#,
    ] {
        for op in ["validateResult", "validateSettingsResult"] {
            expect_wire(&format!(r#"{{"op":"{op}","result":{result}}}"#), 0, result);
        }
        expect_wire(
            &format!(r#"{{"op":"resultAllowsAccess","result":{result}}}"#),
            0,
            "false",
        );
    }
}

#[test]
fn malformed_result_envelopes_and_invalid_capabilities_are_distinct_wire_errors() {
    let capability = r#"{"kind":"unsupported","capability":{"requiresRelaunch":false,"supportsRequest":false,"supportsStatusCheck":false,"systemSettingsUrl":"relative/path"}}"#;
    for op in [
        "validateResult",
        "validateSettingsResult",
        "resultAllowsAccess",
    ] {
        expect_wire(
            &format!(r#"{{"op":"{op}","result":{capability}}}"#),
            1,
            r#"{"error":"invalidResult"}"#,
        );
        for result in [
            r#"{"kind":"supported"}"#,
            r#"{"kind":"supported","value":1}"#,
            r#"{"kind":"supported","value":null}"#,
            r#"{"kind":"supported","value":"granted","error":"apiUnavailable"}"#,
            r#"{"kind":"supported","value":true,"error":"openFailed"}"#,
            r#"{"kind":"deferred"}"#,
            r#"{"kind":"unsupported","capability":{"supportsStatusCheck":false,"supportsRequest":false,"requiresRelaunch":false,"extra":true}}"#,
            r#"{"kind":"failed","error":"other"}"#,
            r#"{"kind":"failed","error":"openFailed","value":true}"#,
            r#"{"kind":"failed","error":"openFailed","error":"apiUnavailable"}"#,
        ] {
            expect_wire(
                &format!(r#"{{"op":"{op}","result":{result}}}"#),
                1,
                r#"{"error":"invalidJson"}"#,
            );
        }
    }
    expect_wire(
        r#"{"op":"allowsAccess","status":"GRANTED"}"#,
        1,
        r#"{"error":"invalidJson"}"#,
    );
}

#[test]
fn extended_dispatch_preserves_strict_core_and_native_payload_validation() {
    for input in [
        r#"{"op":"builtIns","extra":1}"#,
        r#"{"op":"builtIns","op":"windowsStatus","permission":{"id":"camera"},"options":{"kind":"none"}}"#,
        r#"{"op":"validateOptions","permission":{"id":"camera"},"options":{"kind":"none","extra":1}}"#,
        r#"{"op":"windowsStatus","permission":{"id":"camera","id":"microphone"},"options":{"kind":"none"}}"#,
        r#"{"op":"windowsStatus","permission":["camera"],"options":{"kind":"none"}}"#,
        r#"{"op":"windowsRequest","permission":{"id":"camera"},"options":{"kind":"none"},"extra":1}"#,
        r#"{"op":"windowsPollRequest","token":1,"token":2}"#,
        r#"{"op":"windowsCancelRequest","token":1,"permission":{"id":"camera"}}"#,
    ] {
        let (status, _) = unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) };
        assert_eq!(status, 1, "Accepted malformed extended command: {input}");
    }
    for op in ["windowsStatus", "windowsRequest", "windowsOpenSettings"] {
        let input = serde_json::to_vec(
            &json!({"op":op,"permission":{"id":"automation"},"options":{"kind":"none"}}),
        )
        .unwrap();
        assert_eq!(
            unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) }.0,
            1
        );
    }
}

#[test]
fn portable_descriptors_require_objects_at_each_native_boundary() {
    for descriptor in [
        r#"["camera"]"#,
        r#"{"id":"camera","id":"microphone"}"#,
        r#"{"id":"camera"},"permission":{"id":"microphone"}"#,
        r#"{"id":"camera","extra":true}"#,
        r#"{"id":"com.example.custom","custom":[[true,false,"example:settings",false],[]]}"#,
        r#"{"id":"com.example.custom","custom":{"capability":[true,false,"example:settings",false],"usageDescriptionKeys":[]}}"#,
    ] {
        let input = format!(r#"{{"op":"validateDescriptor","permission":{descriptor}}}"#);
        assert_eq!(
            unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) },
            (1, json!({"error":"invalidJson"})),
            "{descriptor}"
        );
    }

    let mut input = br#"{"op":"validateDescriptor","permission":{"id":"camera"}}"#.to_vec();
    input.resize(MAX_INPUT_BYTES, b' ');
    assert_eq!(
        unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) },
        (0, json!({"id":"camera"}))
    );
    input.push(b' ');
    assert_eq!(
        unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) },
        (1, json!({"error":"inputTooLarge"}))
    );
}

#[test]
fn custom_metadata_preserves_exact_settings_text_and_rejects_tracking_conflicts() {
    let keys = [
        "NSCameraUsageDescription",
        "HostUsageKey",
        "Fixtureé",
        "Fixturee\u{301}",
    ];
    let raw_keys = [keys[0], keys[1], keys[2], keys[1], keys[3]];
    let descriptors = ["example:é", "example:%C3%A9", "example:e\u{301}"].map(|destination| {
        json!({
            "id": "com.example.privacy",
            "custom": {
                "capability": {
                    "supportsStatusCheck": true,
                    "supportsRequest": false,
                    "systemSettingsUrl": destination,
                    "requiresRelaunch": false
                },
                "usageDescriptionKeys": raw_keys
            }
        })
    });
    for (index, descriptor) in descriptors.iter().enumerate() {
        let capability = &descriptor["custom"]["capability"];
        for platform in ["macos", "windows"] {
            let query = json!({"op":"metadata","permission":descriptor,"platform":platform});
            let bytes = serde_json::to_vec(&query).unwrap();
            assert_eq!(
                unsafe { copied(system_permissions_call(bytes.as_ptr(), bytes.len())) },
                (
                    0,
                    json!({
                        "capability":capability,
                        "defaultOptions":{"kind":"none"},
                        "usageDescriptionKeys":keys
                    })
                ),
                "{platform}, {capability}"
            );
        }
        let mut canonical = descriptor.clone();
        canonical["custom"]["usageDescriptionKeys"] = json!(keys);
        let snapshot = json!({"values":[{
            "permission":canonical,
            "result":{"kind":"supported","value":"unknown"}
        }]});
        unsafe {
            let store = system_permissions_store_new();
            assert!(!store.is_null());
            assert_eq!(
                store_query(
                    store,
                    json!({"op":"track","permissions":[descriptor,canonical]})
                ),
                (0, snapshot.clone())
            );
            for (other_index, other) in descriptors.iter().enumerate() {
                if index == other_index {
                    continue;
                }
                assert_eq!(
                    store_query(
                        store,
                        json!({"op":"track","permissions":[descriptor,other]})
                    ),
                    (1, json!({"error":"inconsistentMetadata"})),
                    "{capability}, {}",
                    other["custom"]["capability"]
                );
                assert_eq!(
                    store_query(store, json!({"op":"snapshot"})),
                    (0, snapshot.clone())
                );
            }
            system_permissions_store_free(store);
        }
    }
}

#[cfg(not(windows))]
#[test]
fn explicit_windows_operations_never_infer_native_access_on_other_platforms() {
    for op in ["windowsStatus", "windowsOpenSettings"] {
        let input = serde_json::to_vec(
            &json!({"op":op,"permission":{"id":"camera"},"options":{"kind":"none"}}),
        )
        .unwrap();
        assert_eq!(
            unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) },
            (0, json!({"kind":"failed","error":"apiUnavailable"}))
        );
    }
    for input in [
        json!({"op":"windowsRequest","permission":{"id":"camera"},"options":{"kind":"none"}}),
        json!({"op":"windowsPollRequest","token":1}),
    ] {
        let input = serde_json::to_vec(&input).unwrap();
        assert_eq!(
            unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) },
            (
                0,
                json!({"result":{"kind":"failed","error":"apiUnavailable"}})
            )
        );
    }
    let input = br#"{"op":"windowsCancelRequest","token":1}"#;
    assert_eq!(
        unsafe { copied(system_permissions_call(input.as_ptr(), input.len())) },
        (1, json!({"error":"apiUnavailable"}))
    );
}

#[test]
fn null_empty_oversize_invalid_utf8_and_malformed_inputs_have_owned_typed_errors() {
    unsafe {
        assert_eq!(
            copied(system_permissions_call(std::ptr::null(), 0)),
            (1, json!({"error":"invalidBuffer"}))
        );
        assert_eq!(
            copied(system_permissions_call(std::ptr::null(), 1)),
            (1, json!({"error":"invalidBuffer"}))
        );
        // Pointer is never dereferenced for an oversized length.
        assert_eq!(
            copied(system_permissions_call(
                std::ptr::dangling(),
                MAX_INPUT_BYTES + 1
            )),
            (1, json!({"error":"inputTooLarge"}))
        );
        for (input, error) in [
            (&b""[..], "invalidJson"),
            (&[0xff][..], "invalidUtf8"),
            (&b"{"[..], "invalidJson"),
        ] {
            assert_eq!(
                copied(system_permissions_call(input.as_ptr(), input.len())),
                (1, json!({"error":error}))
            );
        }
        assert_eq!(system_permissions_result_status(std::ptr::null()), 1);
        assert!(system_permissions_result_data(std::ptr::null()).is_null());
        assert_eq!(system_permissions_result_len(std::ptr::null()), 0);
        system_permissions_result_free(std::ptr::null_mut());
        system_permissions_store_free(std::ptr::null_mut());
        let input = br#"{"op":"snapshot"}"#;
        assert_eq!(
            copied(system_permissions_store_call(
                std::ptr::null_mut(),
                input.as_ptr(),
                input.len()
            )),
            (1, json!({"error":"invalidBuffer"}))
        );
    }
}

#[test]
fn owned_snapshot_outlives_its_store_and_does_not_change_with_later_mutation() {
    unsafe {
        let store = system_permissions_store_new();
        assert!(!store.is_null());
        assert_eq!(
            store_query(store, json!({"op":"track","permissions":[{"id":"camera"}]})).0,
            0
        );
        let input = br#"{"op":"snapshot"}"#;
        let snapshot = system_permissions_store_call(store, input.as_ptr(), input.len());
        let (_, token) = store_query(store, json!({"op":"begin","permission":{"id":"camera"}}));
        let token = token["token"].as_u64().unwrap();
        assert_eq!(
            store_query(
                store,
                json!({"op":"apply","updates":[{"permission":{"id":"camera"},"token":token,"result":{"kind":"supported","value":"granted"}}],"cancelled":false})
            ),
            (0, json!({"changed":true,"accepted":1}))
        );
        system_permissions_store_free(store);
        assert_eq!(
            copied(snapshot),
            (
                0,
                json!({"values":[{"permission":{"id":"camera"},"result":{"kind":"supported","value":"unknown"}}]})
            )
        );
    }
}

#[test]
fn admission_keeps_observations_separate_and_returns_exact_tokens_and_errors() {
    let store = system_permissions_store_new();
    assert!(!store.is_null());
    for (input, status, expected) in [
        (
            r#"{"op":"track","permissions":[{"id":"camera"}]}"#,
            0,
            r#"{"values":[{"permission":{"id":"camera"},"result":{"kind":"supported","value":"unknown"}}]}"#,
        ),
        (
            r#"{"op":"admit","permission":{"id":"camera"},"kind":"request"}"#,
            0,
            r#"{"token":1}"#,
        ),
        (
            r#"{"op":"recordObservation","permission":{"id":"camera"},"result":{"kind":"supported","value":"denied"}}"#,
            0,
            r#"{"previousResult":null,"result":{"kind":"supported","value":"denied"}}"#,
        ),
        (
            r#"{"op":"recordObservation","permission":{"id":"camera"},"result":{"kind":"supported","value":"granted"}}"#,
            0,
            r#"{"previousResult":{"kind":"supported","value":"denied"},"result":{"kind":"supported","value":"granted"}}"#,
        ),
        (
            r#"{"op":"recordObservation","permission":{"id":"camera"},"result":{"kind":"supported","value":"granted"}}"#,
            0,
            r#"{"previousResult":null,"result":{"kind":"supported","value":"granted"}}"#,
        ),
        (
            r#"{"op":"get","permission":{"id":"camera"}}"#,
            0,
            r#"{"kind":"supported","value":"unknown"}"#,
        ),
        (
            r#"{"op":"admit","permission":{"id":"camera"},"kind":"refresh"}"#,
            0,
            r#"{"token":null}"#,
        ),
        (r#"{"op":"finish","token":999}"#, 0, r#"{"finished":false}"#),
        (
            r#"{"op":"begin","permission":{"id":"camera"}}"#,
            0,
            r#"{"token":2}"#,
        ),
        (r#"{"op":"finish","token":1}"#, 0, r#"{"finished":false}"#),
        (
            r#"{"op":"admit","permission":{"id":"camera"},"kind":"refresh"}"#,
            0,
            r#"{"token":3}"#,
        ),
        (r#"{"op":"finish","token":3}"#, 0, r#"{"finished":true}"#),
        (r#"{"op":"finish","token":3}"#, 0, r#"{"finished":false}"#),
        (
            r#"{"op":"finish","token":0}"#,
            1,
            r#"{"error":"invalidToken"}"#,
        ),
        (
            r#"{"op":"admit","permission":{"id":"camera"},"kind":"query"}"#,
            1,
            r#"{"error":"invalidJson"}"#,
        ),
    ] {
        let (actual_status, actual) = unsafe {
            copied_bytes(system_permissions_store_call(
                store,
                input.as_ptr(),
                input.len(),
            ))
        };
        assert_eq!(actual_status, status, "{input}");
        assert_eq!(std::str::from_utf8(&actual).unwrap(), expected, "{input}");
    }
    unsafe { system_permissions_store_free(store) };
}

#[test]
fn store_batch_budgets_reject_excess_without_consuming_admitted_work() {
    expect_wire(
        r#"{"op":"storeBatchLimit"}"#,
        0,
        &MAX_PERMISSIONS.to_string(),
    );

    let store = system_permissions_store_new();
    assert!(!store.is_null());
    let query = |value| unsafe { store_query(store, value) };
    let camera = json!({"id":"camera"});
    let original = json!({"values":[{
        "permission":camera,
        "result":{"kind":"supported","value":"unknown"}
    }]});
    assert_eq!(
        query(json!({"op":"track","permissions":vec![camera.clone(); MAX_PERMISSIONS]})),
        (0, original.clone())
    );
    assert_eq!(
        query(json!({"op":"begin","permission":camera})),
        (0, json!({"token":1}))
    );

    let mut excess_permissions = vec![json!({"id":"microphone"}); MAX_PERMISSIONS + 1];
    assert_eq!(
        query(json!({"op":"track","permissions":excess_permissions})),
        (1, json!({"error":"limitExceeded"}))
    );
    assert_eq!(query(json!({"op":"snapshot"})), (0, original.clone()));
    excess_permissions[0] = Value::Null;
    assert_eq!(
        query(json!({"op":"track","permissions":excess_permissions})),
        (1, json!({"error":"invalidJson"}))
    );
    assert_eq!(query(json!({"op":"snapshot"})), (0, original.clone()));

    let granted = json!({"kind":"supported","value":"granted"});
    let untracked_updates = (1..=MAX_PERMISSIONS).map(|index| {
        json!({
            "permission":{"id":"automation","targetApplication":format!("com.example.Target{index}")},
            "token":1,"result":granted
        })
    });
    let mut updates: Vec<_> = std::iter::once(json!({
        "permission":camera,"token":1,"result":granted
    }))
    .chain(untracked_updates)
    .collect();
    assert_eq!(
        query(json!({"op":"apply","updates":updates,"cancelled":false})),
        (1, json!({"error":"limitExceeded"}))
    );
    assert_eq!(query(json!({"op":"snapshot"})), (0, original.clone()));

    updates.pop().unwrap();
    let mut input =
        serde_json::to_vec(&json!({"op":"apply","updates":updates,"cancelled":false})).unwrap();
    assert!(input.len() < MAX_INPUT_BYTES);
    input.resize(MAX_INPUT_BYTES + 1, b' ');
    let submit = |bytes: &[u8]| unsafe {
        copied_bytes(system_permissions_store_call(
            store,
            bytes.as_ptr(),
            bytes.len(),
        ))
    };
    assert_eq!(
        submit(&input),
        (1, br#"{"error":"inputTooLarge"}"#.to_vec())
    );
    assert_eq!(query(json!({"op":"snapshot"})), (0, original));
    assert_eq!(
        submit(&input[..MAX_INPUT_BYTES]),
        (0, br#"{"accepted":1,"changed":true}"#.to_vec())
    );
    assert_eq!(
        query(json!({"op":"snapshot"})),
        (
            0,
            json!({"values":[{"permission":camera,"result":granted}]})
        )
    );
    unsafe { system_permissions_store_free(store) };
}

#[test]
fn malformed_batch_leaves_the_stores_existing_token_and_state_intact() {
    unsafe {
        let store = system_permissions_store_new();
        store_query(store, json!({"op":"track","permissions":[{"id":"camera"}]}));
        let (_, token) = store_query(store, json!({"op":"begin","permission":{"id":"camera"}}));
        let token = token["token"].as_u64().unwrap();
        let valid = json!({"permission":{"id":"camera"},"token":token,"result":{"kind":"supported","value":"granted"}});
        let invalid = json!({"permission":{"id":"microphone"},"token":token,"result":{"kind":"supported","value":"invalid-status"}});
        assert_eq!(
            store_query(
                store,
                json!({"op":"apply","updates":[valid,invalid],"cancelled":false})
            )
            .0,
            1
        );
        assert_eq!(
            store_query(store, json!({"op":"get","permission":{"id":"camera"}})),
            (0, json!({"kind":"supported","value":"unknown"}))
        );
        assert_eq!(
            store_query(
                store,
                json!({"op":"apply","updates":[valid],"cancelled":false})
            ),
            (0, json!({"changed":true,"accepted":1}))
        );
        system_permissions_store_free(store);
    }
}

#[test]
fn malformed_positional_state_objects_are_rejected_without_losing_admitted_work() {
    unsafe {
        let store = system_permissions_store_new();
        let (status, snapshot) =
            store_query(store, json!({"op":"track","permissions":[{"id":"camera"}]}));
        assert_eq!(status, 0);
        assert_eq!(
            store_query(store, json!({"op":"begin","permission":{"id":"camera"}})),
            (0, json!({"token":1}))
        );
        for input in [
            json!({"op":"track","permissions":[["microphone"]]}),
            json!({"op":"apply","updates":[[{"id":"camera"},1,{"kind":"supported","value":"denied"}]],"cancelled":false}),
            json!({"op":"apply","updates":[{"permission":["camera"],"token":1,"result":{"kind":"supported","value":"denied"}}],"cancelled":false}),
            json!({"op":"apply","updates":[{"permission":{"id":"camera"},"token":1,"result":{"kind":"unsupported","capability":[false,false,"example:settings",false]}}],"cancelled":false}),
        ] {
            assert_eq!(
                store_query(store, input),
                (1, json!({"error":"invalidJson"}))
            );
            assert_eq!(
                store_query(store, json!({"op":"snapshot"})),
                (0, snapshot.clone())
            );
        }
        assert_eq!(
            store_query(
                store,
                json!({"op":"apply","updates":[{"permission":{"id":"camera"},"token":1,"result":{"kind":"supported","value":"granted"}}],"cancelled":false})
            ),
            (0, json!({"changed":true,"accepted":1}))
        );
        system_permissions_store_free(store);
    }
}

#[test]
fn concurrent_begin_calls_have_unique_tokens_and_cannot_alias_mutable_state() {
    unsafe {
        let store = system_permissions_store_new();
        store_query(store, json!({"op":"track","permissions":[{"id":"camera"}]}));
        let address = store as usize;
        let workers: Vec<_> = (0..8)
            .map(|_| {
                std::thread::spawn(move || {
                    let store = address as *mut SystemPermissionsStore;
                    (0..32)
                        .map(|_| {
                            let (status, result) = store_query(
                                store,
                                json!({"op":"begin","permission":{"id":"camera"}}),
                            );
                            assert_eq!(status, 0);
                            result["token"].as_u64().unwrap()
                        })
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        let mut tokens: Vec<_> = workers
            .into_iter()
            .flat_map(|worker| worker.join().unwrap())
            .collect();
        tokens.sort_unstable();
        assert_eq!(tokens, (1..=256).collect::<Vec<_>>());
        let stale = json!({"permission":{"id":"camera"},"token":255,"result":{"kind":"supported","value":"granted"}});
        assert_eq!(
            store_query(
                store,
                json!({"op":"apply","updates":[stale],"cancelled":false})
            ),
            (0, json!({"changed":false,"accepted":0}))
        );
        system_permissions_store_free(store);
    }
}
