#!/usr/bin/env bash
# usage: run_harness.sh <file.h264> <worker|folded> <chromium-flag>
# Serves nothing itself: expects `python3 -m http.server 8765 --bind 127.0.0.1`
# running in this directory. Prints the page's <pre id="log"> block plus the
# count of Chromium ffmpeg_video_decoder warnings.
cd "$(dirname "$0")"
f=$1; mode=$2; flag=$3; tag="${f%.h264}_${mode}_${flag//[^a-z0-9]/}"
url="http://127.0.0.1:8765/wc_test.html?file=$f&codec=avc1.42E01F&mode=$mode"
timeout 90 chromium --headless=new --no-sandbox --enable-logging=stderr --v=0 "$flag" --dump-dom "$url" > "dump_$tag.txt" 2> "err_$tag.txt"
echo "== $f $mode $flag"
sed -n '/<pre id="log">/,/<\/pre>/p' "dump_$tag.txt" | sed 's/<[^>]*>//g'
echo "ffmpeg_video_decoder warnings: $(grep -c 'ffmpeg_video_decoder.cc' "err_$tag.txt")"
