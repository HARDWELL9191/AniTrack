# AniTrack

A personal AniList client for iPhone (iOS 26+, built against the iOS 27 SDK).

- **Home**: what you're watching, what's ready to watch, airing countdowns, one-tap **+1 episode**
- **Discover**: search (optionally within a category), category browsing with sorting, trending, this season, next season, all-time top
- **For You**: "Ask Hoshi" personal picks, one card at a time, filterable by category (Isekai, Romance, Ecchi…), and endless: more picks load as you reach the end
- **Home**: picked-for-you row, ready to watch, airing schedule, up next, trending this season
- **Match %**: every show gets a personal match next to its score (genres/tags instantly, refined by on-device AI; most AI work happens while charging)
- **Lists**: Watching / Planning / Completed / Paused / Dropped / Rewatching, with filter and sorting
- **Details**: synopsis, info, tags (spoilers hidden), related shows, fan recommendations, edit status / progress / score
- Syncs both ways with your AniList account

## How For You works

1. Builds a taste profile from your list: high scores pull toward a show's genres and tags, dropped and low scores push away.
2. Collects AniList fan recommendations from your ~30 favorite shows, weighted by how much you liked each one.
3. Explores your top tags and genres to find shows nobody linked yet.
4. **On-device AI re-rank:** Apple's Natural Language contextual embedding model turns each synopsis into a meaning vector on your iPhone and compares it to a "taste vector" made from your favorites. iOS runs this with hardware acceleration (on recent iPhones, the Neural Engine when iOS chooses it; apps can't force it).
5. **"Why would I like this?"** uses Apple's on-device Foundation Models (Apple Intelligence) to write a 2-sentence reason, only when you tap it.

Battery: embeddings are cached on disk (each show is processed once), picks are saved and only rebuilt when your list changes or after 3 days, the model is unloaded after each run, and nothing runs in the background.

---

## Setup (once, ~10 minutes)

### 1. Register an AniList API client

1. Go to <https://anilist.co/settings/developer> and click **Create New Client**.
2. Name: `AniTrack`. Redirect URL: **`anitrack://auth`**
3. Save, then copy the **Client ID** (a number). You'll enter it in the app.

### 2. Build the IPA on GitHub (no Mac needed)

1. Create a new repository on GitHub (public builds are free; private repos use your Actions minutes, and macOS minutes count extra).
2. Upload **everything in this folder**, including the hidden `.github` folder.
   Easiest: on the empty repo page choose *uploading an existing file* and drag the whole folder in, or use `git push`.
3. Open the **Actions** tab. The **Build IPA** workflow runs on every push to `main` (or click *Run workflow*).
4. When it's green (about 5–10 min), open the run and download **AniTrack-ipa**. It's a zip containing `AniTrack.ipa`.

If the build fails, download **build-log** from the failed run and send it to Claude to fix.

### 3. Install on your iPhone

The IPA is unsigned; a sideloading tool signs it with your Apple ID. With a free Apple ID the app works for **7 days**, then needs a refresh (the tools do this in one tap or automatically). Free accounts allow 3 sideloaded apps.

First, on the iPhone: **Settings → Privacy & Security → Developer Mode → On** (restart when asked).

**Option A – from your PC: [Sideloadly](https://sideloadly.io)**
1. Install Sideloadly (and iTunes / Apple Devices on Windows), connect the iPhone by cable.
2. Drag in `AniTrack.ipa`, enter your Apple ID, click **Start**.
3. On the iPhone: **Settings → General → VPN & Device Management → trust your developer certificate**.
4. Turn on Sideloadly's auto-refresh, or re-run it within 7 days.

**Option B – on the iPhone only: SideStore**
Install SideStore (the official SideStore guides, or SideInstaller for an on-device setup on iOS 27), then open `AniTrack.ipa` in SideStore. SideStore refreshes the app over Wi-Fi.

Only download these tools from their official sites; you're typing your Apple ID into them.

### 4. First launch

Enter your Client ID, tap **Log in with AniList**, approve, and you're in.
Or choose **Just browse with my username** for read-only mode (no editing).

For AI explanations, Apple Intelligence must be on: **Settings → Apple Intelligence & Siri**.

---

Unofficial; not affiliated with AniList.co. Data from the public AniList API.
