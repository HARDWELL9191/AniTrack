//! Keeps the screen on while a video plays.
//!
//! Windows: mpv does this itself (its video window calls SetThreadExecutionState with
//! ES_DISPLAY_REQUIRED while playback runs and clears it on pause; mpv's `stop-screensaver`).
//!
//! Linux: mpv draws through its render API here (no mpv window), and that path ignores mpv's
//! screensaver control, so the desktop dimmed and blanked the screen mid-video. The app asks for
//! it itself, every way there is, and holds them until playback pauses or stops:
//!   over the session bus (desktops with an idle service)
//!   - xdg-desktop-portal Inhibit (idle): GNOME, KDE and most current desktops
//!   - org.freedesktop.ScreenSaver Inhibit: KDE, Xfce, Cinnamon, MATE, LXQt, Budgie, hypridle,
//!     xscreensaver (6+)…
//!   - org.gnome.SessionManager Inhibit (idle): GNOME, also without the portal
//!   on the window itself (what mpv's own window does)
//!   - Wayland: the idle-inhibit protocol on the app window (sway, river, niri, labwc, wayfire,
//!     Hyprland… with swayidle and the like, which only listen to that)
//!   - X11: the screen saver extension's suspend (screen saver and DPMS) plus mpv's 10-second
//!     XResetScreenSaver heartbeat (plain window managers, xset/DPMS blanking)
//! Holding more than one is harmless; each is released when the video stops, and all of them go
//! away by themselves if the app quits or crashes (they belong to its connections).

#[cfg(target_os = "linux")]
mod linux {
    use std::collections::HashMap;
    use tauri::async_runtime::Mutex;
    use zbus::zvariant::{OwnedObjectPath, Value};
    use zbus::Connection;

    enum Held {
        Portal(OwnedObjectPath),
        ScreenSaver(&'static str, u32),
        Gnome(u32),
    }

    struct State {
        conn: Option<Connection>,
        held: Vec<Held>,
    }

    static STATE: Mutex<State> = Mutex::const_new(State { conn: None, held: Vec::new() });

    const REASON: &str = "Playing video";
    /// Inhibit flag "idle" (portal and GNOME session manager): the screen stays on, no blanking.
    const IDLE: u32 = 8;

    async fn take(conn: &Connection) -> Vec<Held> {
        let mut held = Vec::new();
        let options: HashMap<&str, Value> = HashMap::from([("reason", Value::from(REASON))]);
        match conn
            .call_method(Some("org.freedesktop.portal.Desktop"), "/org/freedesktop/portal/desktop", Some("org.freedesktop.portal.Inhibit"), "Inhibit", &("", IDLE, options))
            .await
        {
            Ok(reply) => match reply.body().deserialize::<OwnedObjectPath>() {
                Ok(handle) => held.push(Held::Portal(handle)),
                Err(e) => eprintln!("[awake] portal: {e}"),
            },
            Err(e) => eprintln!("[awake] portal: {e}"),
        }
        for path in ["/org/freedesktop/ScreenSaver", "/ScreenSaver"] {
            match conn.call_method(Some("org.freedesktop.ScreenSaver"), path, Some("org.freedesktop.ScreenSaver"), "Inhibit", &("JellyReco", REASON)).await {
                Ok(reply) => {
                    if let Ok(cookie) = reply.body().deserialize::<u32>() {
                        held.push(Held::ScreenSaver(path, cookie));
                        break;
                    }
                }
                Err(e) => eprintln!("[awake] screensaver {path}: {e}"),
            }
        }
        match conn
            .call_method(Some("org.gnome.SessionManager"), "/org/gnome/SessionManager", Some("org.gnome.SessionManager"), "Inhibit", &("JellyReco", 0u32, REASON, IDLE))
            .await
        {
            Ok(reply) => {
                if let Ok(cookie) = reply.body().deserialize::<u32>() {
                    held.push(Held::Gnome(cookie));
                }
            }
            Err(e) => eprintln!("[awake] gnome session: {e}"),
        }
        held
    }

