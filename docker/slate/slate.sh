#!/bin/sh
# Loop the pre-encoded slate clip into a live HLS window at $SLATE_DIR.
#
# The filenames are the ones players already hold: nginx rewrites /hls/<channel>/<file>
# to this directory, so a player polling main_stream.m3u8 for any channel is handed this
# playlist, and the segment names inside it resolve here too.
set -eu

OUT=${SLATE_DIR:-/slate}
WINDOW=${WINDOW_SEGMENTS:-7}
SEG=${SEGMENT_SECONDS:-4}

[ -d "$OUT" ] && [ -w "$OUT" ] || { echo "slate: $OUT is not a writable directory" >&2; exit 1; }

# Stale output from a previous run would be served as if live until ffmpeg overwrote it,
# and a player handed yesterday's playlist waits for segments that were deleted. Only our
# own files: this is a bind mount, and a glob this narrow cannot take anything else.
rm -f "$OUT"/*.m3u8 "$OUT"/*.m3u8.tmp "$OUT"/slate_seg*.ts "$OUT"/slate_seg*.ts.tmp

# EPOCH NUMBERING. MediaMTX restarts its media sequence at 0 whenever a publisher
# reconnects; this one starts at the current Unix time, ~1.79 billion. Switching a player
# onto the slate is therefore always a FORWARD jump, which players treat as having fallen
# behind the live edge - not a sequence regression, which they are entitled to reject.
#
# temp_file: write then rename, so nginx never serves a half-written playlist.
exec ffmpeg -hide_banner -loglevel warning -nostdin \
  -re -stream_loop -1 -i /opt/slate/clip.mp4 \
  -c copy \
  -f hls -hls_time "$SEG" -hls_list_size "$WINDOW" \
  -hls_flags delete_segments+omit_endlist+program_date_time+independent_segments+temp_file \
  -hls_start_number_source epoch \
  -hls_segment_filename "$OUT/slate_seg%d.ts" \
  -master_pl_name index.m3u8 \
  "$OUT/main_stream.m3u8"
