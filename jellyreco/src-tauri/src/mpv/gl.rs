//! Linux: the video under the page. mpv can't draw into a child window under the WebView here
//! (there is no such window on Wayland, and on X11 GTK draws the WebView into the same window), so
//! the app's GTK window gets an overlay: a GL area at the bottom, where mpv draws every frame with
//! its OpenGL render API, and the (transparent) WebView on top with the controls. Works on Wayland
//! and X11 (the approach Celluloid, the GTK mpv player, uses). Everything GTK runs on the main thread.

use super::ffi::{self, Api, OpenGlFbo, OpenGlInitParams, RenderParam};
use gtk::glib;
use gtk::prelude::*;
use libloading::Library;
use std::cell::RefCell;
use std::ffi::{c_char, c_int, c_void, CStr};
use std::sync::{mpsc, Arc, OnceLock};

thread_local! {
    static AREA: RefCell<Option<gtk::GLArea>> = const { RefCell::new(None) };
    static RENDER: RefCell<Option<(Arc<Api>, usize)>> = const { RefCell::new(None) };
    static TICK: RefCell<Option<gtk::TickCallbackId>> = const { RefCell::new(None) };
}

/// mpv has a new frame waiting (set on mpv's thread, taken on the next display refresh).
static PENDING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The app's window, to switch the WebView between see-through (video playing) and opaque.
static WINDOW: OnceLock<tauri::WebviewWindow> = OnceLock::new();

/// See-through only while mpv draws under the page. An opaque WebView (the rest of the time) lets
/// WebKit skip blending the page with what's beneath it on every repaint.
fn see_through(on: bool) {
    if let Some(w) = WINDOW.get() {
        let color = if on { tauri::window::Color(0, 0, 0, 0) } else { tauri::window::Color(0, 0, 0, 255) };
        if let Err(e) = w.set_background_color(Some(color)) {
            if debug() {
                eprintln!("[video] WebView background: {e}");
            }
        }
    }
}

/// Puts a GL area under the WebView (once, at start-up, on the main thread).
pub fn install(window: &tauri::WebviewWindow) -> Result<(), String> {
    let win = window.gtk_window().map_err(|e| e.to_string())?;
    let vbox = window.default_vbox().map_err(|e| e.to_string())?;
    let area = gtk::GLArea::new();
    area.set_hexpand(true);
    area.set_vexpand(true);
    area.set_auto_render(false); // drawn when mpv has a frame (and on resize)
    area.connect_render(|area, _| {
        draw(area);
        glib::Propagation::Stop
    });
    area.connect_resize(|area, _, _| area.queue_render());
    // The overlay's base is an empty box, and the GL area and the WebView both sit on it filling
    // the window (GL area beneath). That way the GL area can be hidden while no video plays: a GL
    // area in the window makes GTK composite the whole window through OpenGL on every repaint
    // (and on X11 read the picture back from the GPU), which slowed down the app even with no video.
    let overlay = gtk::Overlay::new();
    let base = gtk::Box::new(gtk::Orientation::Vertical, 0);
    base.set_hexpand(true);
    base.set_vexpand(true);
    win.remove(&vbox);
    overlay.add(&base);
    overlay.add_overlay(&area);
    overlay.add_overlay(&vbox);
    win.add(&overlay);
    overlay.show_all();
    area.hide();
    AREA.with(|a| *a.borrow_mut() = Some(area));
    let _ = WINDOW.set(window.clone());
    see_through(false);
    Ok(())
}

/// Runs `f` on the GTK main thread and waits for it (directly if this is the main thread).
pub fn on_main<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    let ctx = glib::MainContext::default();
    if ctx.is_owner() {
        return f();
    }
    let (tx, rx) = mpsc::channel();
    ctx.invoke(move || {
        let _ = tx.send(f());
    });
    rx.recv().expect("the main thread is gone")
}