    async fn release(conn: &Connection, held: Vec<Held>) {
        for h in held {
            let result = match &h {
                Held::Portal(handle) => conn.call_method(Some("org.freedesktop.portal.Desktop"), handle.as_str(), Some("org.freedesktop.portal.Request"), "Close", &()).await,
                Held::ScreenSaver(path, cookie) => conn.call_method(Some("org.freedesktop.ScreenSaver"), *path, Some("org.freedesktop.ScreenSaver"), "UnInhibit", &(*cookie,)).await,
                Held::Gnome(cookie) => conn.call_method(Some("org.gnome.SessionManager"), "/org/gnome/SessionManager", Some("org.gnome.SessionManager"), "Uninhibit", &(*cookie,)).await,
            };
            if let Err(e) = result {
                eprintln!("[awake] release: {e}");
            }
        }
    }

    /// On: hold the screen on (once). Off: let it sleep again. Returns which routes are held.
    pub async fn set(on: bool) -> Result<Vec<String>, String> {
        let mut st = STATE.lock().await;
        if on && !st.held.is_empty() {
            return Ok(names(&st.held));
        }
        if st.conn.is_none() {
            st.conn = Some(Connection::session().await.map_err(|e| format!("session bus: {e}"))?);
        }
        let conn = st.conn.clone().expect("connected above");
        if on {
            st.held = take(&conn).await;
            let held = names(&st.held);
            eprintln!("[awake] keeping the screen on via {held:?}");
            Ok(held)
        } else {
            let held = std::mem::take(&mut st.held);
            if !held.is_empty() {
                release(&conn, held).await;
                eprintln!("[awake] screen may sleep again");
            }
            Ok(Vec::new())
        }
    }

    fn names(held: &[Held]) -> Vec<String> {
        held.iter()
            .map(|h| match h {
                Held::Portal(_) => "portal".to_string(),
                Held::ScreenSaver(..) => "org.freedesktop.ScreenSaver".to_string(),
                Held::Gnome(_) => "org.gnome.SessionManager".to_string(),
            })
            .collect()
    }
}

#[cfg(target_os = "linux")]
mod window {
    //! The window-level routes. Run on GTK's main thread only (GDK's Wayland/X11 objects).
    use gtk::glib;
    use gtk::prelude::*;
    use std::cell::RefCell;
    use std::ffi::{c_char, c_int, c_void};
    use wayland_client::globals::{registry_queue_init, GlobalListContents};
    use wayland_client::protocol::{wl_registry, wl_surface::WlSurface};
    use wayland_client::{Connection, Dispatch, EventQueue, Proxy, QueueHandle};
    use wayland_protocols::wp::idle_inhibit::zv1::client::zwp_idle_inhibit_manager_v1::ZwpIdleInhibitManagerV1;
    use wayland_protocols::wp::idle_inhibit::zv1::client::zwp_idle_inhibitor_v1::ZwpIdleInhibitorV1;

    struct Wl;
    impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for Wl {
        fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
    }
    impl Dispatch<ZwpIdleInhibitManagerV1, ()> for Wl {
        fn event(_: &mut Self, _: &ZwpIdleInhibitManagerV1, _: <ZwpIdleInhibitManagerV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    }
    impl Dispatch<ZwpIdleInhibitorV1, ()> for Wl {
        fn event(_: &mut Self, _: &ZwpIdleInhibitorV1, _: <ZwpIdleInhibitorV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
    }

    struct Wayland {
        conn: Connection,
        queue: EventQueue<Wl>,
        manager: ZwpIdleInhibitManagerV1,
        inhibitor: Option<ZwpIdleInhibitorV1>,
    }

    type XDisplay = *mut c_void;
    struct X11 {
        _lib: libloading::Library,
        _xss: Option<libloading::Library>,
        display: XDisplay,
        reset: unsafe extern "C" fn(XDisplay) -> c_int,
        flush: unsafe extern "C" fn(XDisplay) -> c_int,
        suspend: Option<unsafe extern "C" fn(XDisplay, c_int)>,
        heartbeat: Option<glib::SourceId>,
        /// The X server counts suspends per client: only one at a time, so one release undoes it.
        held: bool,
    }

    enum Route {
        Unknown,
        None,
        Wayland(Wayland),
        X11(X11),
    }

    thread_local! {
        static ROUTE: RefCell<Route> = const { RefCell::new(Route::Unknown) };
    }

