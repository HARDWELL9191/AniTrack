//! AniTrack for Windows: the native side. The app itself (screens, AniList, picks) is the web
//! front end; this part runs the on-device AI, keeps the AniList token safe, and handles the
//! anitrack:// login link.

pub mod ai;
mod secure;
mod winai;

use base64::Engine as _;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use tauri::{Emitter, Manager};

struct AppState {
    ai: Arc<ai::Engine>,
    winai: Arc<winai::WinAi>,
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

/// Whether "Why would I like this?" can be written by Windows' on-device language model.
#[tauri::command]
async fn winai_status(state: tauri::State<'_, AppState>) -> Result<winai::Status, String> {
    let w = state.winai.clone();
    let status = tauri::async_runtime::spawn_blocking(move || w.status()).await.map_err(|e| e.to_string())?;
    close_later(&state.winai);
    Ok(status)
}

/// Writes the explanation (off the UI thread; takes a few seconds on the NPU).
#[tauri::command]
async fn winai_explain(prompt: String, state: tauri::State<'_, AppState>) -> Result<String, String> {
    let w = state.winai.clone();
    let text = tauri::async_runtime::spawn_blocking(move || w.explain(&prompt)).await.map_err(|e| e.to_string())?;
    close_later(&state.winai);
    text
}

/// The helper (and the model in it) is closed a minute after the last request; nothing runs
/// in between, so it costs no battery while unused.
fn close_later(w: &Arc<winai::WinAi>) {
    let w = w.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(61));
        w.close_if_idle();
    });
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    // A second launch (e.g. the anitrack:// login link) hands its link to the running window.
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if let Some(url) = argv.iter().find(|a| a.starts_with("anitrack://")) {
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
        .setup(|app| {
            // Registers anitrack:// for this user (also done by the installer), so AniList's
            // login can come back to the app.
            #[cfg(windows)]
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                let _ = app.deep_link().register("anitrack");
            }
            let root = app.path().resource_dir().unwrap_or_default();
            let data = app.path().app_data_dir().unwrap_or_default();
            let ai = Arc::new(ai::Engine::new(ai::Paths { resources: root.join("ai"), data: data.clone() }));
            let winai = Arc::new(winai::WinAi::new(root, data));
            app.manage(AppState { ai, winai });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![ai_status, ai_cached, ai_vectors, winai_status, winai_explain, token_get, token_set, power_saver, write_file])
        .run(tauri::generate_context!())
        .expect("error while running AniTrack");
}
