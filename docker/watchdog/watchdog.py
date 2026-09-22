#!/usr/bin/env python3
"""Relay watchdog: publisher liveness, viewer telemetry, certificate expiry.

Reports. Never restarts anything, never changes configuration.

WHY IT IS A CONTAINER AND NOT A HOST SCRIPT
page-stream's equivalent runs under launchd because its host is a Mac with no
config-management path. Here docker-compose.yml is generated from relay.yml and
drift-checked, so a compose service is reviewable, versioned, and deployed by the pipeline
that already exists. It keeps the dead-man's property either way: if the VM is off, the
pings stop and Healthchecks.io raises the alarm - which is the one thing a scheduled
workflow can never report, because it would simply queue against an offline runner.

WHERE THE NUMBERS COME FROM

  Publishers   Prometheus metrics on MediaMTX, NOT its control API. The `metrics`
               permission is read-only; `api` would let anything on this network rewrite
               the relay's configuration, and nginx - which is internet-facing - is on
               this network.

  Viewers      The nginx access log, and nothing else. MediaMTX cannot see viewers at all:
               nginx serves its hlsDirectory as static files, so `paths_readers` is
               permanently 0 and hlsmuxers reports outboundBytes 0 on a path an Apple TV
               is actively playing. Verified on the live relay, not assumed.

  Certificate  the TLS handshake with nginx - what is actually SERVED, which is not
               the same as what is on disk after a renewal nginx has not reloaded.

THREE SEVERITIES, and the distinction is the whole point:

  problem  -> /fail. An expected publisher is absent or has stopped advancing; nginx is
              not serving; the certificate expires within cert_days_fail.
  warn     -> rides the SUCCESS ping body. Errored frames over threshold, cert nearing
              expiry. Being degraded is not being broken, and a warning that flips the
              check to down makes an outage and a busy afternoon indistinguishable -
              after which everyone ignores both.
  fault    -> /fail, but says WATCHDOG PROBLEM. The monitor could not see. Reporting that
              as healthy hides an outage; reporting it as an outage cries wolf. It is its
              own thing.
"""
import json
import os
import re
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

# --- configuration, all from the environment ------------------------------------------
METRICS_URL = os.environ.get("METRICS_URL", "http://stream-relay:9998/metrics")
NGINX_HEALTH = os.environ.get("NGINX_HEALTH", "https://nginx/healthz")
ACCESS_LOG = os.environ.get("ACCESS_LOG", "/var/log/relay/access.log")
STATUS_PATH = os.environ.get("STATUS_PATH", "/srv/relay-status/status.json")
# The certificate is read off the TLS HANDSHAKE, not off disk.
#
# Two reasons, and the second is the one that matters. certbot keeps live/ and archive/
# at 0700 root, so an unprivileged watchdog cannot read the file without loosening
# permissions on a directory that also holds the private key. And the file is the wrong
# thing to measure: a renewed certificate that nginx has not reloaded still serves the
# OLD one, so the file would report healthy while every viewer gets an expired cert.
# The handshake reports what is actually served.
TLS_HOST = os.environ.get("TLS_HOST", "nginx")
TLS_PORT = int(os.environ.get("TLS_PORT", "443"))
TLS_SNI = os.environ.get("TLS_SNI", "")
INTERVAL = int(os.environ.get("INTERVAL_SECONDS", "300"))

# `-` not `:-`: an UNSET variable is a different fault from one the render set to empty.
# page-stream learned this the hard way - substituting a default for an empty value means
# a rendering bug silently becomes "expect nothing", and a watchdog that checks nothing
# reports healthy forever.
_EXPECTED_RAW = os.environ.get("EXPECTED_PUBLISHERS")
EXPECTED_UNSET = _EXPECTED_RAW is None
EXPECTED = [p for p in (_EXPECTED_RAW or "").split(",") if p]
ALL_PATHS = [p for p in os.environ.get("RELAY_PATHS", "").split(",") if p]