    /// GTK's own Wayland connection and the app window's surface, with the compositor's
    /// idle-inhibit manager (none: the compositor doesn't offer the protocol).
    fn wayland(gtk_window: &gtk::Window) -> Result<Option<Wayland>, String> {
        use glib::translate::ToGlibPtr;
        let gdk_window = gtk_window.window().ok_or("window not shown")?;
        let display = gdk_window.display();
        // SAFETY: GDK's Wayland accessors (resolved from the loaded GDK); the display and surface
        // belong to GTK and live as long as the window/app.
        unsafe {
            let this = libloading::os::unix::Library::this();
            let get_display = this
                .get::<unsafe extern "C" fn(*mut gtk::gdk::ffi::GdkDisplay) -> *mut c_void>(b"gdk_wayland_display_get_wl_display\0")
                .map_err(|e| e.to_string())?;
            let get_surface = this
                .get::<unsafe extern "C" fn(*mut gtk::gdk::ffi::GdkWindow) -> *mut c_void>(b"gdk_wayland_window_get_wl_surface\0")
                .map_err(|e| e.to_string())?;
            let wl_display = get_display(display.to_glib_none().0);
            let wl_surface = get_surface(gdk_window.to_glib_none().0);
            if wl_display.is_null() || wl_surface.is_null() {
                return Err("no Wayland display/surface".into());
            }
            let conn = Connection::from_backend(wayland_backend::client::Backend::from_foreign_display(wl_display.cast()));
            let (globals, queue) = registry_queue_init::<Wl>(&conn).map_err(|e| e.to_string())?;
            let Ok(manager) = globals.bind::<ZwpIdleInhibitManagerV1, _, _>(&queue.handle(), 1..=1, ()) else {
                return Ok(None);
            };
            let _ = wl_surface; // checked above; taken again when inhibiting (it can change on remap)
            Ok(Some(Wayland { conn, queue, manager, inhibitor: None }))
        }
    }

    fn surface(conn: &Connection, gtk_window: &gtk::Window) -> Option<WlSurface> {
        use glib::translate::ToGlibPtr;
        let gdk_window = gtk_window.window()?;
        // SAFETY: as above.
        unsafe {
            let this = libloading::os::unix::Library::this();
            let get_surface = this.get::<unsafe extern "C" fn(*mut gtk::gdk::ffi::GdkWindow) -> *mut c_void>(b"gdk_wayland_window_get_wl_surface\0").ok()?;
            let ptr = get_surface(gdk_window.to_glib_none().0);
            if ptr.is_null() {
                return None;
            }
            let id = wayland_backend::client::ObjectId::from_ptr(WlSurface::interface(), ptr.cast()).ok()?;
            WlSurface::from_id(conn, id).ok()
        }
    }

    /// libX11 (+ libXss for the screen saver extension), on a connection of our own.
    fn x11() -> Result<X11, String> {
        // SAFETY: standard Xlib entry points with their documented signatures.
        unsafe {
            let lib = libloading::Library::new("libX11.so.6").map_err(|e| e.to_string())?;
            let open = *lib.get::<unsafe extern "C" fn(*const c_char) -> XDisplay>(b"XOpenDisplay\0").map_err(|e| e.to_string())?;
            let reset = *lib.get::<unsafe extern "C" fn(XDisplay) -> c_int>(b"XResetScreenSaver\0").map_err(|e| e.to_string())?;
            let flush = *lib.get::<unsafe extern "C" fn(XDisplay) -> c_int>(b"XFlush\0").map_err(|e| e.to_string())?;
            let display = open(std::ptr::null());
            if display.is_null() {
                return Err("XOpenDisplay failed".into());
            }
            let xss = libloading::Library::new("libXss.so.1").ok();
            let suspend = xss.as_ref().and_then(|l| l.get::<unsafe extern "C" fn(XDisplay, c_int)>(b"XScreenSaverSuspend\0").ok().map(|f| *f));
            Ok(X11 { _lib: lib, _xss: xss, display, reset, flush, suspend, heartbeat: None, held: false })
        }
    }

    fn pick(gtk_window: &gtk::Window) -> Route {
        let kind = gtk_window.display().type_().name().to_string();
        if kind.contains("Wayland") {
            return match wayland(gtk_window) {
                Ok(Some(w)) => Route::Wayland(w),
                Ok(None) => {
                    eprintln!("[awake] this compositor has no idle-inhibit protocol");
                    Route::None
                }
                Err(e) => {
                    eprintln!("[awake] wayland: {e}");
                    Route::None
                }
            };
        }
        if kind.contains("X11") {
            return match x11() {
                Ok(x) => Route::X11(x),
                Err(e) => {
                    eprintln!("[awake] x11: {e}");
                    Route::None
                }
            };
        }
        Route::None
    }

