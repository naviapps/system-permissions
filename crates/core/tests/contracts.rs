use serde::Deserialize;
use serde_json::{Value, json};
use system_permissions::*;

fn query(value: Value) -> Result<Value, Error> {
    call(&serde_json::to_vec(&value).unwrap())
}
fn descriptor(value: Value) -> Descriptor {
    serde_json::from_value(value).unwrap()
}
fn custom(id: &str) -> Value {
    json!({"id":id,"custom":{
        "capability":{"supportsStatusCheck":true,"supportsRequest":false,"requiresRelaunch":false},
        "usageDescriptionKeys":["NSCameraUsageDescription"]
    }})
}

#[test]
fn built_ins_keep_all_24_ids_but_never_make_an_unscoped_automation() {
    assert_eq!(BUILT_IN_IDS.len(), 24);
    let values = query(json!({"op":"builtIns"})).unwrap();
    let descriptors: Vec<Descriptor> = serde_json::from_value(values).unwrap();
    assert_eq!(descriptors.len(), 23);
    assert_eq!(descriptors[0].id, "accessibility");
    assert_eq!(
        descriptors
            .iter()
            .map(|descriptor| &descriptor.id)
            .collect::<std::collections::HashSet<_>>()
            .len(),
        descriptors.len()
    );
    for descriptor in descriptors {
        assert_ne!(descriptor.id, "automation");
        assert_eq!(descriptor.validated().unwrap(), descriptor);
    }
    assert_eq!(
        Descriptor::built_in("automation"),
        Err(Error::InvalidTargetApplication)
    );
}

#[test]
fn custom_identifier_reasons_and_precedence_match_the_original_contract() {
    let cases = [
        ("", "empty"),
        ("camera", "reserved"),
        ("custom", "missingNamespace"),
        ("custom.", "emptySegment"),
        ("custom..permission", "emptySegment"),
        ("custom.-permission", "invalidSegmentBoundary"),
        ("custom.permission_", "invalidSegmentBoundary"),
        ("custom.permission-", "invalidSegmentBoundary"),
        ("Com.Example", "invalidCharacter"),
        ("custom/permission", "invalidCharacter"),
        ("com.é", "invalidCharacter"),
        (" custom.id", "invalidCharacter"),
    ];
    for (identifier, reason) in cases {
        assert_eq!(
            query(json!({"op":"validateIdentifier","identifier":identifier})).unwrap(),
            json!({"error":reason})
        );
    }
    for id in BUILT_IN_IDS {
        assert_eq!(
            validate_identifier(id),
            Some(IdentifierValidationError::Reserved)
        );
    }
    for id in ["com.example.permission", "custom.permission_1-alpha", "1.2"] {
        assert_eq!(
            query(json!({"op":"validateIdentifier","identifier":id})).unwrap(),
            json!({})
        );
    }
}

#[test]
fn descriptors_require_targeted_automation_and_reject_mixed_payloads() {
    let target = json!({"id":"automation","targetApplication":"com.apple.TextEdit"});
    assert_eq!(
        query(json!({"op":"validateDescriptor","permission":target})).unwrap(),
        target
    );
    for bad in [
        "",
        "com..apple",
        "Safari",
        " com.apple.Safari",
        "com.apple.Safari ",
        "/Applications/Safari.app",
        "https://example.com",
        "com.apple.*",
        "com.apple.\nSafari",
        "com.example.\u{212a}eyboard",
    ] {
        assert!(query(json!({"op":"validateDescriptor","permission":{"id":"automation","targetApplication":bad}})).is_err(), "{bad:?}");
    }
    for value in [
        json!({"id":"missing"}),
        json!({"id":"camera","targetApplication":"com.apple.Safari"}),
        json!({"id":"camera","custom":custom("com.test.camera")["custom"]}),
        json!({"id":"automation","targetApplication":"com.apple.Safari","custom":custom("com.test.camera")["custom"]}),
        json!({"id":"com.test.custom"}),
        json!({"id":"com.test.custom","targetApplication":"com.apple.Safari","custom":custom("com.test.camera")["custom"]}),
    ] {
        assert!(query(json!({"op":"validateDescriptor","permission":value})).is_err());
    }
}

