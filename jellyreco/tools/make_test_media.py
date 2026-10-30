"""Makes short test videos covering the containers, codecs, audio and subtitle formats a Jellyfin
library typically has, each with several audio and subtitle tracks, for the libmpv playback check.
Formats the given FFmpeg can't encode are skipped (and listed).

python -I make_test_media.py <ffmpeg> <out dir>   ->  writes <out dir>/manifest.json
"""

import json
import os
import subprocess
import sys

FFMPEG, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)

encoders = subprocess.run([FFMPEG, "-hide_banner", "-encoders"], capture_output=True, text=True, encoding="utf-8", errors="replace").stdout


def has(enc):
    return any(line.split()[1:2] == [enc] for line in encoders.splitlines() if len(line.split()) > 1)


SRT = os.path.join(OUT, "subs.srt")
ASS = os.path.join(OUT, "subs.ass")
with open(SRT, "w", encoding="utf-8") as f:
    f.write("1\n00:00:00,200 --> 00:00:01,800\nHello from JellyReco\n\n2\n00:00:02,000 --> 00:00:03,500\nČšž ünïcödé 日本語\n")
with open(ASS, "w", encoding="utf-8") as f:
    f.write(
        "[Script Info]\nScriptType: v4.00+\nPlayResX: 1280\nPlayResY: 720\n\n"
        "[V4+ Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, "
        "ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        "Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,30,1\n\n"
        "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        "Dialogue: 0,0:00:00.20,0:00:03.00,Default,,0,0,0,,{\\an8\\c&H00FFFF&}Typeset {\\b1}sign{\\b0}\n"
    )

DUR = "4"
VIDEO_IN = ["-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate=24000/1001:duration={DUR}"]


def audio_in(layout="stereo", freq=440):
    return ["-f", "lavfi", "-i", f"sine=frequency={freq}:sample_rate=48000:duration={DUR},aformat=channel_layouts={layout}"]


# name, container, video encoder (+args), [(audio encoder, args, layout)], [subtitle (file, codec)], needs
CASES = [
    ("h264_aac_srt_ass.mkv", ["libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"], [("aac", [], "stereo"), ("ac3", [], "5.1")], [(SRT, "srt"), (ASS, "ass")]),
    ("hevc10_eac3_ass.mkv", ["libx265", "-preset", "ultrafast", "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error"], [("eac3", [], "5.1"), ("aac", [], "stereo")], [(ASS, "ass"), (SRT, "srt")]),
    ("av1_opus.mkv", ["libsvtav1", "-preset", "12"], [("libopus", [], "stereo"), ("libopus", [], "5.1")], [(SRT, "srt")]),
    ("av1_aom_opus.webm", ["libaom-av1", "-cpu-used", "8", "-row-mt", "1"], [("libopus", [], "stereo")], [(SRT, "webvtt")]),
    ("vp9_vorbis.webm", ["libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8"], [("libvorbis", [], "stereo")], [(SRT, "webvtt")]),
    ("vp8_vorbis.webm", ["libvpx", "-deadline", "realtime", "-cpu-used", "8"], [("libvorbis", [], "stereo")], []),
    ("h264_truehd_dts.mkv", ["libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"], [("truehd", ["-strict", "-2"], "5.1"), ("dca", ["-strict", "-2"], "5.1")], [(SRT, "srt")]),
    ("h264_flac_pcm.mkv", ["libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"], [("flac", [], "7.1"), ("pcm_s24le", [], "stereo")], [(ASS, "ass")]),
    ("h264_aac_movtext.mp4", ["libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-movflags", "+faststart"], [("aac", [], "stereo"), ("aac", [], "5.1")], [(SRT, "mov_text")]),
    ("hevc_ac3.mp4", ["libx265", "-preset", "ultrafast", "-tag:v", "hvc1", "-x265-params", "log-level=error"], [("ac3", [], "5.1")], []),
    ("mpeg2_ac3_mp2.ts", ["mpeg2video", "-b:v", "4M"], [("ac3", [], "5.1"), ("mp2", [], "stereo")], []),
    ("mpeg4_mp3.avi", ["mpeg4", "-q:v", "5"], [("libmp3lame", [], "stereo")], []),
    ("prores_pcm.mov", ["prores_ks", "-profile:v", "1"], [("pcm_s24le", [], "stereo")], []),
    ("dnxhr_pcm.mov", ["dnxhd", "-profile:v", "dnxhr_lb", "-pix_fmt", "yuv422p"], [("pcm_s16le", [], "stereo")], []),
    ("theora_vorbis.ogv", ["libtheora", "-q:v", "5"], [("libvorbis", [], "stereo")], []),
    ("h264_alac.m4v", ["libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"], [("alac", [], "stereo")], []),
    ("vc1_like_wmv.wmv", ["wmv2"], [("wmav2", [], "stereo")], []),
    ("flv_h264_aac.flv", ["libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"], [("aac", [], "stereo")], []),
]

made, skipped = [], []
for name, venc, audios, subs in CASES:
    needed = [venc[0]] + [a[0] for a in audios]
    missing = [e for e in needed if not has(e)]
    if missing:
        skipped.append({"file": name, "missing": missing})
        continue
    path = os.path.join(OUT, name)
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *VIDEO_IN]
    for i, (_, _, layout) in enumerate(audios):
        cmd += audio_in(layout, 300 + 120 * i)
    for sub, _ in subs:
        cmd += ["-i", sub]
    cmd += ["-map", "0:v"]
    for i in range(len(audios)):
        cmd += ["-map", f"{i + 1}:a"]
    for i in range(len(subs)):
        cmd += ["-map", f"{1 + len(audios) + i}:s"]
    cmd += ["-c:v", *venc]
    for i, (enc, args, _) in enumerate(audios):
        cmd += [f"-c:a:{i}", enc, *args]
    for i, (_, codec) in enumerate(subs):
        cmd += [f"-c:s:{i}", codec]
    langs = ["eng", "jpn", "slv", "ger"]
    for i in range(len(audios)):
        cmd += [f"-metadata:s:a:{i}", f"language={langs[i % 4]}"]
    for i in range(len(subs)):
        cmd += [f"-metadata:s:s:{i}", f"language={langs[(i + 1) % 4]}"]
    cmd += ["-t", DUR, path]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0 or not os.path.exists(path):
        skipped.append({"file": name, "error": (r.stderr or "")[-400:]})
        continue
    made.append({"file": path, "name": name, "audio": len(audios), "subs": len(subs)})

# A file with an external subtitle next to it is a Jellyfin thing (the app loads it with sub-add); covered in the app itself.
with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump({"made": made, "skipped": skipped}, f, indent=1)
print(json.dumps({"made": [m["name"] for m in made], "skipped": skipped}))