# Errored frames PER PASS, not cumulatively - a lifetime counter warns forever after one
# blip. SRT loss percent used to be the trigger and was the wrong metric: it tracks
# bitrate rather than damage, its drop counter matches its retransmit counter to the
# packet, and raising SRT latency tenfold moved it by noise while frames_in_error stayed
# at 0 and the displays stayed correct. Loss is still recorded; it no longer pages.
FRAMES_IN_ERROR_WARN = int(os.environ.get("FRAMES_IN_ERROR_WARN", "10"))
CERT_DAYS_WARN = int(os.environ.get("CERT_DAYS_WARN", "21"))
CERT_DAYS_FAIL = int(os.environ.get("CERT_DAYS_FAIL", "7"))

# Trailing slash would make the failure ping "<url>//fail", which 404s silently - so the
# one signal that matters most would never arrive.
HC_URL = os.environ.get("HEALTHCHECKS_URL", "").strip().rstrip("/")

try:
    CLIENT_CLASSES = json.loads(os.environ.get("CLIENT_CLASSES", "[]"))
except json.JSONDecodeError as exc:
    print(f"[watchdog] CLIENT_CLASSES is not valid JSON: {exc}", file=sys.stderr)
    CLIENT_CLASSES = []

_COMPILED = [
    (c["name"], re.compile(c["match"]), bool(c.get("retain_address")))
    for c in CLIENT_CLASSES
]

METRIC = re.compile(r'^(?P<name>[a-z_]+)\{(?P<labels>[^}]*)\}\s+(?P<value>[0-9.e+-]+)$')
LABEL = re.compile(r'(\w+)="([^"]*)"')


def parse_metrics(body: str) -> dict:
    """Prometheus exposition -> {series: [(labels, value)]}. No client library needed."""
    out: dict[str, list] = {}
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = METRIC.match(line)
        if not m:
            continue
        labels = dict(LABEL.findall(m.group("labels")))
        try:
            value = float(m.group("value"))
        except ValueError:
            continue
        out.setdefault(m.group("name"), []).append((labels, value))
    return out


def classify(ua: str) -> tuple[str, bool]:
    for name, pattern, retain in _COMPILED:
        if pattern.search(ua):
            return name, retain
    return "other", False