#[test]
fn custom_metadata_is_host_owned_and_canonical_usage_keys_preserve_first_order() {
    let mut permission = custom("com.example.permission");
    permission["custom"]["usageDescriptionKeys"] = json!([
        "NSCameraUsageDescription",
        "HostUsageKey",
        "NSCameraUsageDescription"
    ]);
    let canonical = query(json!({"op":"validateDescriptor","permission":permission})).unwrap();
    assert_eq!(
        canonical["custom"]["usageDescriptionKeys"],
        json!(["NSCameraUsageDescription", "HostUsageKey"])
    );
    for platform in ["macos", "windows"] {
        let metadata =
            query(json!({"op":"metadata","permission":permission,"platform":platform})).unwrap();
        assert_eq!(metadata["capability"], canonical["custom"]["capability"]);
        assert_eq!(
            metadata["usageDescriptionKeys"],
            canonical["custom"]["usageDescriptionKeys"]
        );
    }
    for url in [
        "relative/path",
        "",
        "1scheme:settings",
        "x-test:",
        "x-test:bad settings",
    ] {
        let mut bad = permission.clone();
        bad["custom"]["capability"]["systemSettingsUrl"] = json!(url);
        assert!(query(json!({"op":"validateDescriptor","permission":bad})).is_err());
    }
}

#[test]
fn usage_description_keys_preserve_exact_text_order_and_bounds() {
    let canonical = json!([
        "HostUsageKey",
        "Fixture\u{e9}",
        "Fixturee\u{301}",
        "Fixture😀"
    ]);
    let keys = json!([
        "HostUsageKey",
        "Fixture\u{e9}",
        "Fixturee\u{301}",
        "HostUsageKey",
        "Fixture😀"
    ]);
    assert_eq!(
        query(json!({"op":"validateUsageDescriptionKeys","keys":keys})),
        Ok(canonical.clone())
    );

    let mut permission = custom("com.example.permission");
    permission["custom"]["usageDescriptionKeys"] = keys;
    assert_eq!(
        query(json!({"op":"validateDescriptor","permission":permission})).unwrap()["custom"]["usageDescriptionKeys"],
        canonical
    );
    assert_eq!(
        query(json!({"op":"validateUsageDescriptionKeys","keys":[]})),
        Ok(json!([]))
    );

    for (input, expected) in [
        (json!(vec!["HostUsageKey"; 64]), Ok(json!(["HostUsageKey"]))),
        (json!(vec!["HostUsageKey"; 65]), Err(Error::LimitExceeded)),
        (json!(["é".repeat(512)]), Ok(json!(["é".repeat(512)]))),
        (json!(["é".repeat(513)]), Err(Error::InvalidDescriptor)),
        (json!([""]), Err(Error::InvalidDescriptor)),
        (json!([" HostUsageKey"]), Err(Error::InvalidDescriptor)),
        (
            json!(["HostUsageKey\u{00a0}"]),
            Err(Error::InvalidDescriptor),
        ),
        (json!(["Host\nUsageKey"]), Err(Error::InvalidDescriptor)),
    ] {
        assert_eq!(
            query(json!({"op":"validateUsageDescriptionKeys","keys":input})),
            expected
        );
    }
}