/// Connects mpv's renderer to the GL area (main thread).
pub fn attach(api: Arc<Api>, handle: ffi::Handle) -> Result<(), String> {
    let h = handle as usize;
    on_main(move || attach_here(api, h as ffi::Handle))
}

/// JELLYRECO_DEBUG_VIDEO=1 prints what the video surface does (for bug reports).
fn debug() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("JELLYRECO_DEBUG_VIDEO").is_some())
}

fn attach_here(api: Arc<Api>, handle: ffi::Handle) -> Result<(), String> {
    let (Some(create), Some(set_update)) = (api.render_context_create, api.render_context_set_update_callback) else {
        return Err("This libmpv has no render API.".into());
    };
    let area = AREA.with(|a| a.borrow().clone()).ok_or("The video surface isn't ready.")?;
    // Shown (and so given its GL context) only while a video is open.
    area.show();
    area.realize();
    see_through(true);
    area.make_current();
    if let Some(e) = area.error() {
        return Err(format!("OpenGL isn't available: {e}"));
    }
    let mut init = OpenGlInitParams { get_proc_address: Some(get_proc_address), get_proc_address_ctx: std::ptr::null_mut() };
    let api_type = ffi::cstring("opengl");
    let mut params = vec![
        RenderParam { kind: ffi::RENDER_PARAM_API_TYPE, data: api_type.as_ptr() as *mut c_void },
        RenderParam { kind: ffi::RENDER_PARAM_OPENGL_INIT_PARAMS, data: &mut init as *mut _ as *mut c_void },
    ];
    // The display lets mpv share hardware-decoded frames with OpenGL (VA-API, VDPAU).
    let (kind, display) = native_display();
    if !display.is_null() {
        params.push(RenderParam { kind, data: display });
    }
    params.push(RenderParam { kind: ffi::RENDER_PARAM_INVALID, data: std::ptr::null_mut() });
    let mut ctx: ffi::RenderContext = std::ptr::null_mut();
    // SAFETY: documented render API call with a null-terminated parameter list; the GL context is current.
    let rc = unsafe { create(&mut ctx, handle, params.as_mut_ptr()) };
    if rc < 0 || ctx.is_null() {
        return Err(format!("mpv's renderer didn't start: {}", api.error(rc)));
    }
    // SAFETY: the callback only schedules a redraw on the main thread.
    unsafe { set_update(ctx, Some(on_update), std::ptr::null_mut()) };
    RENDER.with(|r| *r.borrow_mut() = Some((api, ctx as usize)));
    // New frames are drawn on the display's own refresh (GTK's frame clock), so video keeps moving
    // at the screen's rate without waiting for something else in the window to redraw (that made
    // playback look stuck until you paused and played again), and high refresh rates are kept.
    let id = area.add_tick_callback(|area, _| {
        if PENDING.swap(false, std::sync::atomic::Ordering::AcqRel) {
            area.queue_render();
        }
        glib::ControlFlow::Continue
    });
    TICK.with(|t| *t.borrow_mut() = Some(id));
    if debug() {
        eprintln!("[video] renderer attached (display param {kind}, {}x{})", area.allocated_width(), area.allocated_height());
    }
    area.queue_render();
    Ok(())
}

/// Frees mpv's renderer (main thread; before mpv itself is destroyed).
pub fn detach() {
    on_main(|| {
        if let Some(id) = TICK.with(|t| t.borrow_mut().take()) {
            id.remove();
        }
        let Some((api, ctx)) = RENDER.with(|r| r.borrow_mut().take()) else { return };
        if let Some(area) = AREA.with(|a| a.borrow().clone()) {
            area.make_current();
            if let Some(free) = api.render_context_free {
                // SAFETY: the context belongs to this GL area and isn't used after this.
                unsafe { free(ctx as ffi::RenderContext) };
            }
            area.queue_render();
        }
    });
    on_main(|| {
        if let Some(area) = AREA.with(|a| a.borrow().clone()) {
            area.hide();
        }
        see_through(false);
    })
}

