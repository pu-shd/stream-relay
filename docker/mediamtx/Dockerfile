# stream-relay MediaMTX image.
#
# Upstream plus one entrypoint. The `-ffmpeg` variant is REQUIRED: tiers >0 launch ffmpeg
# via MediaMTX's runOnAvailable hook, and the plain image has no ffmpeg binary.
#
# Pinned deliberately. runOnReady was renamed runOnAvailable in v1.19.3 (2026-07-23), and
# the generated config uses the new name, so rolling back below 1.19.3 would silently
# stop launching transcode hooks. `latest` is never used.
FROM bluenviron/mediamtx:1.19.3-ffmpeg

# Alpine-based with /bin/sh and busybox sed, so the entrypoint needs no extra packages.
COPY entrypoint.sh /usr/local/bin/relay-entrypoint.sh
RUN chmod +x /usr/local/bin/relay-entrypoint.sh

# The config repo's <dept>/ directory mounts here read-only, supplying
# mediamtx.yml.tmpl. The rendered config lands in /tmp, never in the image.
VOLUME ["/config"]

# SRT ingest (UDP - bypasses Front Door, hits the VM's public IP directly).
EXPOSE 8890/udp
# LL-HLS egress (behind Front Door).
EXPOSE 8888/tcp

# API (9997) and metrics (9998) bind to loopback per the generated config and are
# deliberately NOT exposed.

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD wget -qO- http://127.0.0.1:9997/v3/paths/list >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/relay-entrypoint.sh"]