#[test]
fn usage_description_key_json_rejects_unpaired_surrogates() {
    for key in [r"Host\uD800", r"Host\uDC00"] {
        let input = format!(r#"{{"op":"validateUsageDescriptionKeys","keys":["{key}"]}}"#);
        assert_eq!(call(input.as_bytes()), Err(Error::InvalidJson));
    }
    assert_eq!(
        call(br#"{"op":"validateUsageDescriptionKeys","keys":["Host\uFFFD","Host\uD83D\uDE00"]}"#),
        Ok(json!(["Host\u{fffd}", "Host😀"]))
    );
}

#[test]
fn macos_metadata_keeps_settings_support_usage_and_relaunch_contracts() {
    let keys = [
        ("camera", "NSCameraUsageDescription"),
        ("microphone", "NSMicrophoneUsageDescription"),
        ("contacts", "NSContactsUsageDescription"),
        ("calendars", "NSCalendarsFullAccessUsageDescription"),
        ("reminders", "NSRemindersFullAccessUsageDescription"),
        ("photos", "NSPhotoLibraryUsageDescription"),
        ("speech_recognition", "NSSpeechRecognitionUsageDescription"),
        ("location", "NSLocationUsageDescription"),
        ("bluetooth", "NSBluetoothAlwaysUsageDescription"),
        ("local_network", "NSLocalNetworkUsageDescription"),
        ("media_library", "NSAppleMusicUsageDescription"),
        ("system_audio_capture", "NSAudioCaptureUsageDescription"),
        ("desktop_folder", "NSDesktopFolderUsageDescription"),
        ("documents_folder", "NSDocumentsFolderUsageDescription"),
        ("downloads_folder", "NSDownloadsFolderUsageDescription"),
        ("network_volumes", "NSNetworkVolumesUsageDescription"),
        ("removable_volumes", "NSRemovableVolumesUsageDescription"),
        (
            "file_provider_domain",
            "NSFileProviderDomainUsageDescription",
        ),
        ("automation", "NSAppleEventsUsageDescription"),
    ];
    let direct = [
        "input_monitoring",
        "automation",
        "accessibility",
        "screen_recording",
        "camera",
        "microphone",
        "contacts",
        "calendars",
        "reminders",
        "photos",
        "speech_recognition",
        "notifications",
    ];
    for id in BUILT_IN_IDS {
        let permission = if id == "automation" {
            descriptor(json!({"id":id,"targetApplication":"com.apple.Safari"}))
        } else {
            Descriptor::built_in(id).unwrap()
        };
        let value = metadata(&permission, Platform::Macos, None).unwrap();
        assert!(
            value
                .capability
                .system_settings_url
                .as_ref()
                .unwrap()
                .starts_with("x-apple.systempreferences:")
        );
        assert_eq!(
            value.capability.supports_status_check,
            direct.contains(&id),
            "{id}"
        );
        assert_eq!(
            value.capability.supports_request,
            direct.contains(&id),
            "{id}"
        );
        assert_eq!(
            value.capability.requires_relaunch,
            ["input_monitoring", "screen_recording", "full_disk_access"].contains(&id)
        );
        let expected: Vec<String> = keys
            .iter()
            .filter(|(name, _)| *name == id)
            .map(|(_, key)| key.to_string())
            .collect();
        assert_eq!(value.usage_description_keys, expected, "{id}");
    }
    for (id, destination) in [
        (
            "accessibility",
            "com.apple.preference.security?Privacy_Accessibility",
        ),
        (
            "notifications",
            "com.apple.preference.notifications?Notifications",
        ),
        (
            "documents_folder",
            "com.apple.preference.security?Privacy_FilesAndFolders",
        ),
    ] {
        let actual = metadata(&Descriptor::built_in(id).unwrap(), Platform::Macos, None)
            .unwrap()
            .capability
            .system_settings_url;
        assert_eq!(
            actual,
            Some(format!("x-apple.systempreferences:{destination}"))
        );
    }
}

#[test]
fn windows_does_not_invent_macos_authorization_or_usage_descriptions() {
    for id in BUILT_IN_IDS {
        let permission = if id == "automation" {
            descriptor(json!({"id":id,"targetApplication":"com.apple.TextEdit"}))
        } else {
            Descriptor::built_in(id).unwrap()
        };
        let value = metadata(&permission, Platform::Windows, None).unwrap();
        assert!(value.usage_description_keys.is_empty());
        assert!(!value.capability.requires_relaunch);
        let expected_url = match id {
            "camera" => Some("ms-settings:privacy-webcam"),
            "microphone" => Some("ms-settings:privacy-microphone"),
            "location" => Some("ms-settings:privacy-location"),
            _ => None,
        };
        assert_eq!(
            value.capability.system_settings_url.as_deref(),
            expected_url,
            "{id}"
        );
        assert_eq!(
            value.capability.supports_status_check,
            expected_url.is_some(),
            "{id}"
        );
        assert_eq!(
            value.capability.supports_request,
            expected_url.is_some(),
            "{id}"
        );
    }
}

#[test]
fn direct_admission_matches_the_existing_metadata_decisions() {
    let mut descriptors: Vec<Value> = BUILT_IN_IDS
        .iter()
        .map(|&id| {
            if id == "automation" {
                json!({"id":id,"targetApplication":"com.example.Editor"})
            } else {
                json!({"id":id})
            }
        })
        .collect();
    for (status, request) in [(true, false), (false, true), (false, false), (true, true)] {
        let mut permission = custom("com.example.access");
        permission["custom"]["capability"] = json!({
            "supportsStatusCheck":status, "supportsRequest":request,
            "systemSettingsUrl":"app-settings:privacy", "requiresRelaunch":true
        });
        descriptors.push(permission);
    }
    let option_cases = [
        None,
        Some(json!({"kind":"none"})),
        Some(json!({"kind":"notifications","notificationOptions":u64::MAX})),
        Some(json!({"kind":"photos","photoAccessLevel":"addOnly"})),
    ];
    for platform in ["macos", "windows"] {
        for permission in &descriptors {
            for options in &option_cases {
                let mut metadata_request =
                    json!({"op":"metadata","platform":platform,"permission":permission});
                if let Some(options) = options {
                    metadata_request["options"] = options.clone();
                }
                let metadata = query(metadata_request.clone());
                for (request, capability_key) in
                    [(false, "supportsStatusCheck"), (true, "supportsRequest")]
                {
                    let expected = match &metadata {
                        Err(Error::InvalidOptions) => {
                            json!({"result":{"kind":"failed","error":"invalidOptions"}})
                        }
                        Ok(metadata) if metadata["capability"][capability_key] == true => {
                            json!({"options":options.as_ref().unwrap_or(&metadata["defaultOptions"])})
                        }
                        Ok(metadata) => {
                            json!({"result":{"kind":"unsupported","capability":metadata["capability"]}})
                        }
                        Err(error) => panic!("unexpected metadata error: {error}"),
                    };
                    let mut command = metadata_request.clone();
                    command["op"] = json!("admitAccess");
                    command["request"] = json!(request);
                    assert_eq!(query(command.clone()), Ok(expected), "{command}");
                }
            }
        }
    }
}

#[test]
fn direct_admission_keeps_descriptor_errors_and_rejects_null_options() {
    assert_eq!(
        query(
            json!({"op":"admitAccess","platform":"macos","request":false,
            "permission":{"id":"automation"},"options":{"kind":"photos","photoAccessLevel":"addOnly"}})
        ),
        Err(Error::InvalidTargetApplication)
    );
    assert_eq!(
        query(
            json!({"op":"admitAccess","platform":"windows","request":true,
            "permission":{"id":"camera"},"options":null})
        ),
        Err(Error::InvalidJson)
    );
}

#[test]
fn settings_admission_resolves_each_platform_and_preserves_descriptor_errors() {
    for platform in ["macos", "windows"] {
        for id in BUILT_IN_IDS {
            let permission = if id == "automation" {
                json!({"id":id,"targetApplication":"com.example.Editor"})
            } else {
                json!({"id":id})
            };
            let metadata =
                query(json!({"op":"metadata","platform":platform,"permission":permission}))
                    .unwrap();
            let capability = &metadata["capability"];
            let expected = if capability.get("systemSettingsUrl").is_some() {
                json!({"capability":capability})
            } else {
                json!({"result":{"kind":"unsupported","capability":capability}})
            };
            assert_eq!(
                query(json!({"op":"admitSettings","platform":platform,"permission":permission})),
                Ok(expected),
                "{platform} {id}"
            );
        }
    }
    let options = json!({"kind":"photos","photoAccessLevel":"addOnly"});
    assert_eq!(
        query(
            json!({"op":"admitSettings","platform":"windows","permission":{"id":"accessibility"},"options":options})
        ),
        Ok(json!({"result":{"kind":"failed","error":"invalidOptions"}}))
    );
    assert_eq!(
        query(
            json!({"op":"admitSettings","platform":"macos","permission":{"id":"automation"},"options":options})
        ),
        Err(Error::InvalidTargetApplication)
    );
    assert_eq!(
        query(
            json!({"op":"admitSettings","platform":"macos","permission":{"id":"photos"},"options":null})
        ),
        Err(Error::InvalidJson)
    );
    let mut permission = custom("com.example.settings");
    permission["custom"]["capability"]["systemSettingsUrl"] = json!("app-settings:privacy");
    assert_eq!(
        query(json!({"op":"admitSettings","platform":"windows","permission":permission})),
        Ok(json!({"capability":permission["custom"]["capability"]}))
    );
}

#[test]
fn notification_options_preserve_all_shared_unsigned_wire_values() {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        named_options: Vec<OptionValue>,
        combinations: Vec<OptionValue>,
        raw_masks: Vec<u64>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct OptionValue {
        raw_value: u64,
    }

    let fixture: Fixture = serde_json::from_str(include_str!(
        "../../../Tests/SystemPermissionsTests/Fixtures/notification-options.json"
    ))
    .unwrap();
    let notifications = Descriptor::built_in("notifications").unwrap();
    assert_eq!(
        serde_json::to_value(
            metadata(&notifications, Platform::Macos, None)
                .unwrap()
                .default_options
        )
        .unwrap(),
        json!({"kind":"notifications","notificationOptions":7})
    );
    let masks = fixture
        .named_options
        .into_iter()
        .chain(fixture.combinations)
        .map(|value| value.raw_value)
        .chain(fixture.raw_masks);
    for mask in masks {
        let options = json!({"kind":"notifications","notificationOptions":mask});
        let validated =
            query(json!({"op":"validateOptions","permission":notifications,"options":options}));
        assert_eq!(validated, Ok(options), "notification mask {mask}");
    }
}

#[test]
fn option_metadata_uses_photo_specific_keys() {
    for level in ["readWrite", "addOnly"] {
        let value = query(json!({"op":"metadata","platform":"macos","permission":{"id":"photos"},"options":{"kind":"photos","photoAccessLevel":level}})).unwrap();
        let key = if level == "addOnly" {
            "NSPhotoLibraryAddUsageDescription"
        } else {
            "NSPhotoLibraryUsageDescription"
        };
        assert_eq!(value["usageDescriptionKeys"], json!([key]));
        assert_eq!(
            value["defaultOptions"],
            json!({"kind":"photos","photoAccessLevel":"readWrite"})
        );
    }
    assert_eq!(
        query(
            json!({"op":"validateOptions","permission":{"id":"camera"},"options":{"kind":"none"}})
        )
        .unwrap(),
        json!({"kind":"none"})
    );
    assert_eq!(
        query(
            json!({"op":"validateOptions","permission":{"id":"photos"},"options":{"kind":"notifications","notificationOptions":7}})
        ),
        Err(Error::InvalidOptions)
    );
}

#[test]
fn option_payloads_only_apply_to_their_own_permission_domain() {
    for id in BUILT_IN_IDS {
        let permission = if id == "automation" {
            descriptor(json!({"id":id,"targetApplication":"com.apple.TextEdit"}))
        } else {
            Descriptor::built_in(id).unwrap()
        };
        for (options, domain) in [
            (Options::None, None),
            (
                Options::Notifications {
                    notification_options: 0,
                },
                Some("notifications"),
            ),
            (
                Options::Photos {
                    photo_access_level: PhotoAccessLevel::AddOnly,
                },
                Some("photos"),
            ),
        ] {
            let expected = if domain.is_none_or(|domain| domain == id) {
                Ok(())
            } else {
                Err(Error::InvalidOptions)
            };
            assert_eq!(
                options.validate_for(&permission),
                expected,
                "{id}, {options:?}"
            );
        }
    }
}

#[test]
fn malformed_unknown_duplicate_null_and_mismatched_payloads_are_rejected() {
    for input in [
        r#"{"op":"builtIns","extra":true}"#,
        r#"{"op":"builtIns","permission":{"id":"camera"}}"#,
        r#"{"op":"builtIns","op":"builtIns"}"#,
        r#"{"op":"validateDescriptor","permission":{"id":"camera","id":"microphone"}}"#,
        r#"{"op":"validateDescriptor","permission":{"id":"camera","targetApplication":null}}"#,
        r#"{"op":"validateDescriptor","permission":{"id":"camera","custom":null}}"#,
        r#"{"op":"validateDescriptor","permission":{"id":"camera","extra":1}}"#,
        r#"{"op":"metadata","platform":"linux","permission":{"id":"camera"}}"#,
        r#"{"op":"metadata","platform":"macos","permission":{"id":"photos"},"options":null}"#,
        r#"{"op":"validateOptions","permission":{"id":"camera"},"options":{"kind":"none","notificationOptions":7}}"#,
        r#"{"op":"validateOptions","permission":{"id":"notifications"},"options":{"kind":"notifications","notificationOptions":{"rawValue":7}}}"#,
        r#"{"op":"validateOptions","permission":{"id":"notifications"},"options":{"kind":"notifications","notificationOptions":-1}}"#,
        r#"{"op":"validateOptions","permission":{"id":"notifications"},"options":{"kind":"notifications","notificationOptions":1.0}}"#,
        r#"{"op":"validateOptions","permission":{"id":"photos"},"options":{"kind":"photos","photoAccessLevel":"addOnly","notificationOptions":7}}"#,
        r#"{"op":"builtIns"}{}"#,
    ] {
        assert!(
            call(input.as_bytes()).is_err(),
            "Accepted malformed payload: {input}"
        );
    }
    assert_eq!(call(&[0xff]), Err(Error::InvalidUtf8));
    assert_eq!(
        call(&vec![b' '; MAX_INPUT_BYTES + 1]),
        Err(Error::InputTooLarge)
    );
    let deep = format!("{}0{}", "[".repeat(256), "]".repeat(256));
    assert!(call(deep.as_bytes()).is_err());
    assert!(
        query(json!({"op":"validateDescriptor","permission":{"id":"x".repeat(1025)}})).is_err()
    );
}
