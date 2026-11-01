# JellyReco

**A Jellyfin player for iPhone, Windows and Linux** that plays every file directly, looks like Apple's own apps (Liquid Glass), and recommends what to watch next from your own library.

| | Download |
|---|---|
| **iPhone** (iOS 26+) | AltStore source: `https://raw.githubusercontent.com/HARDWELL9191/AniTrack/altstore/source.json` · or the IPA from [JellyReco (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-latest) |
| **Windows** (ARM64, e.g. Snapdragon) | `JellyReco-Setup-arm64.exe` from [JellyReco PC (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-pc-latest) |
| **Linux** (x86_64) | `JellyReco-x86_64.AppImage` from [JellyReco PC (latest build)](https://github.com/HARDWELL9191/AniTrack/releases/tag/jellyreco-pc-latest) |

## What it does

- **Plays everything on the device:** mpv-based player for MKV, MP4, AVI, TS/M2TS, WebM…; H.264, HEVC 10-bit, AV1, VP9 and more; DTS, TrueHD, AC3/E-AC3 (Atmos), FLAC, Opus; ASS/SSA with embedded fonts, PGS, VobSub, DVB, SRT, WebVTT. Server transcoding only as a last resort.
- **A player that feels like Apple's:** skip intro and credits, next-episode countdown, previous/next episode, trickplay previews, chapters, audio and subtitle sync, playback speed. On iPhone also Picture in Picture, AirPlay, Dolby Vision / HDR, two subtitles at once and fit/fill.
- **For You:** AI picks from your own library, ranked by what you finished, favourited, gave up on or marked *Not for me*, plus titles you don't own yet (TMDB) with age ratings.
- **Your whole library:** Home, Continue Watching, Next Up, My List, libraries, collections, search, Live TV, item pages with seasons, cast and extras.
- **Synced through your server:** My List, Not for me and settings are stored on your Jellyfin account, so a new device picks them up when you sign in.
- **Server dashboard for admins:** sessions, scheduled tasks, users and permissions, libraries, logs, plugins.

## Branches

| Branch | What's in it | Workflow |
|---|---|---|
| `jellyfin` | JellyReco for iPhone | **JellyReco iOS**: builds the IPA, publishes it and updates the AltStore source (`altstore` branch) on every push |
| `jellyreco` | JellyReco PC (Tauri + mpv) | **JellyReco PC**: builds Windows and Linux together and publishes both |
| `main` | AniReco (side app) | **Build IPA** |

Each iPhone build is version `1.0.<build number>`, so AltStore offers it as an update automatically.

---

## AniReco (side app)

A personal **AniList** client for iPhone: your lists, airing countdowns, discovery, and AI-ranked "For You" picks with a personal match % for every show. It syncs both ways with your AniList account.

Setup, building and installation: see **[ANIRECO.md](ANIRECO.md)**.

---

Unofficial; not affiliated with Jellyfin, AniList or TMDB.
