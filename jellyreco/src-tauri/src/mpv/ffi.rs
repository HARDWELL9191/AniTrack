//! libmpv's C API (client.h, API 2.x), loaded at run time from libmpv-2.dll next to the app.
//! Loading it dynamically means no import library is needed for the ARM64 build, and a missing
//! DLL becomes a readable error instead of a crash at start-up.
//! Layouts and values checked against mpv's include/mpv/client.h (MPV_CLIENT_API_VERSION 2.6).

use libloading::Library;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;

pub type Handle = *mut c_void;

// mpv_format
pub const FORMAT_STRING: c_int = 1;

// mpv_event_id
pub const EVENT_NONE: c_int = 0;
pub const EVENT_SHUTDOWN: c_int = 1;
pub const EVENT_LOG_MESSAGE: c_int = 2;
pub const EVENT_START_FILE: c_int = 6;
pub const EVENT_END_FILE: c_int = 7;
pub const EVENT_FILE_LOADED: c_int = 8;
pub const EVENT_IDLE: c_int = 11;
pub const EVENT_VIDEO_RECONFIG: c_int = 17;
pub const EVENT_AUDIO_RECONFIG: c_int = 18;
pub const EVENT_SEEK: c_int = 20;
pub const EVENT_PLAYBACK_RESTART: c_int = 21;
pub const EVENT_PROPERTY_CHANGE: c_int = 22;

#[repr(C)]
pub struct Event {
    pub event_id: c_int,
    pub error: c_int,
    pub reply_userdata: u64,
    pub data: *mut c_void,
}

#[repr(C)]
pub struct EventProperty {
    pub name: *const c_char,
    pub format: c_int,
    pub data: *mut c_void,
}

#[repr(C)]
pub struct EventLogMessage {
    pub prefix: *const c_char,
    pub level: *const c_char,
    pub text: *const c_char,
    pub log_level: c_int,
}

#[repr(C)]
pub struct EventEndFile {
    pub reason: c_int,
    pub error: c_int,
    pub playlist_entry_id: i64,
    pub playlist_insert_id: i64,
    pub playlist_insert_num_entries: c_int,
}

type FnCreate = unsafe extern "C" fn() -> Handle;
type FnInitialize = unsafe extern "C" fn(Handle) -> c_int;
type FnTerminate = unsafe extern "C" fn(Handle);
type FnSetOptionString = unsafe extern "C" fn(Handle, *const c_char, *const c_char) -> c_int;
type FnCommand = unsafe extern "C" fn(Handle, *mut *const c_char) -> c_int;
type FnSetPropertyString = unsafe extern "C" fn(Handle, *const c_char, *const c_char) -> c_int;
type FnGetPropertyString = unsafe extern "C" fn(Handle, *const c_char) -> *mut c_char;
type FnObserveProperty = unsafe extern "C" fn(Handle, u64, *const c_char, c_int) -> c_int;
type FnWaitEvent = unsafe extern "C" fn(Handle, f64) -> *mut Event;
type FnWakeup = unsafe extern "C" fn(Handle);
type FnFree = unsafe extern "C" fn(*mut c_void);
type FnErrorString = unsafe extern "C" fn(c_int) -> *const c_char;
type FnRequestLog = unsafe extern "C" fn(Handle, *const c_char) -> c_int;
type FnApiVersion = unsafe extern "C" fn() -> std::ffi::c_ulong;

