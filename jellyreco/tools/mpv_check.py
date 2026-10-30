"""Runs the libmpv check program on the test media and fails if anything doesn't play to the end,
a track is missing, or a decoder Jellyfin libraries need is missing from the libmpv build.

python -I mpv_check.py <mpv_check exe> <libmpv dll/so> <media dir> <report.json>
"""

import json
import os
import subprocess
import sys

EXE, DLL, MEDIA, REPORT = sys.argv[1:5]

# Decoders (video and audio) the build must have: everything common in Jellyfin libraries.
REQUIRED = [
    "h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4", "mpeg1video", "vc1", "wmv3", "prores", "dnxhd", "theora", "msmpeg4v3", "h263", "mjpeg",
    "aac", "ac3", "eac3", "truehd", "mlp", "dts", "flac", "opus", "vorbis", "mp3", "mp2", "alac", "pcm_s16le", "pcm_s24le", "wmav2", "aac_latm",
]
REQUIRED_DEMUXERS = ["matroska", "mov", "mpegts", "avi", "flv", "ogg", "asf", "mpeg", "dash", "hls"]

manifest = json.load(open(os.path.join(MEDIA, "manifest.json"), encoding="utf-8"))
files = [m["file"] for m in manifest["made"]]
run = subprocess.run([EXE, DLL, REPORT, *files], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1800)
if run.returncode != 0:
    print(f"::error::mpv_check failed ({run.returncode}): {run.stderr[-2000:]}")
    sys.exit(1)
report = json.load(open(REPORT, encoding="utf-8"))

problems = []
decoders = {d.get("codec") for d in (report.get("decoders") or [])} | {d.get("driver") for d in (report.get("decoders") or [])}
missing = [c for c in REQUIRED if c not in decoders]
if missing:
    problems.append(f"decoders missing from libmpv: {', '.join(missing)}")
demuxers = set(report.get("demuxers") or [])
missing_demux = [d for d in REQUIRED_DEMUXERS if not any(d == x or d in x.split(",") for x in demuxers)]
if missing_demux:
    problems.append(f"demuxers missing: {', '.join(missing_demux)}")

expected = {m["file"]: m for m in manifest["made"]}
lines = []
for r in report["files"]:
    m = expected[r["file"]]
    tracks = r.get("tracks") or []
    audio = [t for t in tracks if t.get("type") == "audio"]
    subs = [t for t in tracks if t.get("type") == "sub"]
    video = [t for t in tracks if t.get("type") == "video"]
    # Every check is reported, not just the first one that fails.
    fails = []
    if not r["ok"]:
        fails.append(str(r["error"]))
    if not video:
        fails.append("no video track")
    if len(audio) != m["audio"]:
        fails.append(f"{len(audio)} audio tracks, expected {m['audio']}")
    if len(subs) != m["subs"]:
        fails.append(f"{len(subs)} subtitle tracks, expected {m['subs']}")
    if not r.get("propertyEvents") or r.get("observedTracks") != len(tracks):
        fails.append(f"property events {r.get('propertyEvents')}, observed tracks {r.get('observedTracks')} of {len(tracks)}")
    if float(r.get("lastTimePos") or 0) < 3.0:
        fails.append(f"playback stopped at {r.get('lastTimePos')}s")
    status = "ok" if not fails else "FAILED: " + "; ".join(fails)
    if status != "ok":
        problems.append(f"{m['name']}: {status}")
    vcodec = (video[0].get("codec") if video else "?")
    acodecs = ",".join(t.get("codec", "?") for t in audio)
    scodecs = ",".join(t.get("codec", "?") for t in subs) or "-"
    lines.append(f"{m['name']:<24} {status:<10} video {vcodec}; audio {acodecs}; subs {scodecs}")

summary = [
    f"libmpv {report.get('mpv_version')} | FFmpeg {report.get('ffmpeg_version')} | client API {report.get('client_api')}",
    f"{len(decoders)} decoders, {len(demuxers)} demuxers; hwdec interop: {report.get('hwdec_interop')}",
    *lines,
    *[f"skipped (encoder not in this FFmpeg): {s['file']} {s.get('missing') or s.get('error', '')}" for s in manifest["skipped"]],
]
print("\n".join(summary))
print("::notice::" + "%0A".join(summary))
if problems:
    print("::error::" + "%0A".join(problems))
    sys.exit(1)
