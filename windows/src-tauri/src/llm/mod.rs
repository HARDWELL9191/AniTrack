//! "Why would I like this?" written by a language model on the Snapdragon NPU: the Windows twin
//! of the iPhone's Apple Intelligence explainer.
//!
//! Model: Qwen3-4B-Instruct-2507 (Apache-2.0), as Qualcomm's ready-made Genie package for the
//! Snapdragon X Elite / X Plus (Hexagon v73) or X2 Elite, 4-bit weights. It's downloaded from
//! Qualcomm the first time you ask for it (about 2.5 GB), checked against the size and SHA-256
//! the build recorded, unpacked into AniTrack's data folder, and run by Qualcomm's Genie runtime
//! in a background process (see `process.rs`) that only lives while it's being used.

mod bundle;
mod genie;
pub mod helper;
mod process;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub use bundle::{extract, find_root, patch_config, validate};

#[derive(Clone, Deserialize)]
struct Variant {
    url: String,
    sha256: String,
    size: u64,
}

#[derive(Clone, Deserialize)]
struct Manifest {
    model: String,
    variants: std::collections::HashMap<String, Variant>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// "unsupported", "notDownloaded", "downloading", "ready" or "error".
    pub state: String,
    pub model: String,
    pub size_bytes: u64,
    pub received: u64,
    pub detail: String,
}

#[derive(Default)]
struct Download {
    active: bool,
    received: u64,
    total: u64,
    error: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Installed {
    variant: String,
    sha256: String,
    /// Model folder, relative to the variant folder.
    root: String,
}

pub struct Llm {
    lib_dir: PathBuf,
    data: PathBuf,
    manifest: Option<Manifest>,
    chip: Option<(String, String)>,
    download: Mutex<Download>,
    cancel: AtomicBool,
    helper: Mutex<Option<Arc<process::HelperProcess>>>,
}

impl Llm {
    /// `lib_dir`: the AI folder (Genie.dll, the QNN libraries, llm-models.json);
    /// `data`: AniTrack's data folder.
    pub fn new(lib_dir: PathBuf, data: PathBuf) -> Self {
        let manifest = std::fs::read_to_string(lib_dir.join("llm-models.json")).ok().and_then(|t| serde_json::from_str(&t).ok());
        Self {
            lib_dir,
            data: data.join("llm"),
            manifest,
            chip: detect_chip(),
            download: Mutex::new(Download::default()),
            cancel: AtomicBool::new(false),
            helper: Mutex::new(None),
        }
    }

    fn variant(&self) -> Option<(String, Variant)> {
        let (key, _) = self.chip.as_ref()?;
        let v = self.manifest.as_ref()?.variants.get(key)?.clone();
        Some((key.clone(), v))
    }

    fn installed(&self) -> Option<(Installed, PathBuf)> {
        let (key, v) = self.variant()?;
        let dir = self.data.join(&key);
        let info: Installed = serde_json::from_str(&std::fs::read_to_string(dir.join("installed.json")).ok()?).ok()?;
        let root = dir.join(&info.root);
        (info.sha256 == v.sha256 && root.join("genie_config.json").is_file()).then_some((info, root))
    }

    pub fn status(&self) -> Status {
        let model = self.manifest.as_ref().map(|m| m.model.clone()).unwrap_or_default();
        let base = |state: &str, size: u64, detail: String| Status { state: state.into(), model: model.clone(), size_bytes: size, received: 0, detail };
        let Some(manifest) = &self.manifest else {
            return base("unsupported", 0, "The AI writer isn't part of this build.".into());
        };
        let Some((_, chip_name)) = &self.chip else {
            return base("unsupported", 0, "The AI writer needs a Snapdragon X PC.".into());
        };
        let Some((_, v)) = self.variant() else {
            return base("unsupported", 0, format!("{} isn't available for {chip_name} yet.", manifest.model));
        };
        let d = self.download.lock().unwrap();
        if d.active {
            return Status { received: d.received, ..base("downloading", d.total.max(v.size), format!("Downloading {} for {chip_name}", manifest.model)) };
        }
        if let Some(err) = &d.error {
            return base("error", v.size, err.clone());
        }
        drop(d);
        if self.installed().is_some() {
            return base("ready", v.size, format!("{} on the Snapdragon NPU ({chip_name})", manifest.model));
        }
        base("notDownloaded", v.size, format!("{} for {chip_name}, runs on the NPU", manifest.model))
    }