// Render API (Linux: mpv draws with OpenGL into the app's GL area).
pub type RenderContext = *mut c_void;
#[repr(C)]
pub struct RenderParam {
    pub kind: c_int,
    pub data: *mut c_void,
}
#[repr(C)]
pub struct OpenGlInitParams {
    pub get_proc_address: Option<unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void>,
    pub get_proc_address_ctx: *mut c_void,
}
#[repr(C)]
pub struct OpenGlFbo {
    pub fbo: c_int,
    pub w: c_int,
    pub h: c_int,
    pub internal_format: c_int,
}
pub const RENDER_PARAM_INVALID: c_int = 0;
pub const RENDER_PARAM_API_TYPE: c_int = 1;
pub const RENDER_PARAM_OPENGL_INIT_PARAMS: c_int = 2;
pub const RENDER_PARAM_OPENGL_FBO: c_int = 3;
pub const RENDER_PARAM_FLIP_Y: c_int = 4;
pub const RENDER_PARAM_X11_DISPLAY: c_int = 8;
pub const RENDER_PARAM_WL_DISPLAY: c_int = 9;
type FnRenderCreate = unsafe extern "C" fn(*mut RenderContext, Handle, *mut RenderParam) -> c_int;
type FnRenderSetUpdate = unsafe extern "C" fn(RenderContext, Option<unsafe extern "C" fn(*mut c_void)>, *mut c_void);
type FnRenderUpdate = unsafe extern "C" fn(RenderContext) -> u64;
type FnRenderRender = unsafe extern "C" fn(RenderContext, *mut RenderParam) -> c_int;
type FnRenderFree = unsafe extern "C" fn(RenderContext);

/// The libmpv functions the player uses.
pub struct Api {
    _lib: Library,
    pub create: FnCreate,
    pub initialize: FnInitialize,
    pub terminate_destroy: FnTerminate,
    pub set_option_string: FnSetOptionString,
    pub command: FnCommand,
    pub set_property_string: FnSetPropertyString,
    pub get_property_string: FnGetPropertyString,
    pub observe_property: FnObserveProperty,
    pub wait_event: FnWaitEvent,
    pub wakeup: FnWakeup,
    pub free: FnFree,
    pub error_string: FnErrorString,
    pub request_log_messages: FnRequestLog,
    pub client_api_version: FnApiVersion,
    pub render_context_create: Option<FnRenderCreate>,
    pub render_context_set_update_callback: Option<FnRenderSetUpdate>,
    pub render_context_update: Option<FnRenderUpdate>,
    pub render_context_render: Option<FnRenderRender>,
    pub render_context_free: Option<FnRenderFree>,
}

// The function pointers are plain C entry points; libmpv itself is thread-safe.
unsafe impl Send for Api {}
unsafe impl Sync for Api {}

impl Api {
    pub fn load(dll: &Path) -> Result<Self, String> {
        // SAFETY: loading a known library and resolving documented symbols with their C signatures.
        unsafe {
            let lib = Library::new(dll).map_err(|e| format!("couldn't load {}: {e}", dll.display()))?;
            macro_rules! sym {
                ($name:literal) => {
                    *lib.get(concat!($name, "\0").as_bytes()).map_err(|e| format!("{}: {e}", $name))?
                };
            }
            Ok(Self {
                create: sym!("mpv_create"),
                initialize: sym!("mpv_initialize"),
                terminate_destroy: sym!("mpv_terminate_destroy"),
                set_option_string: sym!("mpv_set_option_string"),
                command: sym!("mpv_command"),
                set_property_string: sym!("mpv_set_property_string"),
                get_property_string: sym!("mpv_get_property_string"),
                observe_property: sym!("mpv_observe_property"),
                wait_event: sym!("mpv_wait_event"),
                wakeup: sym!("mpv_wakeup"),
                free: sym!("mpv_free"),
                error_string: sym!("mpv_error_string"),
                request_log_messages: sym!("mpv_request_log_messages"),
                client_api_version: sym!("mpv_client_api_version"),
                render_context_create: lib.get(b"mpv_render_context_create\0").ok().map(|f| *f),
                render_context_set_update_callback: lib.get(b"mpv_render_context_set_update_callback\0").ok().map(|f| *f),
                render_context_update: lib.get(b"mpv_render_context_update\0").ok().map(|f| *f),
                render_context_render: lib.get(b"mpv_render_context_render\0").ok().map(|f| *f),
                render_context_free: lib.get(b"mpv_render_context_free\0").ok().map(|f| *f),
                _lib: lib,
            })
        }
    }

    pub fn error(&self, code: c_int) -> String {
        // SAFETY: mpv_error_string returns a static string for any code.
        unsafe { cstr((self.error_string)(code)).unwrap_or_else(|| format!("error {code}")) }
    }
}

pub fn cstring(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

/// Copies a C string (null → None).
pub unsafe fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        None
    } else {
        Some(CStr::from_ptr(p).to_string_lossy().into_owned())
    }
}
