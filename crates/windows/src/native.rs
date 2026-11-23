use super::*;
use windows::Security::Authorization::AppCapabilityAccess::AppCapability;
use windows::Win32::Foundation::{ERROR_INSUFFICIENT_BUFFER, RPC_E_CHANGED_MODE};
use windows::Win32::Storage::Packaging::Appx::GetCurrentPackageFullName;
use windows::Win32::System::Com::{
    APTTYPE, APTTYPE_MAINSTA, APTTYPE_STA, APTTYPEQUALIFIER, CoGetApartmentType,
};
use windows::Win32::System::WinRT::{
    RO_INIT_MULTITHREADED, RO_INIT_SINGLETHREADED, RoInitialize, RoUninitialize,
};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows::core::{HSTRING, PCWSTR, w};

struct Apartment(bool);
impl Apartment {
    fn enter() -> Result<Self, OperationError> {
        let mut apartment = APTTYPE::default();
        let mut qualifier = APTTYPEQUALIFIER::default();
        let sta = unsafe { CoGetApartmentType(&mut apartment, &mut qualifier) }.is_ok()
            && (apartment == APTTYPE_STA || apartment == APTTYPE_MAINSTA);
        let mode = if sta {
            RO_INIT_SINGLETHREADED
        } else {
            RO_INIT_MULTITHREADED
        };
        // Match every successful initialization (including S_FALSE) with one uninitialize.
        // Existing host apartment ownership and threading mode remain intact.
        match unsafe { RoInitialize(mode) } {
            Ok(()) => Ok(Self(true)),
            Err(error) if error.code() == RPC_E_CHANGED_MODE => Ok(Self(false)),
            Err(_) => Err(OperationError::ApiUnavailable),
        }
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        if self.0 {
            unsafe { RoUninitialize() };
        }
    }
}

fn has_package_identity() -> bool {
    let mut length = 0;
    // Querying package identity has no effects and needs no package-name allocation.
    unsafe {
        GetCurrentPackageFullName(&mut length, None) == ERROR_INSUFFICIENT_BUFFER && length > 1
    }
}

fn capability(name: &str) -> Result<AppCapability, OperationError> {
    if !has_package_identity() {
        return Err(OperationError::ApiUnavailable);
    }
    AppCapability::Create(&HSTRING::from(name)).map_err(|_| OperationError::ApiUnavailable)
}

pub(super) fn status(name: &str) -> PermissionResult {
    let result = (|| {
        let _apartment = Apartment::enter()?;
        let value = capability(name)?
            .CheckAccess()
            .map_err(|_| OperationError::ApiUnavailable)?;
        Ok(PermissionResult::Supported {
            value: access_status(value.0),
        })
    })();
    result.unwrap_or_else(failed)
}

pub(super) fn open_settings(url: &str) -> SettingsResult {
    let wide: Vec<u16> = url.encode_utf16().chain(Some(0)).collect();
    // ShellExecute receives a fixed built-in ms-settings URI and no arguments or verb
    // capable of elevation. Success reports launch only, never a permission grant.
    let result = unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            PCWSTR(wide.as_ptr()),
            None,
            None,
            SW_SHOWNORMAL,
        )
    };
    if result.0 as isize > 32 {
        SettingsResult::Supported { value: true }
    } else {
        SettingsResult::Failed {
            error: OperationError::OpenFailed,
        }
    }
}
