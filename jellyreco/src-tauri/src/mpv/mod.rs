//! The playback engine: libmpv (mpv + FFmpeg, so practically every container and codec) drawing
//! into the app window. mpv gets the main window's handle as `wid` and renders its video in a
//! child window behind the WebView; the WebView is transparent while video plays, so the React
//! controls float over the picture (the technique tauri-plugin-libmpv uses on Windows).
//!
//! On Linux there's no window to give mpv, so it draws with its OpenGL render API into a GTK GL
//! area under the WebView instead (see gl.rs).
//!
//! The UI drives mpv with commands and properties; property changes and file events come back as
//! "mpv" events. Values travel as strings (node properties like track-list arrive as JSON).

pub mod ffi;

/// LC_NUMERIC = "C" for this process (glibc's LC_NUMERIC is 1).
#[cfg(target_os = "linux")]
fn c_numeric_locale() {
    extern "C" {
        fn setlocale(category: std::ffi::c_int, locale: *const std::ffi::c_char) -> *mut std::ffi::c_char;
    }
    const LC_NUMERIC: std::ffi::c_int = 1;
    // SAFETY: called on the thread that starts mpv, before mpv exists; the string is static.
    unsafe { setlocale(LC_NUMERIC, c"C".as_ptr()) };
}
#[cfg(target_os = "linux")]
pub mod gl;

use serde::Serialize;
use std::collections::HashMap;
use std::ffi::c_char;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

#[derive(Clone, Serialize)]
pub struct Info {
    pub available: bool,
    pub detail: String,
    pub version: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum Event {
    Property { name: String, value: Option<String> },
    StartFile,
    FileLoaded,
    EndFile { reason: String, error: Option<String> },
    PlaybackRestart,
    Seek,
    VideoReconfig,
    Idle,
    Log { level: String, prefix: String, text: String },
    Shutdown,
}

struct Instance {
    handle: usize, // mpv_handle*, kept as an integer so the struct is Send
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

pub struct Engine {
    dll: PathBuf,
    api: Mutex<Option<Result<Arc<ffi::Api>, String>>>,
    instance: Mutex<Option<Instance>>,
    starting: AtomicBool,
}

impl Engine {
    pub fn new(dll: PathBuf) -> Self {
        Self { dll, api: Mutex::new(None), instance: Mutex::new(None), starting: AtomicBool::new(false) }
    }

    fn api(&self) -> Result<Arc<ffi::Api>, String> {
        let mut guard = self.api.lock().unwrap();
        if guard.is_none() {
            *guard = Some(ffi::Api::load(&self.dll).map(Arc::new));
        }
        guard.as_ref().unwrap().clone()
    }

    pub fn info(&self) -> Info {
        match self.api() {
            Ok(api) => {
                // SAFETY: plain C call without arguments.
                let v = unsafe { (api.client_api_version)() } as u64;
                Info { available: true, detail: format!("libmpv client API {}.{}", v >> 16, v & 0xffff), version: None }
            }
            Err(e) => Info { available: false, detail: e, version: None },
        }
    }

    fn handle(&self) -> Result<(Arc<ffi::Api>, ffi::Handle), String> {
        let api = self.api()?;
        let guard = self.instance.lock().unwrap();
        let inst = guard.as_ref().ok_or("The player isn't running.")?;
        Ok((api, inst.handle as ffi::Handle))
    }

    /// Creates mpv inside `wid` (once) with these options and starts its event thread.
    pub fn start(&self, app: AppHandle, wid: Option<i64>, options: HashMap<String, String>, observe: Vec<String>) -> Result<(), String> {
        let api = self.api()?;
        // No lock is held while mpv starts (on Linux that waits for the GTK thread, which also runs
        // the app's commands): a flag keeps it to one start at a time.
        if self.instance.lock().unwrap().is_some() || self.starting.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        let result = self.create(&api, &app, wid, options, observe);
        self.starting.store(false, Ordering::SeqCst);
        let inst = result?;
        *self.instance.lock().unwrap() = Some(inst);
        Ok(())
    }

