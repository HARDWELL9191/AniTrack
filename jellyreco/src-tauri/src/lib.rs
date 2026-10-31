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

// Commands, properties and reads run on a worker thread, never on the main thread. A plain
// (non-async) Tauri command runs on the main thread, and on Linux that's also the thread mpv draws
// video on (gl.rs): mpv forbids calling it from its render thread, because a command that needs the
// video output (loadfile for the next / previous episode, seeking, track changes) then waits for a
// frame that thread can't draw until the command returns. mpv breaks that with timeouts, which is
// what made the player on Linux slow to react and skip or stall on next / previous.
#[tauri::command]
async fn mpv_command(args: Vec<String>, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let engine = state.mpv.clone();
    tauri::async_runtime::spawn_blocking(move || engine.command(&args)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn mpv_set(name: String, value: String, state: tauri::State<'_, AppState>) -> Result<(), String> {
    let engine = state.mpv.clone();
    tauri::async_runtime::spawn_blocking(move || engine.set(&name, &value)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn mpv_get(name: String, state: tauri::State<'_, AppState>) -> Result<Option<String>, String> {
    let engine = state.mpv.clone();
    tauri::async_runtime::spawn_blocking(move || engine.get(&name)).await.map_err(|e| e.to_string())?
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
    #[cfg(windows)]
    return std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".into());
    #[cfg(not(windows))]
    return std::fs::read_to_string("/proc/sys/kernel/hostname").map(|h| h.trim().to_string()).ok().filter(|h| !h.is_empty()).unwrap_or_else(|| "Linux".into());
}

/// Linux: settings that make video and the page work on every distribution, set before anything
/// starts (only where the person hasn't set them).
#[cfg(target_os = "linux")]
fn linux_environment() {
    let unset = |k: &str| std::env::var_os(k).is_none();
    // VA-API drivers (Intel, AMD) are in different folders on Debian/Ubuntu, Fedora/openSUSE and
    // Arch; the libva inside the AppImage has to be told where this system keeps them.
    if unset("LIBVA_DRIVERS_PATH") {
        let dirs: Vec<&str> = ["/usr/lib/x86_64-linux-gnu/dri", "/usr/lib64/dri", "/usr/lib/dri", "/run/opengl-driver/lib/dri", "/usr/local/lib/dri"]
            .into_iter()
            .filter(|d| std::path::Path::new(d).is_dir())
            .collect();
        if !dirs.is_empty() {
            std::env::set_var("LIBVA_DRIVERS_PATH", dirs.join(":"));
        }
    }
    // Nvidia's driver and WebKitGTK's DMA-BUF renderer can leave the window blank.
    if unset("WEBKIT_DISABLE_DMABUF_RENDERER") && std::path::Path::new("/proc/driver/nvidia/version").exists() {
        std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    }
}

/// Linux: WebKitGTK caps page updates near 60 per second ("Prefer Page Rendering Updates near
/// 60fps", on by default), so on a 120/144/165 Hz screen scrolling and animations run at 60. This
/// turns that off, so the page follows the display's refresh rate. Through WebKitGTK's feature API
/// (2.42+), looked up at run time so an older WebKitGTK just keeps its default.
#[cfg(target_os = "linux")]
fn tune_webkit(w: &tauri::WebviewWindow) {
    use std::ffi::{c_char, c_int, c_void, CStr};
    let keep_60 = std::env::var_os("JELLYRECO_WEBKIT_60HZ").is_some();
    let _ = w.with_webview(move |wv| {
        use gtk::glib::object::ObjectType;
        let view = wv.inner().as_ptr() as *mut c_void;
        type GetSettings = unsafe extern "C" fn(*mut c_void) -> *mut c_void;
        type AllFeatures = unsafe extern "C" fn() -> *mut c_void;
        type ListLen = unsafe extern "C" fn(*mut c_void) -> usize;
        type ListGet = unsafe extern "C" fn(*mut c_void, usize) -> *mut c_void;
        type Ident = unsafe extern "C" fn(*mut c_void) -> *const c_char;
        type SetEnabled = unsafe extern "C" fn(*mut c_void, *mut c_void, c_int);
        type Unref = unsafe extern "C" fn(*mut c_void);
        type SetPolicy = unsafe extern "C" fn(*mut c_void, c_int);
        type GetPolicy = unsafe extern "C" fn(*mut c_void) -> c_int;
        // SAFETY: WebKitGTK's documented C API, on the main thread, with the app's own WebView.
        unsafe {
            let this = libloading::os::unix::Library::this();
            let (Ok(get_settings), Ok(all), Ok(len), Ok(get), Ok(ident), Ok(set), Ok(unref)) = (
                this.get::<GetSettings>(b"webkit_web_view_get_settings\0"),
                this.get::<AllFeatures>(b"webkit_settings_get_all_features\0"),
                this.get::<ListLen>(b"webkit_feature_list_get_length\0"),
                this.get::<ListGet>(b"webkit_feature_list_get\0"),
                this.get::<Ident>(b"webkit_feature_get_identifier\0"),
                this.get::<SetEnabled>(b"webkit_settings_set_feature_enabled\0"),
                this.get::<Unref>(b"webkit_feature_list_unref\0"),
            ) else {
                return;
            };
            let settings = get_settings(view);
            // The page is drawn and composited on the GPU (WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS),
            // unless the person turned it off with WebKit's own environment variable.
            if !settings.is_null() && std::env::var_os("WEBKIT_DISABLE_COMPOSITING_MODE").is_none() {
                if let (Ok(set_policy), Ok(get_policy)) = (
                    this.get::<SetPolicy>(b"webkit_settings_set_hardware_acceleration_policy\0"),
                    this.get::<GetPolicy>(b"webkit_settings_get_hardware_acceleration_policy\0"),
                ) {
                    set_policy(settings, 1);
                    eprintln!("[webkit] hardware acceleration policy: {}", ["on demand", "always", "never"].get(get_policy(settings) as usize).unwrap_or(&"?"));
                }
            }
            if keep_60 {
                return;
            }
            let list = all();
            if settings.is_null() || list.is_null() {
                return;
            }
            for i in 0..len(list) {
                let f = get(list, i);
                let id = ident(f);
                if !id.is_null() && CStr::from_ptr(id).to_bytes() == b"PreferPageRenderingUpdatesNear60FPS" {
                    set(settings, f, 0);
                    if std::env::var_os("JELLYRECO_DEBUG_VIDEO").is_some() {
                        eprintln!("[webkit] page updates follow the display's refresh rate");
                    }
                }
            }
            unref(list);
        }
    });
}

/// The window's icon (taskbar, Alt+Tab): the dark (default) or light app icon from Settings.
/// The installed shortcut / AppImage keeps the dark icon; on Linux under Wayland the dock shows that one.
#[tauri::command]
fn set_app_icon(window: tauri::WebviewWindow, variant: String) -> Result<(), String> {
    let bytes: &[u8] = if variant == "light" { include_bytes!("../icons/window-light.png") } else { include_bytes!("../icons/window-dark.png") };
    let image = tauri::image::Image::from_bytes(bytes).map_err(|e| e.to_string())?;
    window.set_icon(image).map_err(|e| e.to_string())
}

/// The video file the app was started with, once (the page asks when it's ready).
#[tauri::command]
fn launch_file() -> Option<String> {
    static TAKEN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if TAKEN.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return None;
    }
    std::env::args().skip(1).find(|a| !a.starts_with('-') && std::path::Path::new(a).is_file())
}

/// "windows" or "linux" (the page adapts a few platform details).
#[tauri::command]
fn platform() -> &'static str {
    if cfg!(windows) { "windows" } else if cfg!(target_os = "linux") { "linux" } else { "other" }
}

/// Writes a file the person picked in a Save dialog (logs, backups).
#[tauri::command]
fn write_text_file(path: String, contents: String) -> Result<(), String> {
    std::fs::write(&path, contents).map_err(|e| e.to_string())
}

/// Reads a file the person picked in an Open dialog (image uploads), as base64. Size-capped.
#[tauri::command]
fn read_file_base64(path: String) -> Result<String, String> {
    use base64::Engine as _;
    let meta = std::fs::metadata(&path).map_err(|e| e.to_string())?;
    if meta.len() > 40 * 1024 * 1024 {
        return Err("That file is too big (40 MB at most).".into());
    }
    let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
    Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[cfg(target_os = "linux")]
    linux_environment();
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
            // Linux: the GL area for the video goes under the WebView.
            #[cfg(target_os = "linux")]
            if let Some(w) = app.get_webview_window("main") {
                if let Err(e) = mpv::gl::install(&w) {
                    eprintln!("video surface: {e}");
                }
                tune_webkit(&w);
            }
            let root = app.path().resource_dir().unwrap_or_default();
            let data = app.path().app_data_dir().unwrap_or_default();
            let ai = Arc::new(ai::Engine::new(ai::Paths { resources: root.join("ai"), data: data.clone() }));
            #[cfg(windows)]
            let mpv_lib = root.join("mpv").join("libmpv-2.dll");
            // Linux: the AppImage's own libmpv (next to the app), else the system's.
            #[cfg(not(windows))]
            let mpv_lib = [root.join("mpv").join("libmpv.so.2"), root.join("lib").join("libmpv.so.2")]
                .into_iter()
                .find(|p| p.exists())
                .unwrap_or_else(|| std::path::PathBuf::from("libmpv.so.2"));
            let mpv = Arc::new(mpv::Engine::new(mpv_lib));
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
            accounts_save, power_saver, device_name, platform, launch_file, set_app_icon, write_text_file, read_file_base64
        ])
        .run(tauri::generate_context!())
        .expect("error while running JellyReco");
}
