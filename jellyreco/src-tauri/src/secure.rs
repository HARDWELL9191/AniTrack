//! Sign-in data and battery saver status.
//! Windows: encrypted for your Windows account with DPAPI (the protection Windows uses for saved
//! Wi-Fi and browser passwords). Linux: in your desktop's keyring (Secret Service: GNOME Keyring,
//! KWallet, KeePassXC…); without one, in a file only your user can read.

use std::path::Path;

#[cfg(windows)]
mod dpapi {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CryptUnprotectData, CRYPT_INTEGER_BLOB};

    fn blob(data: &[u8]) -> CRYPT_INTEGER_BLOB {
        CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 }
    }

    fn take(out: CRYPT_INTEGER_BLOB) -> Vec<u8> {
        let bytes = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) }.to_vec();
        unsafe { LocalFree(out.pbData as _) };
        bytes
    }

    pub fn protect(data: &[u8]) -> Option<Vec<u8>> {
        let input = blob(data);
        let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let ok = unsafe {
            CryptProtectData(&input, std::ptr::null(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut out)
        };
        (ok != 0).then(|| take(out))
    }

    pub fn unprotect(data: &[u8]) -> Option<Vec<u8>> {
        let input = blob(data);
        let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
        let ok = unsafe {
            CryptUnprotectData(&input, std::ptr::null_mut(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut out)
        };
        (ok != 0).then(|| take(out))
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod dpapi {
    // Development builds on other systems only: stored as is.
    pub fn protect(data: &[u8]) -> Option<Vec<u8>> {
        Some(data.to_vec())
    }
    pub fn unprotect(data: &[u8]) -> Option<Vec<u8>> {
        Some(data.to_vec())
    }
}

#[cfg(not(target_os = "linux"))]
pub fn load(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let plain = dpapi::unprotect(&bytes)?;
    String::from_utf8(plain).ok().filter(|s| !s.is_empty())
}

#[cfg(not(target_os = "linux"))]
pub fn store(path: &Path, token: Option<&str>) -> Result<(), String> {
    match token {
        None | Some("") => {
            let _ = std::fs::remove_file(path);
            Ok(())
        }
        Some(t) => {
            let sealed = dpapi::protect(t.as_bytes()).ok_or("Windows couldn't protect the token")?;
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            }
            std::fs::write(path, sealed).map_err(|e| e.to_string())
        }
    }
}

#[cfg(target_os = "linux")]
mod keyring {
    use secret_service::blocking::SecretService;
    use secret_service::EncryptionType;
    use std::collections::HashMap;

    fn attrs() -> HashMap<&'static str, &'static str> {
        HashMap::from([("application", "jellyreco"), ("kind", "sign-ins")])
    }

    pub fn put(data: &str) -> Result<(), String> {
        let ss = SecretService::connect(EncryptionType::Dh).map_err(|e| e.to_string())?;
        let c = ss.get_default_collection().map_err(|e| e.to_string())?;
        if c.is_locked().map_err(|e| e.to_string())? {
            c.unlock().map_err(|e| e.to_string())?;
        }
        c.create_item("JellyReco sign-ins", attrs(), data.as_bytes(), true, "application/json").map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get() -> Option<String> {
        let ss = SecretService::connect(EncryptionType::Dh).ok()?;
        let found = ss.search_items(attrs()).ok()?;
        let item = found.unlocked.into_iter().next().or_else(|| {
            let locked = found.locked.into_iter().next()?;
            locked.unlock().ok()?;
            Some(locked)
        })?;
        String::from_utf8(item.get_secret().ok()?).ok()
    }

    pub fn remove() {
        if let Ok(ss) = SecretService::connect(EncryptionType::Dh) {
            if let Ok(found) = ss.search_items(attrs()) {
                for i in found.unlocked.into_iter().chain(found.locked) {
                    let _ = i.delete();
                }
            }
        }
    }
}

/// The file says where the sign-ins are: "keyring" (the desktop keyring) or the data itself.
#[cfg(target_os = "linux")]
const IN_KEYRING: &str = "jellyreco:keyring:v1";

#[cfg(target_os = "linux")]
pub fn load(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let data = if text.trim() == IN_KEYRING { keyring::get()? } else { text };
    Some(data).filter(|s| !s.is_empty())
}

#[cfg(target_os = "linux")]
pub fn store(path: &Path, token: Option<&str>) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    match token {
        None | Some("") => {
            keyring::remove();
            let _ = std::fs::remove_file(path);
            Ok(())
        }
        Some(t) => {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            }
            let contents = match keyring::put(t) {
                Ok(()) => IN_KEYRING.to_string(),
                Err(_) => t.to_string(), // no keyring on this desktop: a file only you can read
            };
            let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path).map_err(|e| e.to_string())?;
            f.write_all(contents.as_bytes()).map_err(|e| e.to_string())
        }
    }
}

#[cfg(windows)]
pub fn battery_saver_on() -> bool {
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    let mut s: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
    // SystemStatusFlag 1 = battery saver (energy saver) is on.
    unsafe { GetSystemPowerStatus(&mut s) != 0 && s.SystemStatusFlag == 1 }
}

/// Power Saver (power-profiles-daemon, the switch GNOME and KDE show) or a low-power platform profile.
#[cfg(target_os = "linux")]
pub fn battery_saver_on() -> bool {
    let via_daemon = || -> Option<bool> {
        let conn = zbus::blocking::Connection::system().ok()?;
        for (dest, path, iface) in [
            ("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles"),
            ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles"),
        ] {
            if let Ok(reply) = conn.call_method(Some(dest), path, Some("org.freedesktop.DBus.Properties"), "Get", &(iface, "ActiveProfile")) {
                let v: zbus::zvariant::OwnedValue = reply.body().deserialize().ok()?;
                let s: String = v.try_into().ok()?;
                return Some(s == "power-saver");
            }
        }
        None
    };
    via_daemon().unwrap_or_else(|| std::fs::read_to_string("/sys/firmware/acpi/platform_profile").map(|p| p.trim() == "low-power").unwrap_or(false))
}

#[cfg(not(any(windows, target_os = "linux")))]
pub fn battery_saver_on() -> bool {
    false
}

#[cfg(test)]
mod tests {
    #[test]
    fn token_round_trip() {
        let path = std::env::temp_dir().join(format!("jellyreco-token-{}.bin", std::process::id()));
        super::store(&path, Some("abc.def")).unwrap();
        assert_eq!(super::load(&path).as_deref(), Some("abc.def"));
        super::store(&path, None).unwrap();
        assert_eq!(super::load(&path), None);
    }
}