    fn create(&self, api: &Arc<ffi::Api>, app: &AppHandle, wid: Option<i64>, options: HashMap<String, String>, observe: Vec<String>) -> Result<Instance, String> {
        // libmpv only starts with C number formatting, and GTK switches the process to the
        // system's locale at start-up (e.g. Slovenian, with decimal commas). Only numbers are
        // reset: text, dates and the page keep the person's language.
        #[cfg(target_os = "linux")]
        c_numeric_locale();
        // SAFETY: documented libmpv sequence: create, set options, initialize.
        let handle = unsafe { (api.create)() };
        if handle.is_null() {
            return Err("mpv couldn't be created (libmpv needs C number formatting; see the log).".into());
        }
        let set_opt = |name: &str, value: &str| -> Result<(), String> {
            let (n, v) = (ffi::cstring(name), ffi::cstring(value));
            let rc = unsafe { (api.set_option_string)(handle, n.as_ptr(), v.as_ptr()) };
            if rc < 0 {
                Err(format!("option {name}={value}: {}", api.error(rc)))
            } else {
                Ok(())
            }
        };
        #[cfg(not(target_os = "linux"))]
        if let Some(wid) = wid {
            set_opt("wid", &wid.to_string())?;
        }
        #[cfg(target_os = "linux")]
        let _ = wid;
        let mut warnings = Vec::new();
        for (k, v) in &options {
            // Linux: mpv draws through the render API, so its own output and GPU options don't apply.
            #[cfg(target_os = "linux")]
            // force-window would make mpv set up its video output right away, racing the render
            // context created just after mpv starts: when mpv wins, video is switched off.
            if matches!(k.as_str(), "vo" | "gpu-api" | "gpu-context" | "wid" | "force-window" | "d3d11-flip" | "d3d11-output-csp" | "d3d11-exclusive-fs") {
                continue;
            }
            // An option an older/newer libmpv doesn't know shouldn't stop playback.
            if let Err(e) = set_opt(k, v) {
                warnings.push(e);
            }
        }
        #[cfg(target_os = "linux")]
        {
            set_opt("vo", "libmpv")?;
            set_opt("force-window", "no")?;
            // Frames are drawn on GTK's main thread without waiting for their display time (gl.rs),
            // so mpv shouldn't render them ahead of time either (mpv's advice for that setup).
            let _ = set_opt("video-timing-offset", "0");
            // Zero-copy hardware decoding where the GL context allows it, else hardware decoding with a copy.
            // (A Windows-only choice like d3d11va synced from another PC counts as automatic.)
            if options.get("hwdec").is_some_and(|h| h == "auto-safe" || h.starts_with("d3d11")) {
                let _ = set_opt("hwdec", "auto-safe,auto-copy-safe");
            }
        }
        let rc = unsafe { (api.initialize)(handle) };
        if rc < 0 {
            unsafe { (api.terminate_destroy)(handle) };
            return Err(format!("mpv didn't start: {}", api.error(rc)));
        }
        #[cfg(target_os = "linux")]
        if let Err(e) = gl::attach(api.clone(), handle) {
            unsafe { (api.terminate_destroy)(handle) };
            return Err(e);
        }
        let level = ffi::cstring(if std::env::var_os("JELLYRECO_DEBUG_VIDEO").is_some() { "v" } else { "warn" });
        unsafe { (api.request_log_messages)(handle, level.as_ptr()) };
        for (i, name) in observe.iter().enumerate() {
            let n = ffi::cstring(name);
            unsafe { (api.observe_property)(handle, i as u64 + 1, n.as_ptr(), ffi::FORMAT_STRING) };
        }
        for w in warnings {
            let _ = app.emit("mpv", Event::Log { level: "warn".into(), prefix: "jellyreco".into(), text: w });
        }

        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (api, stop, h, app) = (api.clone(), stop.clone(), handle as usize, app.clone());
            std::thread::Builder::new()
                .name("mpv-events".into())
                .spawn(move || event_loop(api, h as ffi::Handle, stop, app))
                .map_err(|e| e.to_string())?
        };
        Ok(Instance { handle: handle as usize, stop, thread: Some(thread) })
    }

    pub fn command(&self, args: &[String]) -> Result<(), String> {
        let (api, h) = self.handle()?;
        let owned: Vec<_> = args.iter().map(|a| ffi::cstring(a)).collect();
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        // SAFETY: null-terminated array of valid C strings that outlive the call.
        let rc = unsafe { (api.command)(h, ptrs.as_mut_ptr()) };
        if rc < 0 {
            Err(format!("{}: {}", args.first().map(String::as_str).unwrap_or("command"), api.error(rc)))
        } else {
            Ok(())
        }
    }

    pub fn set(&self, name: &str, value: &str) -> Result<(), String> {
        // Linux: the render API output stays as it is (the page re-sends every live option).
        #[cfg(target_os = "linux")]
        if matches!(name, "vo" | "gpu-api" | "gpu-context" | "wid" | "force-window") || name.starts_with("d3d11") {
            return Ok(());
        }
        #[cfg(target_os = "linux")]
        let value = if name == "hwdec" && (value == "auto-safe" || value.starts_with("d3d11")) { "auto-safe,auto-copy-safe" } else { value };
        let (api, h) = self.handle()?;
        let (n, v) = (ffi::cstring(name), ffi::cstring(value));
        let rc = unsafe { (api.set_property_string)(h, n.as_ptr(), v.as_ptr()) };
        if rc < 0 {
            Err(format!("{name}: {}", api.error(rc)))
        } else {
            Ok(())
        }
    }

    pub fn get(&self, name: &str) -> Result<Option<String>, String> {
        let (api, h) = self.handle()?;
        let n = ffi::cstring(name);
        // SAFETY: the returned string is owned by us and freed with mpv_free.
        unsafe {
            let p = (api.get_property_string)(h, n.as_ptr());
            if p.is_null() {
                return Ok(None);
            }
            let s = ffi::cstr(p);
            (api.free)(p as *mut _);
            Ok(s)
        }
    }