class LogTail:
    """Reads new lines, then TRUNCATES.

    The telemetry log lives on a volume, so Docker's json-file rotation does not touch it
    and nothing else would ever bound it. Truncating after each pass keeps it to one
    interval of data by construction.

    Safe because nginx opens access logs O_APPEND: after truncation the next write lands
    at offset 0 rather than leaving a sparse file. The cost is a race - lines written
    between the final read and the truncate are lost. That is a few seconds of a viewer
    count every five minutes, and the full history is still in `docker logs nginx`, which
    keeps its own capped copy.
    """

    def __init__(self, path: str):
        self.path = path

    def drain(self) -> tuple[list[dict], int]:
        if not os.path.exists(self.path):
            return [], 0
        rows, bad = [], 0
        try:
            with open(self.path, "r+", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rows.append(json.loads(line))
                    except json.JSONDecodeError:
                        # A torn final line is normal: nginx may be mid-write. Counted
                        # rather than raised, but counted - silently dropping parse
                        # failures is how a broken log_format looks like no traffic.
                        bad += 1
                fh.truncate(0)
        except OSError as exc:
            print(f"[watchdog] cannot read {self.path}: {exc}", file=sys.stderr)
            return [], 0
        return rows, bad


def cert_days_left() -> float | None:
    """Days until the certificate nginx is currently SERVING expires."""
    import ssl

    if not TLS_SNI:
        print("[watchdog] TLS_SNI is unset; cannot check the certificate",
              file=sys.stderr)
        return None

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    # Not verifying: the certificate is issued for the public name and this connects to
    # the container by its compose alias, so the hostname would never match and the CA
    # path is not the question. What is wanted is the peer's notAfter. SNI is still sent,
    # so nginx picks the right certificate.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((TLS_HOST, TLS_PORT), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=TLS_SNI) as tls:
                der = tls.getpeercert(binary_form=True)
    except (OSError, ssl.SSLError) as exc:
        print(f"[watchdog] TLS handshake with {TLS_HOST}:{TLS_PORT} failed: {exc}",
              file=sys.stderr)
        return None
    if not der:
        return None

    # getpeercert() returns {} under CERT_NONE, so the DER is decoded instead. openssl
    # rather than hand-parsing: getting DER date arithmetic subtly wrong would make this
    # check quietly always pass, which is worse than not having it.
    try:
        out = subprocess.run(
            ["openssl", "x509", "-enddate", "-noout"],
            input=ssl.DER_cert_to_PEM_cert(der),
            capture_output=True, text=True, timeout=10, check=True,
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError) as exc:
        print(f"[watchdog] openssl failed: {exc}", file=sys.stderr)
        return None
    if "=" not in out:
        return None
    stamp = out.split("=", 1)[1].strip()
    try:
        expires = datetime.strptime(stamp, "%b %d %H:%M:%S %Y %Z").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        print(f"[watchdog] cannot parse notAfter {stamp!r}: {exc}", file=sys.stderr)
        return None
    return (expires - datetime.now(timezone.utc)).total_seconds() / 86400.0


def nginx_serving() -> bool | None:
    """None means 'could not tell', which is not the same as False."""
    ctx = None
    if NGINX_HEALTH.startswith("https://"):
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        # The certificate is issued for the public name; this connects to the container by
        # its compose alias. Verifying would fail on the name, and the question here is
        # only "does nginx answer", not "is the chain good" - cert validity is checked
        # separately and properly from the file.
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(NGINX_HEALTH, timeout=10, context=ctx) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as exc:
        return exc.code == 200
    except (urllib.error.URLError, socket.timeout, OSError):
        return False


def ping(url: str, body: str, fail: bool) -> str:
    """Report the ping's OWN outcome. A monitor that cannot deliver must say so."""
    if not url:
        return "no HEALTHCHECKS_URL set; nothing was reported off this host"
    target = url + ("/fail" if fail else "")
    req = urllib.request.Request(target, data=body.encode()[:9000], method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            if resp.status == 200:
                return "ok"
            return f"unexpected HTTP {resp.status}"
    except urllib.error.HTTPError as exc:
        if exc.code in (400, 404):
            return (f"HTTP {exc.code} - HEALTHCHECKS_URL is wrong, "
                    "SO THIS ALERT DID NOT ARRIVE")
        return f"HTTP {exc.code}"
    except (urllib.error.URLError, socket.timeout, OSError) as exc:
        return f"unreachable ({exc})"


def collect(previous: dict) -> dict:
    now = datetime.now(timezone.utc)
    problems: list[str] = []
    warnings: list[str] = []
    faults: list[str] = []

    # --- publishers -------------------------------------------------------------------
    paths: dict[str, dict] = {}
    try:
        with urllib.request.urlopen(METRICS_URL, timeout=15) as resp:
            metrics = parse_metrics(resp.read().decode("utf-8", "replace"))
        metrics_ok = True
    except Exception as exc:  # noqa: BLE001 - any failure here is "cannot see"
        metrics = {}
        metrics_ok = False
        faults.append(f"cannot read MediaMTX metrics at {METRICS_URL}: {exc}")

    for labels, _ in metrics.get("paths", []):
        paths.setdefault(labels.get("name", "?"), {})["state"] = labels.get("state")
    for labels, value in metrics.get("paths_inbound_bytes", []):
        paths.setdefault(labels.get("name", "?"), {})["bytes"] = int(value)
    for labels, value in metrics.get("paths_inbound_frames_in_error", []):
        paths.setdefault(labels.get("name", "?"), {})["frame_errors"] = int(value)

    # SRT quality, per publishing connection.
    srt: dict[str, dict] = {}
    def _srt(series, key):
        for labels, value in metrics.get(series, []):
            if labels.get("state") != "publish":
                continue
            srt.setdefault(labels.get("path", "?"), {})[key] = value
    _srt("srt_conns_packets_received", "rx")
    _srt("srt_conns_packets_received_loss", "loss")
    _srt("srt_conns_packets_received_retrans", "retrans")

    for name, stats in srt.items():
        rx = stats.get("rx", 0)
        if rx > 0:
            # Recorded, not alerted on. Useful as a trend; not evidence of damage.
            pct = 100.0 * stats.get("loss", 0) / rx
            paths.setdefault(name, {})["srt_loss_percent"] = round(pct, 3)

    # WITHOUT METRICS, SAY NOTHING ABOUT PUBLISHERS.
    #
    # An empty `paths` would otherwise make every expected channel "absent from the
    # relay", which is a claim the watchdog has not earned: it observed nothing, not
    # absence. Reporting cannot-see as broken is the same mistake as reporting it as
    # healthy, just in the other direction - and here it would name eight channels as
    # down every time the metrics endpoint hiccups.
    if not metrics_ok:
        return {
            "generated": now.isoformat(),
            "healthy": False,
            "problems": [],
            "warnings": [],
            "faults": faults,
            "expected_publishers": EXPECTED,
            "known_paths": ALL_PATHS,
            "nginx_serving": nginx_serving(),
            "cert_days_left": None,
            "paths": {},
        }

    if EXPECTED_UNSET:
        faults.append(
            "EXPECTED_PUBLISHERS is unset, so no publisher was checked; "
            "render-relay.py should always emit it"
        )
    elif not EXPECTED:
        # Legitimate today - no channel has cut over - and it must not read as healthy.
        warnings.append("no channel declares publishing: true, so no publisher is expected")

    for name in EXPECTED:
        info = paths.get(name)
        if info is None:
            problems.append(f"{name}: expected to be publishing, absent from the relay")
            continue
        if info.get("state") != "ready":
            problems.append(f"{name}: state={info.get('state')}, expected ready")
            continue
        prev_err = (previous.get("paths") or {}).get(name, {}).get("frame_errors")
        cur_err = info.get("frame_errors")
        if prev_err is not None and cur_err is not None:
            delta_err = cur_err - prev_err
            info["frame_errors_delta"] = delta_err
            if delta_err > FRAMES_IN_ERROR_WARN:
                warnings.append(
                    f"{name}: {delta_err} errored frames this pass "
                    f"(over {FRAMES_IN_ERROR_WARN}) - the picture is degrading"
                )

        prev = (previous.get("paths") or {}).get(name, {}).get("bytes")
        cur = info.get("bytes")
        if prev is None:
            info["advancing"] = None  # first pass; nothing to compare against yet
        elif cur is not None and cur > prev:
            info["advancing"] = True
            info["bytes_delta"] = cur - prev
        else:
            # THE failure a single reading cannot see. A frozen non-zero counter is
            # exactly what a wedged publisher looks like, and `ready: true` stays true.
            info["advancing"] = False
            info["bytes_delta"] = 0
            problems.append(
                f"{name}: ready but bytesReceived has not moved since the last pass "
                f"({cur} bytes) - the publisher is wedged"
            )

    # --- viewers ----------------------------------------------------------------------
    rows, malformed = LogTail(ACCESS_LOG).drain()
    if malformed:
        warnings.append(f"{malformed} unparseable line(s) in the access log")
    viewers: dict[str, dict] = {}
    for row in rows:
        path = row.get("path") or "-"
        if path == "-":
            continue
        cls, retain = classify(row.get("ua") or "")
        bucket = viewers.setdefault(path, {"requests": 0, "bytes": 0, "classes": {},
                                           "devices": {}})
        bucket["requests"] += 1
        bucket["bytes"] += int(row.get("bytes") or 0)
        bucket["classes"][cls] = bucket["classes"].get(cls, 0) + 1
        # PRIVACY. An address is kept only for a class that declares retain_address -
        # the managed displays, so a dead one can be named. Everyone else is counted and
        # their address discarded here, before it reaches status.json or a ping body.
        if retain and row.get("ip"):
            key = f"{cls}:{row['ip']}"
            bucket["devices"][key] = bucket["devices"].get(key, 0) + 1

    for name, bucket in viewers.items():
        bucket["distinct_devices"] = len(bucket["devices"])
        paths.setdefault(name, {})["viewers"] = bucket

    # --- delivery ---------------------------------------------------------------------
    serving = nginx_serving()
    if serving is False:
        problems.append(
            "nginx is not answering /healthz - PID 1 in that container is the shell, so "
            "it can serve nothing while docker ps shows it running"
        )

    days = cert_days_left()
    if days is None:
        faults.append(
            f"could not read the certificate served by {TLS_HOST}:{TLS_PORT}"
        )
    elif days < CERT_DAYS_FAIL:
        problems.append(f"certificate expires in {days:.1f} days")
    elif days < CERT_DAYS_WARN:
        warnings.append(f"certificate expires in {days:.1f} days")

    healthy = not problems and not faults
    return {
        "generated": now.isoformat(),
        "healthy": healthy,
        "problems": problems,
        "warnings": warnings,
        "faults": faults,
        "expected_publishers": EXPECTED,
        "known_paths": ALL_PATHS,
        "nginx_serving": serving,
        "cert_days_left": None if days is None else round(days, 1),
        "paths": paths,
    }


def summarise(snap: dict) -> str:
    lines = []
    if snap["faults"]:
        lines.append("WATCHDOG PROBLEM (the monitor could not see, which is not the same")
        lines.append("as the relay being down):")
        lines += [f"  - {f}" for f in snap["faults"]]
    if snap["problems"]:
        lines.append("PROBLEMS:")
        lines += [f"  - {p}" for p in snap["problems"]]
    if snap["warnings"]:
        lines.append("WARNINGS (not a failure):")
        lines += [f"  - {w}" for w in snap["warnings"]]
    lines.append("PATHS:")
    for name in sorted(snap["paths"]):
        info = snap["paths"][name]
        v = info.get("viewers") or {}
        classes = ", ".join(f"{k}={c}" for k, c in sorted((v.get("classes") or {}).items()))
        lines.append(
            f"  {name}: state={info.get('state')} "
            f"delta={info.get('bytes_delta', '-')}B "
            f"loss={info.get('srt_loss_percent', '-')}% "
            f"requests={v.get('requests', 0)} devices={v.get('distinct_devices', 0)}"
            + (f" [{classes}]" if classes else "")
        )
    if snap["cert_days_left"] is not None:
        lines.append(f"certificate: {snap['cert_days_left']} days left")
    lines.append("Next: gh workflow run watchdog.yml --repo pu-shd/stream-relay-config")
    return "\n".join(lines)


def write_status(snap: dict) -> None:
    tmp = STATUS_PATH + ".tmp"
    try:
        os.makedirs(os.path.dirname(STATUS_PATH), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(snap, fh, indent=2, sort_keys=True)
        # Atomic: the workflow reads this file on a schedule of its own and must never
        # catch a half-written one.
        os.replace(tmp, STATUS_PATH)
    except OSError as exc:
        print(f"[watchdog] cannot write {STATUS_PATH}: {exc}", file=sys.stderr)


def main() -> int:
    stopping = {"now": False}

    def _stop(signum, _frame):
        stopping["now"] = True
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    once = os.environ.get("WATCHDOG_ONCE") == "1"
    previous: dict = {}

    while not stopping["now"]:
        snap = collect(previous)
        write_status(snap)

        verdict = "healthy" if snap["healthy"] else "NOT healthy"
        n = len(snap["problems"]) + len(snap["faults"])
        print(f"[watchdog] {snap['generated']} {verdict} ({n} problem(s))", flush=True)

        body = summarise(snap)
        # Warnings ride the SUCCESS ping. Healthchecks.io keeps the body, so the trend is
        # visible in the check's history without any of it counting as a failure.
        result = ping(HC_URL, body, fail=not snap["healthy"])
        print(f"[watchdog] healthchecks.io: {result}", flush=True)

        previous = snap
        if once:
            return 0 if snap["healthy"] else 1
        # Interruptible sleep, so SIGTERM does not wait out the whole interval.
        for _ in range(INTERVAL):
            if stopping["now"]:
                break
            time.sleep(1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
