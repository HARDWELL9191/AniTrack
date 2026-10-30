#!/bin/bash
# Generates 6-second test files covering the hard formats (needs ffmpeg).
set -uo pipefail
out="$1"; mkdir -p "$out"; cd "$out"
# Every input has its own fixed length (duration=6), so no encode can run forever.
V="-f lavfi -i testsrc2=size=640x360:rate=24:duration=6"
A="-f lavfi -i sine=frequency=440:sample_rate=48000:duration=6"
A6="-f lavfi -i sine=frequency=440:sample_rate=48000:duration=6,aformat=channel_layouts=5.1"
printf '1\n00:00:00,500 --> 00:00:05,000\nHello from JellyReco\n' > subs.srt
ffmpeg -nostdin -loglevel error -y -i subs.srt subs.ass
make() { name="$1"; shift; if timeout 120 ffmpeg -nostdin -loglevel error -y "$@" -shortest "$name"; then echo "made $name"; else echo "SKIPPED $name (encoder missing)"; rm -f "$name"; fi; }

make hevc10_truehd_ass.mkv $V $A6 -i subs.ass -map 0 -map 1 -map 2 -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params log-level=error -c:a truehd -strict -2 -c:s ass
make av1_opus_srt.mkv $V $A -i subs.srt -map 0 -map 1 -map 2 -c:v libsvtav1 -preset 12 -c:a libopus -c:s srt
make h264_dts_vobsub.mkv $V $A6 -i subs.srt -map 0 -map 1 -map 2 -c:v libx264 -preset ultrafast -c:a dca -strict -2 -c:s dvdsub
make hevc_eac3_movtext.mp4 $V $A6 -i subs.srt -map 0 -map 1 -map 2 -c:v libx265 -preset ultrafast -x265-params log-level=error -tag:v hvc1 -c:a eac3 -c:s mov_text
make vp9_flac_webvtt.mkv $V $A -i subs.srt -map 0 -map 1 -map 2 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a flac -c:s webvtt
make h264_ac3_aac_two_audio.mkv $V $A6 $A -map 0 -map 1 -map 2 -c:v libx264 -preset ultrafast -c:a:0 ac3 -c:a:1 aac
make mpeg4_mp3.avi $V $A -c:v mpeg4 -c:a libmp3lame
make wmv2_wma.wmv $V $A -c:v wmv2 -c:a wmav2
make mpeg2_ac3.ts $V $A6 -c:v mpeg2video -c:a ac3
make vp8_vorbis.webm $V $A -c:v libvpx -deadline realtime -c:a libvorbis
make h264_alac.mov $V $A -c:v libx264 -preset ultrafast -c:a alac
make hevc_dts_m2ts.m2ts $V $A6 -c:v libx265 -preset ultrafast -x265-params log-level=error -c:a dca -strict -2 -f mpegts
ls -la
