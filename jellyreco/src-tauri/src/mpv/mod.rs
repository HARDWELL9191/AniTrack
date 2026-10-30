//! The playback engine: libmpv (mpv + FFmpeg, so practically every container and codec) drawing
//! into the app window. mpv gets the main window's handle as `wid` and renders its video in a
//! child window behind the WebView; the WebView is transparent while video plays, so the React
//! controls float over the picture (the technique tauri-plugin-libmpv uses on Windows).
//!
//! The UI drives mpv with commands and properties; property changes and file events come back as
//! "mpv" events. Values travel as strings (node properties like track-list arrive as JSON).

pub mod ffi;

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
}

impl Engine {
    pub fn new(dll: PathBuf) -> Self {
        Self { dll, api: Mutex::new(None), instance: Mutex::new(None) }
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
        let mut guard = self.instance.lock().unwrap();
        if guard.is_some() {
            return Ok(());
        }
        // SAFETY: documented libmpv sequence: create, set options, initialize.
        let handle = unsafe { (api.create)() };
        if handle.is_null() {
            return Err("mpv couldn't be created.".into());
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
        if let Some(wid) = wid {
            set_opt("wid", &wid.to_string())?;
        }
        let mut warnings = Vec::new();
        for (k, v) in &options {
            // An option an older/newer libmpv doesn't know shouldn't stop playback.
            if let Err(e) = set_opt(k, v) {
                warnings.push(e);
            }
        }
        let rc = unsafe { (api.initialize)(handle) };
        if rc < 0 {
            unsafe { (api.terminate_destroy)(handle) };
            return Err(format!("mpv didn't start: {}", api.error(rc)));
        }
        let level = ffi::cstring("warn");
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
            let (api, stop, h) = (api.clone(), stop.clone(), handle as usize);
            std::thread::Builder::new()
                .name("mpv-events".into())
                .spawn(move || event_loop(api, h as ffi::Handle, stop, app))
                .map_err(|e| e.to_string())?
        };
        *guard = Some(Instance { handle: handle as usize, stop, thread: Some(thread) });
        Ok(())
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
        let _ = app.emit("mpv", event);
    }
}
