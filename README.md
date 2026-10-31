# JellyReco

A Jellyfin player for iPhone (iOS 26+, built against the iOS 27 SDK) with the same Liquid Glass look as AniReco, a player that plays every file directly on the phone, and AI recommendations from your own library.

## What's in it

- **Player (mpv via MPVUI 0.8.0):** direct play of MKV, MP4/MOV, AVI, WMV, TS/M2TS, WebM, OGG…; H.264, HEVC 10-bit, AV1 (dav1d), VP8/9, MPEG-2/4, VC-1, ProRes; DTS, TrueHD, AC3/E-AC3 (Atmos passthrough), FLAC, Opus, ALAC, WMA; ASS/SSA with embedded fonts, PGS, VobSub, DVB, SRT, WebVTT.
  - Picture in Picture, AirPlay, Dolby Vision / HDR10 on the native output; a libplacebo Metal renderer for anything the native layer can't show (switches by itself).
  - Server conversion only as a last resort (switch in Settings → Video player).
  - Audio/subtitle switching, **two subtitles at once**, audio and subtitle sync, subtitle style, playback speed (0.25–4×), hold for 2×, chapters with thumbnails, trickplay previews while scrubbing, skip intro/recap/credits (media segments), next-episode countdown, "Still watching?", fill/fit, rotation lock, control lock, lock-screen controls, playback info.
  - Gestures: brightness / volume / speed / audio or subtitle sync on either side, swipe to scrub, double-tap to jump, pinch to fill.
- **Library:** Home (Continue Watching, Next Up, Picked for you, My List, Recently added per library), libraries in grid or list, sorting, filters (watched, favourites, genres, years, ratings, tags), A–Z, random, collections, favourites, search (movies, shows, episodes, collections, people, genres), Live TV.
- **Item pages:** play/resume/from the beginning, versions, audio and subtitle choice before playing, seasons & episodes, chapters, cast & crew, extras, trailers, similar titles, media info, mark watched, favourite, My List, Not for me, refresh metadata (admins).
- **For You:** pick a library (your library names; default Anime; or All; anything called "placeholder", "playlist" or "playlists" is never offered), then a genre. The AI ranks unwatched titles from that library using what you finished, favourited, are watching, gave up on or marked Not for me, Jellyfin's similar-items data and Apple's on-device language model. "Why would I like this?" is written by Apple Intelligence.
- **Saved on your server, not the phone:** My List (plan to watch), Not for me (Jellyfin's thumbs-down) and all JellyReco settings sync to your Jellyfin account, so a new iPhone picks everything up when you sign in.
- **Server dashboard (admins):** active sessions (direct play vs transcoding, reasons, stop/pause/message), scheduled tasks (run, stop, triggers), users (create, delete, every permission, library access, parental control, passwords), devices, API keys, server logs, activity log, libraries (scan), plugins, restart/shutdown, and a **Playback test** that plays every file's audio and subtitle tracks on your iPhone and lists anything that fails.
- Multiple servers and users, Quick Connect (sign in and approve), Face ID lock.

## Build

The **Build JellyReco** workflow runs on every push to the `jellyfin` branch:

- **build** produces `JellyReco-ipa` (unsigned; sideload with AltStore like AniReco).
- **formats** generates test files in the hard formats and plays every audio and subtitle track with the exact libmpv build the app ships; see the `format-test` log.

**AltStore source:** every build also updates `source.json` on the `altstore` branch. Add this source in AltStore and new builds show up as updates (the version is `1.0.<run number>`, so each build is newer than the last):

`https://raw.githubusercontent.com/HARDWELL9191/anitrack/altstore/source.json`

Add `custom-icon.png` to the repo root to use your own icon.
