#!/usr/bin/env python3
"""Builds the AltStore source (source.json) for JellyReco from the app that was just built.

Usage: make_source.py <JellyReco.app> <JellyReco.ipa> <download-url> <raw-base-url> <notes> <out-dir>

Version, build number, minimum iOS and the privacy permissions are read from the built
app's Info.plist, so the source always matches the IPA exactly (AltStore refuses to
install an app whose permissions don't match what the source lists).
"""
import json
import os
import plistlib
import sys
from datetime import datetime, timezone

app, ipa, download_url, raw_base, notes, out_dir = sys.argv[1:7]

with open(os.path.join(app, "Info.plist"), "rb") as f:
    info = plistlib.load(f)

bundle_id = info["CFBundleIdentifier"]
version = info["CFBundleShortVersionString"]
build = info["CFBundleVersion"]
privacy = {k: v for k, v in sorted(info.items()) if k.endswith("UsageDescription")}

source = {
    "name": "JellyReco",
    "subtitle": "A Jellyfin player for iPhone with AI picks from your own library.",
    "description": "Official source for JellyReco. Add it in AltStore to install JellyReco and get every new build as an update.",
    "iconURL": f"{raw_base}/icon.png",
    "website": "https://github.com/HARDWELL9191/anitrack/tree/jellyfin",
    "tintColor": "#3D99FF",
    "nsfw": False,
    "featuredApps": [bundle_id],
    "apps": [
        {
            "name": "JellyReco",
            "bundleIdentifier": bundle_id,
            "developerName": "Tim",
            "subtitle": "Jellyfin player with AI recommendations.",
            "localizedDescription": (
                "A Jellyfin player for iPhone with a Liquid Glass look.\n\n"
                "• Plays every file directly on the phone (mpv engine), with server conversion only as a last resort\n"
                "• Picture in Picture, AirPlay, HDR, two subtitles at once, skip intro/credits, trickplay\n"
                "• For You: AI picks from your own library, explained by Apple Intelligence\n"
                "• My List and Not for me are saved on your Jellyfin server, not the phone\n"
                "• Server dashboard for administrators\n\n"
                "Requires your own Jellyfin server. iOS 26 or later."
            ),
            "iconURL": f"{raw_base}/icon.png",
            "tintColor": "#3D99FF",
            "category": "entertainment",
            "screenshots": [],
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "localizedDescription": notes,
                    "downloadURL": download_url,
                    "size": os.path.getsize(ipa),
                    "minOSVersion": info.get("MinimumOSVersion", "26.0"),
                }
            ],
            "appPermissions": {
                # Unsigned build: no entitlements beyond the ones AltStore adds itself when signing.
                "entitlements": [],
                "privacy": privacy,
            },
        }
    ],
    "news": [],
}

os.makedirs(out_dir, exist_ok=True)
with open(os.path.join(out_dir, "source.json"), "w") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(json.dumps(source["apps"][0]["versions"][0], indent=2))
print("privacy:", list(privacy))
