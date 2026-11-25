#!/usr/bin/env bash
# Short media files in every codec and container worth asking a browser
# about, for scripts/sites/media.mjs: 2 s, 320x240, a moving test pattern
# and a tone. Made once into build/sites/fixtures (ffmpeg from Homebrew).
set -uo pipefail
cd "$(dirname "$0")/../.."
out=build/sites/fixtures
mkdir -p "$out"
ff() { nice -n 10 ffmpeg -hide_banner -loglevel error -y -threads 2 "$@"; }
V=(-f lavfi -i testsrc2=size=320x240:rate=30:duration=2)
A=(-f lavfi -i sine=frequency=440:duration=2:sample_rate=48000)
make() {  # name, ffmpeg args…
  local name="$1"; shift
  [ -s "$out/$name" ] && return
  ff "$@" "$out/$name" 2>"$out/$name.err" && rm -f "$out/$name.err" || echo "could not make $name: $(head -c 300 "$out/$name.err")"
}
frag=(-movflags frag_keyframe+empty_moov+default_base_moof)

# Video (with sound where the container usually has it)
make h264-aac.mp4        "${V[@]}" "${A[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest
make h264-high10.mp4     "${V[@]}" -c:v libx264 -profile:v high10 -pix_fmt yuv420p10le
make h264-444.mp4        "${V[@]}" -c:v libx264 -profile:v high444 -pix_fmt yuv444p
make h264.mov            "${V[@]}" "${A[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest
make h264.mkv            "${V[@]}" "${A[@]}" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest
make h264-ac3.mp4        "${V[@]}" "${A[@]}" -c:v libx264 -pix_fmt yuv420p -c:a ac3 -shortest
make hevc-hvc1.mp4       "${V[@]}" "${A[@]}" -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -x265-params log-level=error -c:a aac -shortest
make hevc-hev1.mp4       "${V[@]}" -c:v libx265 -tag:v hev1 -pix_fmt yuv420p -x265-params log-level=error
make hevc-main10-hdr.mp4 "${V[@]}" -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p10le \
  -x265-params log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc
make av1.mp4             "${V[@]}" "${A[@]}" -c:v libsvtav1 -preset 12 -pix_fmt yuv420p -c:a libopus -shortest
make av1.webm            "${V[@]}" "${A[@]}" -c:v libsvtav1 -preset 12 -pix_fmt yuv420p -c:a libopus -shortest
make av1-10bit.mp4       "${V[@]}" -c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le
make vp9.webm            "${V[@]}" "${A[@]}" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a libopus -shortest
make vp9-10bit.webm      "${V[@]}" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -profile:v 2 -pix_fmt yuv420p10le
make vp9.mp4             "${V[@]}" -c:v libvpx-vp9 -deadline realtime -cpu-used 8
make vp8.webm            "${V[@]}" "${A[@]}" -c:v libvpx -deadline realtime -cpu-used 8 -c:a libopus -shortest
make prores.mov          "${V[@]}" -c:v prores -profile:v 0

# Sound alone
make aac-lc.m4a          "${A[@]}" -c:a aac
make he-aac.m4a          "${A[@]}" -c:a aac_at -profile:a 4 -b:a 48k
make mp3.mp3             "${A[@]}" -c:a libmp3lame
make opus.webm           "${A[@]}" -c:a libopus
make opus.ogg            "${A[@]}" -c:a libopus
make opus.mp4            "${A[@]}" -c:a libopus
make vorbis.ogg          "${A[@]}" -c:a vorbis -strict -2 -ac 2
make flac.flac           "${A[@]}" -c:a flac
make flac.mp4            "${A[@]}" -c:a flac -strict -2
make alac.m4a            "${A[@]}" -c:a alac
make ac3.ac3             "${A[@]}" -c:a ac3
make eac3.mp4            "${A[@]}" -c:a eac3
make pcm16.wav           "${A[@]}" -c:a pcm_s16le
make pcm-float.wav       "${A[@]}" -c:a pcm_f32le
make pcm.aiff            "${A[@]}" -c:a pcm_s16be

# Fragmented MP4 for Media Source Extensions (what YouTube, Netflix… use)
make mse-h264.mp4        "${V[@]}" -c:v libx264 -pix_fmt yuv420p -g 30 "${frag[@]}"
make mse-hevc.mp4        "${V[@]}" -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -g 30 -x265-params log-level=error "${frag[@]}"
make mse-av1.mp4         "${V[@]}" -c:v libsvtav1 -preset 12 -pix_fmt yuv420p -g 30 "${frag[@]}"
make mse-vp9.mp4         "${V[@]}" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -g 30 "${frag[@]}"
make mse-aac.mp4         "${A[@]}" -c:a aac "${frag[@]}"
make mse-opus.mp4        "${A[@]}" -c:a libopus "${frag[@]}"
make mse-ac3.mp4         "${A[@]}" -c:a ac3 -movflags frag_keyframe+empty_moov+default_base_moof+delay_moov

# HLS: MPEG-TS segments (H.264/AAC) and fMP4 segments (HEVC)
if [ ! -s "$out/hls-ts/index.m3u8" ]; then
  mkdir -p "$out/hls-ts"
  ff "${V[@]}" "${A[@]}" -c:v libx264 -pix_fmt yuv420p -g 30 -c:a aac -shortest \
    -f hls -hls_time 1 -hls_playlist_type vod "$out/hls-ts/index.m3u8"
fi
if [ ! -s "$out/hls-hevc/index.m3u8" ]; then
  mkdir -p "$out/hls-hevc"
  ff "${V[@]}" -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -g 30 -x265-params log-level=error \
    -f hls -hls_time 1 -hls_segment_type fmp4 -hls_playlist_type vod "$out/hls-hevc/index.m3u8"
fi
ls "$out" | wc -l | tr -d ' '