/// mpv has a new frame (called on one of mpv's threads): redraw on the main thread.
/// The GL area's tick callback picks it up on the next display refresh (one redraw per refresh at
/// most, however often mpv calls).
unsafe extern "C" fn on_update(_: *mut c_void) {
    PENDING.store(true, std::sync::atomic::Ordering::Release);
}

const GL_COLOR_BUFFER_BIT: u32 = 0x4000;
const GL_DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;

fn draw(area: &gtk::GLArea) {
    let gl = loader();
    let drawn = RENDER.with(|r| {
        let r = r.borrow();
        let Some((api, ctx)) = r.as_ref() else { return false };
        let (Some(render), Some(update)) = (api.render_context_render, api.render_context_update) else { return false };
        let scale = area.scale_factor();
        let (w, h) = (area.allocated_width() * scale, area.allocated_height() * scale);
        let mut fbo_id: c_int = 0;
        if let Some(get) = gl.get_integerv {
            // SAFETY: GTK made the area's context current for this render signal.
            unsafe { get(GL_DRAW_FRAMEBUFFER_BINDING, &mut fbo_id) };
        }
        if debug() {
            static FRAMES: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            let n = FRAMES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if n < 5 || n % 120 == 0 {
                eprintln!("[video] frame {n}: fbo {fbo_id}, {w}x{h}");
            }
        }
        let mut fbo = OpenGlFbo { fbo: fbo_id, w, h, internal_format: 0 };
        let mut flip: c_int = 1;
        // Never wait for the frame's display time here: this runs on GTK's main thread, which also
        // delivers the mouse, window changes (full screen, maximize) and the page's own updates.
        // Waiting (mpv's default, up to video-timing-offset per frame) held all of that up while a
        // video played. The frame is drawn at the display refresh it's due on instead.
        let mut block: c_int = 0;
        let mut params = [
            RenderParam { kind: ffi::RENDER_PARAM_OPENGL_FBO, data: &mut fbo as *mut _ as *mut c_void },
            RenderParam { kind: ffi::RENDER_PARAM_FLIP_Y, data: &mut flip as *mut _ as *mut c_void },
            RenderParam { kind: ffi::RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: &mut block as *mut _ as *mut c_void },
            RenderParam { kind: ffi::RENDER_PARAM_INVALID, data: std::ptr::null_mut() },
        ];
        // SAFETY: valid context and parameters; mpv draws into the bound framebuffer.
        unsafe {
            update(*ctx as ffi::RenderContext);
            render(*ctx as ffi::RenderContext, params.as_mut_ptr());
            if let Some(swap) = api.render_context_report_swap {
                swap(*ctx as ffi::RenderContext);
            }
        }
        true
    });
    if !drawn {
        // Nothing playing: black (the page covers it unless a video is open).
        if let (Some(color), Some(clear)) = (gl.clear_color, gl.clear) {
            unsafe {
                color(0.0, 0.0, 0.0, 1.0);
                clear(GL_COLOR_BUFFER_BIT);
            }
        }
    }
}

// MARK: OpenGL entry points (EGL on Wayland, GLX on X11; libglvnd provides both)

type GetProc = unsafe extern "C" fn(*const c_char) -> *mut c_void;
type CurrentContext = unsafe extern "C" fn() -> *mut c_void;

struct Loader {
    _egl: Option<Library>,
    _glx: Option<Library>,
    egl_get_proc: Option<GetProc>,
    egl_current: Option<CurrentContext>,
    glx_get_proc: Option<GetProc>,
    get_integerv: Option<unsafe extern "C" fn(u32, *mut c_int)>,
    clear_color: Option<unsafe extern "C" fn(f32, f32, f32, f32)>,
    clear: Option<unsafe extern "C" fn(u32)>,
}
// The library handles and plain function pointers are fine to share between threads.
unsafe impl Send for Loader {}
unsafe impl Sync for Loader {}

static LOADER: OnceLock<Loader> = OnceLock::new();

