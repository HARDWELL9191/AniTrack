//! Keeps the screen on while a video plays.
//!
//! Windows: mpv does this itself (its video window calls SetThreadExecutionState with
//! ES_DISPLAY_REQUIRED while playback runs and clears it on pause; mpv's `stop-screensaver`).
//!
//! Linux: mpv draws through its render API here (no mpv window), and that path ignores mpv's
//! screensaver control, so the desktop dimmed and blanked the screen mid-video. The app asks the
//! desktop itself, over the session bus, through every standard route it finds, and holds them
//! until playback pauses or stops:
//!   - xdg-desktop-portal Inhibit (idle): GNOME, KDE and most current desktops
//!   - org.freedesktop.ScreenSaver Inhibit: KDE, Xfce, Cinnamon, MATE, LXQt, hypridle…
//!   - org.gnome.SessionManager Inhibit (idle): GNOME, also without the portal
//! Holding more than one is harmless; each is released when the video stops.

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
            if held.is_empty() {
                return Err("No desktop service to keep the screen on was found.".into());
            }
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

/// Keep the screen on (a video is playing) or let it sleep (paused, stopped, music).
/// Windows: nothing to do, mpv's video window handles it.
#[tauri::command]
pub async fn keep_awake(on: bool) -> Result<Vec<String>, String> {
    #[cfg(target_os = "linux")]
    return linux::set(on).await;
    #[cfg(not(target_os = "linux"))]
    {
        let _ = on;
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
            let held = super::keep_awake(true).await.unwrap();
            println!("held: {held:?}");
            assert_eq!(held.len(), 3);
            let again = super::keep_awake(true).await.unwrap();
            assert_eq!(again.len(), 3);
            super::keep_awake(false).await.unwrap();
            super::keep_awake(false).await.unwrap();
            let log = log.lock().unwrap().clone();
            for l in &log { println!("{l}"); }
            assert_eq!(log.iter().filter(|l| l.contains("inhibit") && !l.contains("uninhibit")).count(), 3, "each route taken once");
            assert!(log.contains(&"saver uninhibit 42".to_string()) && log.contains(&"gnome uninhibit 7".to_string()) && log.contains(&"portal close".to_string()));
        });
    }
}
