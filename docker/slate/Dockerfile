# The maintenance slate: one still image, as a live HLS stream, forever.
#
# nginx serves this in place of every channel while the flag file exists (see the /hls/
# location in the rendered nginx.conf), so the displays show a deliberate "back shortly"
# rather than whatever the player shows for a dead stream while the producers reboot.
#
# It runs ALL THE TIME, not only during maintenance. A slate started on demand is one that
# has never been tested at the moment it is needed; this one is always warm, always
# checked by the watchdog, and the switch is a single file appearing.
#
# Built on the host from this context, like the watchdog, and for the same reason: no
# registry. The deploy stages the department's own slate.png over the neutral default.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

RUN apk add --no-cache ffmpeg

# Must match MediaMTX's hlsSegmentDuration. The clip is exactly one segment long and
# carries exactly one keyframe, so every loop is a segment boundary.
ARG SEGMENT_SECONDS=4
ARG FPS=30

COPY slate.png /opt/slate/slate.png
COPY slate.sh /usr/local/bin/slate.sh

# ENCODED ONCE, HERE, and never again. At runtime the loop is `-c copy`, which measured at
# 0.4% of one core: the relay has two vCPUs and this must cost it nothing.
#
#   High@4.0      - what the channels advertise (avc1.640028), and within what the
#                   Chair's older Apple TV decodes. 5.1 is what broke that one before.
#   1920x1080     - letterboxed, never stretched, whatever the PNG's shape.
#   one keyframe  - GOP = the clip, so the segmenter cuts every loop at 4s exactly.
#   silent AAC    - the channels carry two tracks; a slate with one is a different
#                   stream shape to the player, for no benefit.
#
# MP4, NOT TS. Looping an MPEG-TS input loses the keyframe flag after the first pass - the
# demuxer does not re-mark it after seeking back - and the segmenter, finding no keyframe,
# wrote one 30-second segment instead of seven 4-second ones. MP4 carries its keyframe
# index explicitly and survives the loop.
RUN ffmpeg -loglevel error -y \
      -loop 1 -framerate "$FPS" -t "$SEGMENT_SECONDS" -i /opt/slate/slate.png \
      -f lavfi -t "$SEGMENT_SECONDS" -i anullsrc=r=48000:cl=stereo \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,format=yuv420p" \
      -c:v libx264 -profile:v high -level:v 4.0 -tune stillimage -preset medium \
      -g "$((FPS * SEGMENT_SECONDS))" -keyint_min "$((FPS * SEGMENT_SECONDS))" -sc_threshold 0 \
      -b:v 400k -maxrate 600k -bufsize 1200k \
      -c:a aac -b:a 64k -ar 48000 -ac 2 -t "$SEGMENT_SECONDS" \
      -movflags +faststart /opt/slate/clip.mp4 \
 && chmod 0755 /usr/local/bin/slate.sh

ENV SEGMENT_SECONDS=$SEGMENT_SECONDS

# Unprivileged: it reads one file and writes a directory of segments.
RUN adduser -D -u 10002 slate
USER slate

ENTRYPOINT ["/usr/local/bin/slate.sh"]
