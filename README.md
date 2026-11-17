# JellyReco

**A Jellyfin player for iPhone, Windows and Linux.** It plays every file directly on your device, looks and feels like Apple's own apps (Liquid Glass), and recommends what to watch next from your own library.

## Download

| Device | What to get |
|---|---|
| **iPhone** (iOS 26 or newer) | AltStore source, which gets updates automatically: `https://raw.githubusercontent.com/HARDWELL9191/AniTrack/altstore/source.json`<br>or `JellyReco.ipa` from [JellyReco (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-latest) |
| **Windows** (Intel / AMD) | `JellyReco-Setup-x64.exe` from [JellyReco PC (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-pc-latest) |
| **Windows on Arm** (Snapdragon) | `JellyReco-Setup-arm64.exe` from [JellyReco PC (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-pc-latest) |
| **Linux** (x86_64) | `JellyReco-x86_64.AppImage` from [JellyReco PC (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-pc-latest) |

You need your own [Jellyfin](https://jellyfin.org) server. JellyReco is a player for it, not a server.

---

## Install on iPhone

JellyReco isn't on the App Store, so it's installed by **sideloading**: a tool signs the app with your own Apple ID. A free Apple ID works fine. You need a Windows PC or a Mac once, for the first setup.

### Option A: AltStore (recommended, updates arrive automatically)

**1. Install AltStore Classic on your iPhone.** Follow AltStore's official guide for your computer:
[Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) ·
[Mac](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos).
In short, on Windows:
1. Install **iTunes** and **iCloud** from Apple's website (not the Microsoft Store versions).
2. Install **AltServer** and run it as administrator.
3. Connect your iPhone by cable and unlock it.
4. In iTunes, turn on **Wi-Fi sync** for the iPhone.
5. Click the AltServer icon in the taskbar → **Install AltStore** → your iPhone, then sign in with your Apple ID.
6. On the iPhone: **Settings → General → VPN & Device Management** → trust your Apple ID.

**2. Turn on Developer Mode:** **Settings → Privacy & Security → Developer Mode → On**, then restart when asked.

**3. Add the JellyReco source.** In AltStore, open the **Sources** tab, tap **+** and paste:
```
https://raw.githubusercontent.com/HARDWELL9191/AniTrack/altstore/source.json
```

**4. Install JellyReco.** Find JellyReco in the source (or under **Browse**) and tap **FREE**.

**Updates:** every new build shows up in AltStore under **My Apps** as an update. Tap **Update**.

**Good to know:**
- **7-day refresh:** with a free Apple ID, sideloaded apps expire after **7 days**. AltStore refreshes them in the background while AltServer is running on your computer on the same Wi-Fi. You can also do it by hand with **My Apps → Refresh All**. Set AltServer to start with your computer and you'll never notice.
- **3-app limit:** a free Apple ID can only have **3 sideloaded apps** at a time, and AltStore itself counts as one of them.

### Option B: install the IPA yourself

Download `JellyReco.ipa` from [JellyReco (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-latest) and install it with:
- **[Sideloadly](https://sideloadly.io)** on Windows or Mac, by cable. Then trust your Apple ID under **Settings → General → VPN & Device Management**.
- or **SideStore**, on the iPhone itself.

Turn on Developer Mode as in step 2 above. With this option you install updates yourself, by downloading the new IPA.

Only download these tools from their official sites, since you sign in with your Apple ID.

---

## Install on Windows

1. **Pick the right installer:** **Settings → System → About** shows your **System type**.
   - **x64-based processor:** use `JellyReco-Setup-x64.exe`.
   - **ARM-based processor:** use `JellyReco-Setup-arm64.exe`.
2. **Run it.** The installer isn't code-signed, so Windows may show *"Windows protected your PC"*. Click **More info → Run anyway**.
3. **Updating:** download the new installer and run it. It installs over the old version and keeps your sign-in and settings.

## Install on Linux

**With [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever)** (recommended): open `JellyReco-x86_64.AppImage` with Gear Lever. JellyReco is added to your app menu, and Gear Lever finds updates by itself, because the AppImage carries its own update information.

**Without it:**
```sh
chmod +x JellyReco-x86_64.AppImage
./JellyReco-x86_64.AppImage
```

---

## First launch

1. **Server address:** enter your Jellyfin server's address, e.g. `192.168.1.20:8096` or `jellyfin.example.com`, and tap **Connect**.
2. **Sign in:** with your username and password, or tap **Use Quick Connect** and approve the code from Jellyfin on a device where you're already signed in.
3. **Done:** your libraries, Continue Watching and Next Up are there.

Your phone or computer has to reach the server. If you use the server from outside your home over a VPN (WireGuard, Tailscale…), connect the VPN first.

---

## What it does

- **Plays everything on the device.** An mpv-based player for MKV, MP4, AVI, TS/M2TS, WebM…
  - **Video:** H.264, HEVC 10-bit, AV1, VP9 and more.
  - **Audio:** DTS, TrueHD, AC3/E-AC3 (Atmos), FLAC, Opus.
  - **Subtitles:** ASS/SSA with embedded fonts, PGS, VobSub, DVB, SRT, WebVTT.

  The server only converts a file as a last resort.
- **A player that feels like Apple's.**
  - **Everywhere:** skip intro, recap and credits (from your server or the open databases TheIntroDB, IntroDB and AniSkip), Up Next with *Play now*, previous/next episode, trickplay previews while scrubbing, chapters, audio and subtitle delay, playback speed.
  - **iPhone also:** Picture in Picture, AirPlay, Dolby Vision / HDR, two subtitles at once and Fit/Fill.
- **For You.** AI picks from your own library, ranked by what you finished, favourited, gave up on or marked *Not for me*. It also suggests titles you don't own yet (TMDB, with age ratings). Libraries named *Anime* / *Anime Movies* can use your AniList account instead.
- **Your whole library.** Home, Continue Watching, Next Up, My List, libraries, collections, search, Live TV, and item pages with seasons, cast and extras.
- **Synced through your server.** My List, *Not for me* and settings are stored on your Jellyfin account, so a new device picks them up when you sign in.
- **Server dashboard for admins.** Sessions, scheduled tasks, users and permissions, libraries, logs, plugins.

---

## For developers

Everything is built by GitHub Actions; nothing is built by hand.

| Branch | What's in it | Workflow |
|---|---|---|
| `jellyfin` | JellyReco for iPhone (SwiftUI) | **JellyReco iOS**: builds the IPA, publishes [JellyReco (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-latest) and updates the AltStore source (`altstore` branch) |
| `jellyreco` | JellyReco PC (Tauri + mpv) | **JellyReco PC**: builds Windows x64, Windows on Arm and Linux together and publishes [JellyReco PC (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-pc-latest) |
| `libmpv-build` | JellyReco's patches for the iPhone player engine (libmpv) | **libmpv build**: builds the engine and stores it on the `libmpv-binaries` branch |
| `main` | AniReco (side app) and this page | **Build IPA** |

Each build is version `1.0.<build number>`, so AltStore and Gear Lever see every new build as an update.

---

## AniReco (side app)

A personal **AniList** client for iPhone: your lists, airing countdowns, discovery, and AI-ranked "For You" picks with a personal match % for every show. It syncs both ways with your AniList account.

Setup, building and installation: see **[ANIRECO.md](ANIRECO.md)**.

---

Unofficial. Not affiliated with Jellyfin, AniList, TMDB or AltStore.