fn loader() -> &'static Loader {
    LOADER.get_or_init(|| unsafe {
        let egl = Library::new("libEGL.so.1").ok();
        let glx = Library::new("libGL.so.1").ok();
        let egl_get_proc = egl.as_ref().and_then(|l| l.get::<GetProc>(b"eglGetProcAddress\0").ok().map(|f| *f));
        let egl_current = egl.as_ref().and_then(|l| l.get::<CurrentContext>(b"eglGetCurrentContext\0").ok().map(|f| *f));
        let glx_get_proc = glx.as_ref().and_then(|l| l.get::<GetProc>(b"glXGetProcAddressARB\0").ok().map(|f| *f));
        let mut l = Loader { _egl: egl, _glx: glx, egl_get_proc, egl_current, glx_get_proc, get_integerv: None, clear_color: None, clear: None };
        let find = |l: &Loader, name: &[u8]| lookup(l, CStr::from_bytes_with_nul(name).unwrap().as_ptr());
        l.get_integerv = std::mem::transmute::<*mut c_void, Option<unsafe extern "C" fn(u32, *mut c_int)>>(find(&l, b"glGetIntegerv\0"));
        l.clear_color = std::mem::transmute::<*mut c_void, Option<unsafe extern "C" fn(f32, f32, f32, f32)>>(find(&l, b"glClearColor\0"));
        l.clear = std::mem::transmute::<*mut c_void, Option<unsafe extern "C" fn(u32)>>(find(&l, b"glClear\0"));
        l
    })
}

/// A GL function for the context GTK made current (EGL if that's what's current, else GLX).
unsafe fn lookup(l: &Loader, name: *const c_char) -> *mut c_void {
    let egl_active = l.egl_current.map(|f| !f().is_null()).unwrap_or(false);
    let first = if egl_active { l.egl_get_proc } else { l.glx_get_proc };
    let second = if egl_active { l.glx_get_proc } else { l.egl_get_proc };
    for f in [first, second].into_iter().flatten() {
        let p = f(name);
        if !p.is_null() {
            return p;
        }
    }
    std::ptr::null_mut()
}

unsafe extern "C" fn get_proc_address(_: *mut c_void, name: *const c_char) -> *mut c_void {
    lookup(loader(), name)
}

/// The Wayland wl_display or X11 Display behind GTK (null if neither).
fn native_display() -> (c_int, *mut c_void) {
    use glib::translate::ToGlibPtr;
    let Some(display) = gtk::gdk::Display::default() else { return (0, std::ptr::null_mut()) };
    let kind = display.type_().name().to_string();
    let raw: *mut gtk::gdk::ffi::GdkDisplay = display.to_glib_none().0;
    // SAFETY: GDK's own backend accessors, resolved from the already-loaded GDK library.
    unsafe {
        let this = libloading::os::unix::Library::this();
        // libva's Wayland backend crashes on a compositor without a GPU behind it (no render node,
        // e.g. a virtual machine): there mpv decodes with a copy instead of zero-copy.
        let has_render_node = std::fs::read_dir("/dev/dri").map(|d| d.flatten().any(|e| e.file_name().to_string_lossy().starts_with("renderD"))).unwrap_or(false);
        if kind.contains("Wayland") && !has_render_node {
            return (0, std::ptr::null_mut());
        }
        if kind.contains("Wayland") {
            if let Ok(f) = this.get::<unsafe extern "C" fn(*mut gtk::gdk::ffi::GdkDisplay) -> *mut c_void>(b"gdk_wayland_display_get_wl_display\0") {
                return (ffi::RENDER_PARAM_WL_DISPLAY, f(raw));
            }
        } else if kind.contains("X11") {
            if let Ok(f) = this.get::<unsafe extern "C" fn(*mut gtk::gdk::ffi::GdkDisplay) -> *mut c_void>(b"gdk_x11_display_get_xdisplay\0") {
                return (ffi::RENDER_PARAM_X11_DISPLAY, f(raw));
            }
        }
    }
    (0, std::ptr::null_mut())
}