    /// Stops the event thread and destroys mpv (frees decoders and the GPU).
    pub fn destroy(&self) {
        let inst = self.instance.lock().unwrap().take();
        let (Some(mut inst), Ok(api)) = (inst, self.api()) else { return };
        let h = inst.handle as ffi::Handle;
        inst.stop.store(true, Ordering::SeqCst);
        unsafe { (api.wakeup)(h) };
        if let Some(t) = inst.thread.take() {
            let _ = t.join();
        }
        // Linux: the renderer goes first (it belongs to the GL area).
        #[cfg(target_os = "linux")]
        gl::detach();
        // SAFETY: the event thread has exited, nothing else uses the handle.
        unsafe { (api.terminate_destroy)(h) };
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.destroy();
    }
}

fn event_loop(api: Arc<ffi::Api>, h: ffi::Handle, stop: Arc<AtomicBool>, app: AppHandle) {
    let mut names: HashMap<String, Option<String>> = HashMap::new();
    // Positions change on every video frame. The page shows them ten times a second, so they're
    // forwarded at most every 90 ms (each forward is work on the app's main thread, which on Linux
    // also draws the video); the latest value is held back and sent with the next event, so a pause
    // or seek never leaves the bar behind.
    const RAPID: [&str; 2] = ["time-pos", "demuxer-cache-time"];
    let mut last_sent: HashMap<&'static str, std::time::Instant> = HashMap::new();
    let mut held: HashMap<&'static str, Option<String>> = HashMap::new();
    while !stop.load(Ordering::SeqCst) {
        // SAFETY: only this thread waits on the handle; the pointer is valid until the next call.
        let ev = unsafe { &*(api.wait_event)(h, 1.0) };
        let event = match ev.event_id {
            ffi::EVENT_NONE => continue,
            ffi::EVENT_SHUTDOWN => {
                let _ = app.emit("mpv", Event::Shutdown);
                break;
            }
            ffi::EVENT_PROPERTY_CHANGE if !ev.data.is_null() => unsafe {
                let p = &*(ev.data as *const ffi::EventProperty);
                let name = ffi::cstr(p.name).unwrap_or_default();
                let value = if p.format == ffi::FORMAT_STRING && !p.data.is_null() { ffi::cstr(*(p.data as *const *const c_char)) } else { None };
                // time-pos changes many times a second: only forward real changes.
                if names.get(&name) == Some(&value) {
                    continue;
                }
                names.insert(name.clone(), value.clone());
                if let Some(key) = RAPID.iter().copied().find(|k| *k == name) {
                    let now = std::time::Instant::now();
                    if last_sent.get(key).is_some_and(|t| now.duration_since(*t) < std::time::Duration::from_millis(90)) {
                        held.insert(key, value);
                        continue;
                    }
                    last_sent.insert(key, now);
                    held.remove(key);
                }
                Event::Property { name, value }
            },
            ffi::EVENT_START_FILE => Event::StartFile,
            ffi::EVENT_FILE_LOADED => Event::FileLoaded,
            ffi::EVENT_END_FILE => {
                let (reason, error) = if ev.data.is_null() {
                    ("unknown".to_string(), None)
                } else {
                    let e = unsafe { &*(ev.data as *const ffi::EventEndFile) };
                    let reason = match e.reason {
                        0 => "eof",
                        2 => "stop",
                        3 => "quit",
                        4 => "error",
                        5 => "redirect",
                        _ => "unknown",
                    };
                    (reason.to_string(), (e.error < 0).then(|| api.error(e.error)))
                };
                Event::EndFile { reason, error }
            }
            ffi::EVENT_PLAYBACK_RESTART => Event::PlaybackRestart,
            ffi::EVENT_SEEK => Event::Seek,
            ffi::EVENT_VIDEO_RECONFIG => Event::VideoReconfig,
            ffi::EVENT_IDLE => Event::Idle,
            ffi::EVENT_LOG_MESSAGE if !ev.data.is_null() => unsafe {
                let m = &*(ev.data as *const ffi::EventLogMessage);
                Event::Log {
                    level: ffi::cstr(m.level).unwrap_or_default(),
                    prefix: ffi::cstr(m.prefix).unwrap_or_default(),
                    text: ffi::cstr(m.text).unwrap_or_default().trim_end().to_string(),
                }
            },
            _ => continue,
        };
        // JELLYRECO_DEBUG_VIDEO=1: mpv's warnings and errors also go to the terminal.
        if let Event::Log { level, prefix, text } = &event {
            static DEBUG: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
            if *DEBUG.get_or_init(|| std::env::var_os("JELLYRECO_DEBUG_VIDEO").is_some()) {
                eprintln!("[mpv {level}] {prefix}: {text}");
            }
        }
        // Anything else happening (pause, seek, a new file...) first sends the held-back positions.
        if !matches!(&event, Event::Property { name, .. } if RAPID.contains(&name.as_str())) {
            for (key, value) in held.drain() {
                last_sent.insert(key, std::time::Instant::now());
                let _ = app.emit("mpv", Event::Property { name: key.to_string(), value });
            }
        }
        let _ = app.emit("mpv", event);
    }
}
