//! AniReco for Windows: the native side. The app itself (screens, AniList, picks) is the web
//! front end; this part runs the on-device AI, keeps the AniList token safe, and handles the
//! anireco:// login link.

pub mod ai;
pub mod llm;
mod secure;

use base64::Engine as _;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use tauri::{Emitter, Manager};

struct AppState {
    ai: Arc<ai::Engine>,
    llm: Arc<llm::Llm>,
}

#[derive(Deserialize)]
struct EmbedItem {
    id: i64,
    text: String,
}

fn keyed(map: HashMap<i64, Vec<f32>>) -> HashMap<String, Vec<f32>> {
    map.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

#[tauri::command]
fn ai_status(state: tauri::State<'_, AppState>) -> ai::Status {
    state.ai.status()
}

#[tauri::command]
fn ai_cached(ids: Vec<i64>, state: tauri::State<'_, AppState>) -> HashMap<String, Vec<f32>> {
    keyed(state.ai.cached(&ids))
}

/// Runs off the UI thread: model start-up and embedding never block the window.
#[tauri::command]
async fn ai_vectors(items: Vec<EmbedItem>, state: tauri::State<'_, AppState>) -> Result<HashMap<String, Vec<f32>>, String> {
    let engine = state.ai.clone();
    let items: Vec<(i64, String)> = items.into_iter().map(|i| (i.id, i.text)).collect();
    tauri::async_runtime::spawn_blocking(move || engine.vectors(&items))
        .await
        .map_err(|e| e.to_string())?
        .map(keyed)
}

/// The AI writer ("Why would I like this?" on the NPU): downloaded, downloading, ready.
#[tauri::command]
fn llm_status(state: tauri::State<'_, AppState>) -> llm::Status {
    state.llm.status()
}

/// Starts the model download in the background (progress through llm_status).
#[tauri::command]
fn llm_download(state: tauri::State<'_, AppState>) {
    let llm = state.llm.clone();
    tauri::async_runtime::spawn(async move {
        let _ = llm.download().await;
    });
}

#[tauri::command]
fn llm_cancel(state: tauri::State<'_, AppState>) {
    state.llm.cancel_download();
}

#[tauri::command]
async fn llm_remove(state: tauri::State<'_, AppState>) -> Result<(), String> {
    let llm = state.llm.clone();
    tauri::async_runtime::spawn_blocking(move || llm.remove()).await.map_err(|e| e.to_string())?
}

/// Writes the explanation (off the UI thread; a few seconds on the NPU).
#[tauri::command]
async fn llm_explain(system: String, user: String, state: tauri::State<'_, AppState>) -> Result<String, String> {
    let llm = state.llm.clone();
    let text = tauri::async_runtime::spawn_blocking(move || llm.explain(&system, &user)).await.map_err(|e| e.to_string())?;
    // The model is closed a minute after the last request, so it costs nothing while unused.
    let llm = state.llm.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(61));
        llm.close_if_idle();
    });
    text
}

#[tauri::command]
fn token_get(app: tauri::AppHandle) -> Option<String> {
    secure::load(&token_path(&app))
}

#[tauri::command]
fn token_set(app: tauri::AppHandle, token: Option<String>) -> Result<(), String> {
    secure::store(&token_path(&app), token.as_deref())
}

fn token_path(app: &tauri::AppHandle) -> std::path::PathBuf {
    app.path().app_data_dir().unwrap_or_default().join("anilist-token.bin")
}

/// Battery saver on (the Windows twin of Low Power Mode): the AI part pauses.
#[tauri::command]
fn power_saver() -> bool {
    secure::battery_saver_on()
}

/// Saves a file the person picked in the Save dialog (the Excel export).
#[tauri::command]
fn write_file(path: String, base64: String) -> Result<(), String> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(base64).map_err(|e| e.to_string())?;
    std::fs::write(&path, bytes).map_err(|e| e.to_string())
}

/// The app's identifier before it was renamed from AniTrack to AniReco.
const OLD_IDENTIFIER: &str = "com.tim.anitrack";

/// First start after the rename: moves AniTrack's data folders to AniReco's, so the login,
/// settings, cached lists and the downloaded AI writer carry over. `%APPDATA%\<identifier>` holds
/// the token and the AI files, `%LOCALAPPDATA%\<identifier>` the window's browser data (settings
/// and cache), which is why this runs before the window opens. Same folders Tauri resolves.
/// Returns true if anything was moved.
fn move_old_data(identifier: &str) -> bool {
    let mut moved = false;
    for base in [dirs::data_dir(), dirs::data_local_dir()].into_iter().flatten() {
        let (old, new) = (base.join(OLD_IDENTIFIER), base.join(identifier));
        if old.is_dir() && !new.exists() && std::fs::rename(&old, &new).is_ok() {
            moved = true;
        }
    }
    moved
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let context = tauri::generate_context!();
    let moved = move_old_data(&context.config().identifier);
    let mut builder = tauri::Builder::default();

    // A second launch (e.g. the anireco:// login link) hands its link to the running window.
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if let Some(url) = argv.iter().find(|a| a.starts_with("anireco://")) {
                let _ = app.emit("auth-link", url.clone());
            }
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }));
    }

    builder
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(move |app| {
            // Registers anireco:// for this user (also done by the installer), so AniList's
            // login can come back to the app.
            #[cfg(windows)]
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                let _ = app.deep_link().register("anireco");
                // The old app's anitrack:// link pointed at the AniTrack exe, which is gone now.
                if moved {
                    let _ = app.deep_link().unregister("anitrack");
                }
            }
            let root = app.path().resource_dir().unwrap_or_default();
            let data = app.path().app_data_dir().unwrap_or_default();
            let ai = Arc::new(ai::Engine::new(ai::Paths { resources: root.join("ai"), data: data.clone() }));
            let llm = Arc::new(llm::Llm::new(root.join("ai"), data.clone()));
            app.manage(AppState { ai, llm });
            // Earlier builds used Windows' own language model through an identity package;
            // remove that registration (it isn't used any more).
            #[cfg(windows)]
            cleanup_windows_ai(&data);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![ai_status, ai_cached, ai_vectors, llm_status, llm_download, llm_cancel, llm_remove, llm_explain, token_get, token_set, power_saver, write_file])
        .run(context)
        .expect("error while running AniReco");
}

/// Removes the AniTrack.WindowsAI package an earlier build (still named AniTrack) registered, once.
#[cfg(windows)]
fn cleanup_windows_ai(data: &std::path::Path) {
    let note = data.join("winai-registered.txt");
    if !note.exists() {
        return;
    }
    let _ = std::fs::remove_file(&note);
    std::thread::spawn(|| {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command", "Get-AppxPackage -Name AniTrack.WindowsAI | Remove-AppxPackage"])
            .creation_flags(0x0800_0000)
            .status();
    });
}
