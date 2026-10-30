//! The AniList token, encrypted for your Windows account with DPAPI (the same protection
//! Windows uses for saved Wi-Fi and browser passwords), and battery saver status.

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

#[cfg(not(windows))]
mod dpapi {
    // Development builds on other systems only: stored as is.
    pub fn protect(data: &[u8]) -> Option<Vec<u8>> {
        Some(data.to_vec())
    }
    pub fn unprotect(data: &[u8]) -> Option<Vec<u8>> {
        Some(data.to_vec())
    }
}

pub fn load(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let plain = dpapi::unprotect(&bytes)?;
    String::from_utf8(plain).ok().filter(|s| !s.is_empty())
}

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

#[cfg(windows)]
pub fn battery_saver_on() -> bool {
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    let mut s: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
    // SystemStatusFlag 1 = battery saver (energy saver) is on.
    unsafe { GetSystemPowerStatus(&mut s) != 0 && s.SystemStatusFlag == 1 }
}

#[cfg(not(windows))]
pub fn battery_saver_on() -> bool {
    false
}

#[cfg(test)]
mod tests {
    #[test]
    fn token_round_trip() {
        let path = std::env::temp_dir().join(format!("anireco-token-{}.bin", std::process::id()));
        super::store(&path, Some("abc.def")).unwrap();
        assert_eq!(super::load(&path).as_deref(), Some("abc.def"));
        super::store(&path, None).unwrap();
        assert_eq!(super::load(&path), None);
    }
}
