#!/usr/bin/env bash
# usage: ffcheck.sh <files...> -- probe + full decode of remuxed fMP4 files
for f in "$@"; do
  echo "== $f"
  ffprobe -v error -show_entries stream=codec_name,profile,level,width,height,codec_tag_string -of compact=p=0 "$f"
  ffmpeg -v error -i "$f" -f null - 2>&1 | head -5
  echo "decoded frames: $(ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 "$f")"
done
