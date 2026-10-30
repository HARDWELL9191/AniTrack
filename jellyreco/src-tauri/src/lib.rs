//! JellyReco for Windows: the native side. The app (screens, Jellyfin, picks) is the web front
//! end; this part runs mpv (playback), the on-device AI (For You), and keeps sign-ins encrypted.

pub mod ai;
pub mod mpv;
mod secure;

use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use tauri::{Emitter, Manager};

struct AppState {
    ai: Arc<ai::Engine>,
    mpv: Arc<mpv::Engine>,
}

#[derive(Deserialize)]
struct EmbedItem {
    id: i64,
    text: String,
}

fn keyed(map: HashMap<i64, Vec<f32>>) -> HashMap<String, Vec<f32>> {
    map.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

// MARK: Playback

#[tauri::command]
fn mpv_info(state: tauri::State<'_, AppState>) -> mpv::Info {
    state.mpv.info()
}

/// Creates mpv inside the main window (video behind the transparent WebView).
#[tauri::command]
async fn mpv_start(app: tauri::AppHandle, window: tauri::WebviewWindow, options: HashMap<String, String>, observe: Vec<String>, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let wid = match window.window_handle().map(|h| h.as_raw()) {
        Ok(RawWindowHandle::Win32(h)) => Some(h.hwnd.get() as i64),
        _ => None,
    };
    let engine = state.mpv.clone();
    tauri::async_runtime::spawn_blocking(move || engine.start(app, wid, options, observe)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn mpv_command(args: Vec<String>, state: tauri::State<'_, AppState>) -> Result<(), String> {
    state.mpv.command(&args)
}

#[tauri::command]
fn mpv_set(name: String, value: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    state.mpv.set(&name, &value)
}

#[tauri::command]
fn mpv_get(name: String, state: tauri::State<'_, AppState>) -> Result<Option<String>, String> {
    state.mpv.get(&name)
}

#[tauri::command]
async fn mpv_destroy(state: tauri::State<'_, AppState>) -> Result<(), String> {
    let engine = state.mpv.clone();
    tauri::async_runtime::spawn_blocking(move || engine.destroy()).await.map_err(|e| e.to_string())
}

// MARK: On-device AI (For You)

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

// MARK: Accounts and system

/// Saved servers and sign-in tokens, encrypted for your Windows account (DPAPI).
#[tauri::command]
fn accounts_load(app: tauri::AppHandle) -> Option<String> {
    secure::load(&accounts_path(&app))
}

#[tauri::command]
fn accounts_save(app: tauri::AppHandle, data: Option<String>) -> Result<(), String> {
    secure::store(&accounts_path(&app), data.as_deref())
}

fn accounts_path(app: &tauri::AppHandle) -> std::path::PathBuf {
    app.path().app_data_dir().unwrap_or_default().join("accounts.bin")
}

/// Battery saver on: the AI part pauses.
#[tauri::command]
fn power_saver() -> bool {
    secure::battery_saver_on()
}

/// The computer's name, shown to the server as this device.
#[tauri::command]
fn device_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".into())
}

/// Writes a file the person picked in a Save dialog (logs, backups).
#[tauri::command]
fn write_text_file(path: String, contents: String) -> Result<(), String> {
    std::fs::write(&path, contents).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    // A second launch focuses the running window.
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            // A file opened with the app (drag onto the exe): play it.
            if let Some(path) = argv.iter().skip(1).find(|a| !a.starts_with('-')) {
                let _ = app.emit("open-file", path.clone());
            }
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }));
    }

    builder
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let root = app.path().resource_dir().unwrap_or_default();
            let data = app.path().app_data_dir().unwrap_or_default();
            let ai = Arc::new(ai::Engine::new(ai::Paths { resources: root.join("ai"), data: data.clone() }));
            let mpv = Arc::new(mpv::Engine::new(root.join("mpv").join("libmpv-2.dll")));
            app.manage(AppState { ai, mpv });
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window stops mpv first, so audio never outlives the window.
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                if let Some(state) = window.app_handle().try_state::<AppState>() {
                    state.mpv.destroy();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            mpv_info, mpv_start, mpv_command, mpv_set, mpv_get, mpv_destroy, ai_status, ai_cached, ai_vectors, accounts_load,
            accounts_save, power_saver, device_name, write_text_file
        ])
        .run(tauri::generate_context!())
        .expect("error while running JellyReco");
}