    /// Downloads, checks and unpacks the model (runs in the background; see `status`).
    pub async fn download(self: Arc<Self>) -> Result<(), String> {
        let (key, v) = self.variant().ok_or("the AI writer isn't available on this PC")?;
        {
            let mut d = self.download.lock().unwrap();
            if d.active {
                return Ok(());
            }
            *d = Download { active: true, received: 0, total: v.size, error: None };
        }
        self.cancel.store(false, Ordering::SeqCst);
        let result = self.clone().fetch_and_install(&key, &v).await;
        let mut d = self.download.lock().unwrap();
        d.active = false;
        if let Err(e) = &result {
            d.error = Some(e.clone());
        }
        result
    }

    pub fn cancel_download(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }

    async fn fetch_and_install(self: Arc<Self>, key: &str, v: &Variant) -> Result<(), String> {
        std::fs::create_dir_all(&self.data).map_err(|e| e.to_string())?;
        let part = self.data.join(format!("{key}.zip.part"));
        let client = reqwest::Client::builder().build().map_err(|e| e.to_string())?;
        let mut res = client.get(&v.url).send().await.and_then(|r| r.error_for_status()).map_err(|e| format!("couldn't download the model: {e}"))?;
        let mut file = std::fs::File::create(&part).map_err(|e| e.to_string())?;
        let mut hasher = Sha256::new();
        let mut received = 0u64;
        loop {
            if self.cancel.load(Ordering::SeqCst) {
                drop(file);
                let _ = std::fs::remove_file(&part);
                return Err("Download cancelled.".into());
            }
            match res.chunk().await.map_err(|e| format!("the download stopped: {e}"))? {
                Some(chunk) => {
                    file.write_all(&chunk).map_err(|e| format!("couldn't save the model (is the disk full?): {e}"))?;
                    hasher.update(&chunk);
                    received += chunk.len() as u64;
                    self.download.lock().unwrap().received = received;
                }
                None => break,
            }
        }
        file.flush().map_err(|e| e.to_string())?;
        drop(file);
        let digest = hex(&hasher.finalize());
        if received != v.size || digest != v.sha256 {
            let _ = std::fs::remove_file(&part);
            return Err(format!("The download didn't match Qualcomm's file ({received} bytes); try again."));
        }

        // Unpacking 2.5 GB takes a moment: off the async threads.
        let data = self.data.clone();
        let key = key.to_string();
        let sha = v.sha256.clone();
        tauri::async_runtime::spawn_blocking(move || install(&data, &key, &part, &sha))
            .await
            .map_err(|e| e.to_string())?
    }

    pub fn remove(&self) -> Result<(), String> {
        if let Some(h) = self.helper.lock().unwrap().take() {
            h.close_now();
        }
        if let Some((key, _)) = self.variant() {
            let dir = self.data.join(key);
            if dir.exists() {
                std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
            }
        }
        self.download.lock().unwrap().error = None;
        Ok(())
    }

    /// Writes the explanation (blocking; a few seconds on the NPU, longer the first time while
    /// the model loads).
    pub fn explain(&self, system: &str, user: &str) -> Result<String, String> {
        let (_, root) = self.installed().ok_or("the AI writer isn't downloaded")?;
        let helper = {
            let mut guard = self.helper.lock().unwrap();
            guard
                .get_or_insert_with(|| {
                    let exe = std::env::current_exe().unwrap_or_default();
                    let args = vec!["--llm-helper".into(), self.lib_dir.display().to_string(), root.display().to_string()];
                    Arc::new(process::HelperProcess::new(exe, args))
                })
                .clone()
        };
        let reply = helper.request(&serde_json::json!({ "cmd": "explain", "system": system, "user": user, "maxTokens": 120 }))?;
        reply["text"].as_str().filter(|t| !t.is_empty()).map(str::to_string).ok_or_else(|| "the model gave no answer".into())
    }

