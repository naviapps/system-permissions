use system_permissions::{
    Descriptor, Error, Options, PermissionResult, Platform, Status, Store, Update, WorkKind, call,
    metadata,
};

fn main() {
    let notifications = Descriptor::built_in("notifications").unwrap();
    let camera = Descriptor::built_in("camera").unwrap();
    let all_bits = Options::Notifications {
        notification_options: u64::MAX,
    };
    assert_eq!(all_bits.validate_for(&notifications), Ok(()));
    assert_eq!(all_bits.validate_for(&camera), Err(Error::InvalidOptions));
    assert_eq!(
        metadata(&notifications, Platform::Macos, Some(&all_bits))
            .unwrap()
            .default_options,
        Options::Notifications {
            notification_options: 7,
        }
    );

    let wire = call(
        br#"{"op":"validateOptions","permission":{"id":"notifications"},"options":{"kind":"notifications","notificationOptions":18446744073709551615}}"#,
    )
    .unwrap();
    assert_eq!(wire["notificationOptions"].as_u64(), Some(u64::MAX));
    let mut store = Store::new();
    store.track(std::slice::from_ref(&camera)).unwrap();
    let token = store.admit(&camera, WorkKind::Request).unwrap().unwrap();
    assert_eq!(store.admit(&camera, WorkKind::Refresh).unwrap(), None);
    let grant = Update {
        permission: camera.clone(),
        token,
        result: PermissionResult::Supported {
            value: Status::Granted,
        },
    };
    assert_eq!(
        store
            .apply(std::slice::from_ref(&grant), false)
            .unwrap()
            .accepted,
        1
    );
    assert_eq!(store.finish(token), Ok(true));
    assert_eq!(store.apply(&[grant], false).unwrap().accepted, 0);
    assert!(store.admit(&camera, WorkKind::Refresh).unwrap().unwrap() > token);
    println!(
        "Standalone Rust Git SystemPermissions consumer passed notification options, validation and work admission."
    );
}