    /// On/off on the window. Returns the route's name when it's held.
    pub fn set(gtk_window: &gtk::Window, on: bool) -> Option<&'static str> {
        ROUTE.with(|route| {
            let mut route = route.borrow_mut();
            if matches!(*route, Route::Unknown) {
                if !on {
                    return None;
                }
                *route = pick(gtk_window);
            }
            match &mut *route {
                Route::Wayland(w) => {
                    let _ = w.queue.dispatch_pending(&mut Wl);
                    if on && w.inhibitor.is_none() {
                        let surface = surface(&w.conn, gtk_window)?;
                        w.inhibitor = Some(w.manager.create_inhibitor(&surface, &w.queue.handle(), ()));
                    } else if !on {
                        if let Some(i) = w.inhibitor.take() {
                            i.destroy();
                        }
                    }
                    let _ = w.conn.flush();
                    w.inhibitor.as_ref().map(|_| "wayland idle-inhibit")
                }
                Route::X11(x) => {
                    // SAFETY: our own Display connection, used on this thread only.
                    unsafe {
                        if on != x.held {
                            if let Some(suspend) = x.suspend {
                                suspend(x.display, on as c_int);
                            }
                            x.held = on;
                        }
                        if on {
                            (x.reset)(x.display);
                            if x.heartbeat.is_none() {
                                let (display, reset, flush) = (x.display as usize, x.reset, x.flush);
                                x.heartbeat = Some(glib::timeout_add_seconds_local(10, move || {
                                    reset(display as XDisplay);
                                    flush(display as XDisplay);
                                    glib::ControlFlow::Continue
                                }));
                            }
                        } else if let Some(id) = x.heartbeat.take() {
                            id.remove();
                        }
                        (x.flush)(x.display);
                    }
                    on.then_some("x11 screensaver suspend")
                }
                _ => None,
            }
        })
    }
}

/// Keep the screen on (a video is playing) or let it sleep (paused, stopped, music).
/// Windows: nothing to do, mpv's video window handles it.
#[tauri::command]
pub async fn keep_awake(app: tauri::AppHandle, on: bool) -> Result<Vec<String>, String> {
    #[cfg(target_os = "linux")]
    {
        use gtk::prelude::Cast;
        use tauri::Manager;
        let (tx, rx) = std::sync::mpsc::channel();
        if let Some(window) = app.get_webview_window("main") {
            let w = window.clone();
            let _ = window.run_on_main_thread(move || {
                let held = w.gtk_window().ok().and_then(|gtk_window| window::set(gtk_window.upcast_ref::<gtk::Window>(), on));
                let _ = tx.send(held);
            });
        } else {
            let _ = tx.send(None);
        }
        let mut held = linux::set(on).await.unwrap_or_else(|e| {
            eprintln!("[awake] session bus: {e}");
            Vec::new()
        });
        let on_window = tauri::async_runtime::spawn_blocking(move || rx.recv_timeout(std::time::Duration::from_secs(3)).ok().flatten()).await.ok().flatten();
        if let Some(name) = on_window {
            eprintln!("[awake] window: {name}");
            held.push(name.to_string());
        }
        if on && held.is_empty() {
            return Err("Nothing on this desktop to keep the screen on was found.".into());
        }
        Ok(held)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (app, on);
        Ok(Vec::new())
    }
}

#[cfg(all(test, target_os = "linux"))]
mod local_bus_test {
    use std::sync::{Arc, Mutex};
    use zbus::zvariant::{OwnedObjectPath, Value};
    use std::collections::HashMap;