    /// Frees the NPU memory after a quiet minute.
    pub fn close_if_idle(&self) {
        if let Some(h) = self.helper.lock().unwrap().as_ref() {
            h.close_if_idle();
        }
    }
}

/// Unpacks a verified download into `<data>/<key>`, applies the config fix and checks it.
pub fn install(data: &Path, key: &str, zip: &Path, sha256: &str) -> Result<(), String> {
    let staging = data.join(format!("{key}.staging"));
    let _ = std::fs::remove_dir_all(&staging);
    let result = (|| {
        let root = bundle::extract(zip, &staging)?;
        bundle::patch_config(&root)?;
        bundle::validate(&root)?;
        let rel = root.strip_prefix(&staging).map_err(|e| e.to_string())?.to_path_buf();
        let info = Installed { variant: key.into(), sha256: sha256.into(), root: rel.to_string_lossy().into() };
        std::fs::write(staging.join("installed.json"), serde_json::to_string(&info).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        let dest = data.join(key);
        let _ = std::fs::remove_dir_all(&dest);
        std::fs::rename(&staging, &dest).map_err(|e| e.to_string())
    })();
    let _ = std::fs::remove_file(zip);
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&staging);
    }
    result
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Which Qualcomm package fits this PC: ("x2_elite" | "x_elite", marketing name). The X Elite
/// package also runs on the X Plus and X (same Hexagon v73 NPU).
fn detect_chip() -> Option<(String, String)> {
    let name = processor_name()?;
    chip_from_name(&name).map(|k| (k.to_string(), name.trim().to_string()))
}

fn chip_from_name(name: &str) -> Option<&'static str> {
    let n = name.to_lowercase();
    if !n.contains("snapdragon") {
        return None;
    }
    // "Snapdragon(R) X2 Elite …", "Snapdragon X2 Elite Extreme …" vs "Snapdragon(R) X Elite - X1E…",
    // "X Plus - X1P…", "Snapdragon(R) X 10-core X1…".
    if n.contains("x2") { Some("x2_elite") } else { Some("x_elite") }
}

#[cfg(windows)]
fn processor_name() -> Option<String> {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
    let key: Vec<u16> = r"HARDWARE\DESCRIPTION\System\CentralProcessor\0".encode_utf16().chain([0]).collect();
    let value: Vec<u16> = "ProcessorNameString".encode_utf16().chain([0]).collect();
    let mut buf = [0u16; 256];
    let mut len = (buf.len() * 2) as u32;
    let rc = unsafe {
        RegGetValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr().cast(), &mut len)
    };
    if rc != 0 {
        return None;
    }
    let chars = (len as usize / 2).saturating_sub(1);
    Some(String::from_utf16_lossy(&buf[..chars.min(buf.len())]))
}

#[cfg(not(windows))]
fn processor_name() -> Option<String> {
    std::env::var("ANITRACK_TEST_CPU").ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_package_for_the_chip() {
        assert_eq!(chip_from_name("Snapdragon(R) X Elite - X1E78100 - Qualcomm(R) Oryon(TM) CPU"), Some("x_elite"));
        assert_eq!(chip_from_name("Snapdragon(R) X Plus - X1P64100 - Qualcomm(R) Oryon(TM) CPU"), Some("x_elite"));
        assert_eq!(chip_from_name("Snapdragon(R) X 10-core X1P42100"), Some("x_elite"));
        assert_eq!(chip_from_name("Snapdragon(R) X2 Elite Extreme - X2E94100"), Some("x2_elite"));
        assert_eq!(chip_from_name("Intel(R) Core(TM) Ultra 7"), None);
    }
}