    type Log = Arc<Mutex<Vec<String>>>;
    struct Saver(Log);
    #[zbus::interface(name = "org.freedesktop.ScreenSaver")]
    impl Saver {
        fn inhibit(&self, app: String, reason: String) -> u32 { self.0.lock().unwrap().push(format!("saver inhibit {app} {reason}")); 42 }
        fn un_inhibit(&self, cookie: u32) { self.0.lock().unwrap().push(format!("saver uninhibit {cookie}")); }
    }
    struct Portal(Log);
    #[zbus::interface(name = "org.freedesktop.portal.Inhibit")]
    impl Portal {
        fn inhibit(&self, window: String, flags: u32, options: HashMap<String, Value<'_>>) -> OwnedObjectPath {
            let reason = options.get("reason").map(|v| v.to_string()).unwrap_or_default();
            self.0.lock().unwrap().push(format!("portal inhibit '{window}' flags={flags} reason={reason}"));
            OwnedObjectPath::try_from("/org/freedesktop/portal/desktop/request/1_1/t").unwrap()
        }
    }
    struct Request(Log);
    #[zbus::interface(name = "org.freedesktop.portal.Request")]
    impl Request {
        fn close(&self) { self.0.lock().unwrap().push("portal close".into()); }
    }
    struct Gnome(Log);
    #[zbus::interface(name = "org.gnome.SessionManager")]
    impl Gnome {
        fn inhibit(&self, app: String, xid: u32, reason: String, flags: u32) -> u32 { self.0.lock().unwrap().push(format!("gnome inhibit {app} {xid} {reason} {flags}")); 7 }
        fn uninhibit(&self, cookie: u32) { self.0.lock().unwrap().push(format!("gnome uninhibit {cookie}")); }
    }

    #[test]
    #[ignore]
    fn holds_and_releases_on_a_session_bus() {
        tauri::async_runtime::block_on(async {
            let log: Log = Default::default();
            let _a = zbus::connection::Builder::session().unwrap().name("org.freedesktop.ScreenSaver").unwrap()
                .serve_at("/org/freedesktop/ScreenSaver", Saver(log.clone())).unwrap().build().await.unwrap();
            let _b = zbus::connection::Builder::session().unwrap().name("org.freedesktop.portal.Desktop").unwrap()
                .serve_at("/org/freedesktop/portal/desktop", Portal(log.clone())).unwrap()
                .serve_at("/org/freedesktop/portal/desktop/request/1_1/t", Request(log.clone())).unwrap().build().await.unwrap();
            let _c = zbus::connection::Builder::session().unwrap().name("org.gnome.SessionManager").unwrap()
                .serve_at("/org/gnome/SessionManager", Gnome(log.clone())).unwrap().build().await.unwrap();
            let held = super::linux::set(true).await.unwrap();
            println!("held: {held:?}");
            assert_eq!(held.len(), 3);
            let again = super::linux::set(true).await.unwrap();
            assert_eq!(again.len(), 3);
            super::linux::set(false).await.unwrap();
            super::linux::set(false).await.unwrap();
            let log = log.lock().unwrap().clone();
            for l in &log { println!("{l}"); }
            assert_eq!(log.iter().filter(|l| l.contains("inhibit") && !l.contains("uninhibit")).count(), 3, "each route taken once");
            assert!(log.contains(&"saver uninhibit 42".to_string()) && log.contains(&"gnome uninhibit 7".to_string()) && log.contains(&"portal close".to_string()));
        });
    }
}

#[cfg(all(test, target_os = "linux"))]
mod local_window_test {
    use gtk::prelude::*;

    fn pump() {
        for _ in 0..40 {
            while gtk::events_pending() {
                gtk::main_iteration();
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    /// Run under a real display: weston/sway (GDK_BACKEND=wayland) or Xvfb (GDK_BACKEND=x11).
    #[test]
    #[ignore]
    fn holds_and_releases_on_the_window() {
        gtk::init().unwrap();
        let win = gtk::Window::new(gtk::WindowType::Toplevel);
        win.set_default_size(320, 200);
        win.show_all();
        pump();
        let held = super::window::set(&win, true);
        println!("held: {held:?}");
        assert!(held.is_some());
        assert_eq!(super::window::set(&win, true), held, "holding twice is the same hold");
        pump();
        // Optional: ask the compositor/X server what it thinks (e.g. AWAKE_CHECK="swaymsg -t get_tree").
        let check = |label: &str| {
            if let Ok(cmd) = std::env::var("AWAKE_CHECK") {
                let out = std::process::Command::new("sh").arg("-c").arg(&cmd).output().unwrap();
                println!("{label}: {}", String::from_utf8_lossy(&out.stdout).trim());
            }
        };
        check("while held");
        assert_eq!(super::window::set(&win, false), None);
        pump();
        check("after release");
        assert!(super::window::set(&win, true).is_some(), "can hold again");
        assert_eq!(super::window::set(&win, false), None);
        pump();
    }
}
