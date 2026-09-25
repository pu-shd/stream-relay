#!/usr/bin/env python3
"""Offline suite for the relay watchdog. stdlib unittest - no pytest, no network.

The watchdog decides whether anyone is told the wall has gone dark, so it is RUN against
synthetic inputs rather than grepped. Every case below is a state the relay can actually
be in, and the first one is a state in which every signal that existed before this
watchdog reported green.

    python3 tests/watchdog/test_watchdog.py
"""
import atexit
import importlib.util
import json
from datetime import datetime, timezone
import time
import os
import shutil
import subprocess
import sys
import socket
import tempfile
import threading
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
WATCHDOG = REPO_ROOT / "docker" / "watchdog" / "watchdog.py"

def _make_cert(days: int, directory: str) -> tuple[str, str]:
    cert = os.path.join(directory, "fullchain.pem")
    key = os.path.join(directory, "key.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", str(days),
         "-subj", "/CN=relay-test", "-keyout", key, "-out", cert],
        capture_output=True, check=True,
    )
    return cert, key


class TLSServer:
    """A throwaway TLS listener presenting a certificate with a chosen lifetime.

    The expiry check reads the certificate off the HANDSHAKE rather than off disk, so it
    is exercised against a real handshake. Stubbing it would test nothing: the whole
    point of the change was that the served certificate and the file can differ.
    """

    def __init__(self, days: int):
        import ssl as _ssl
        self.dir = tempfile.mkdtemp()
        cert, key = _make_cert(days, self.dir)
        ctx = _ssl.SSLContext(_ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self._ctx = ctx
        self._stop = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            try:
                with self._ctx.wrap_socket(conn, server_side=True):
                    pass
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

    def close(self):
        self._stop = True
        try:
            self.sock.close()
        except OSError:
            pass
        shutil.rmtree(self.dir, ignore_errors=True)


# One long-lived certificate for the default environment, so unrelated cases are not
# failed by a certificate fault they are not about.
_DEFAULT_TLS = TLSServer(90)
atexit.register(_DEFAULT_TLS.close)


def load_watchdog(**env):
    """Import watchdog.py with a given environment.

    Its configuration is read at import time from os.environ, which is the right shape for
    a container and means each case needs a fresh module object.
    """
    defaults = {
        "METRICS_URL": "http://127.0.0.1:1/metrics",   # refused unless overridden
        "NGINX_HEALTH": "http://127.0.0.1:1/healthz",
        "ACCESS_LOG": "/nonexistent",
        "STATUS_PATH": "/nonexistent/status.json",
        "TLS_HOST": "127.0.0.1",
        "TLS_PORT": str(_DEFAULT_TLS.port),
        "TLS_SNI": "relay-test",
        "HEALTHCHECKS_URL": "",
        "RELAY_PATHS": "live-events,news",
        "EXPECTED_PUBLISHERS": "live-events",
        "CLIENT_CLASSES": json.dumps([
            {"name": "apple-tv", "match": "AppleCoreMedia.*Apple TV",
             "retain_address": True},
            {"name": "vlc", "match": "^VLC", "retain_address": False},
            {"name": "other", "match": ".*", "retain_address": False},
        ]),
    }
    defaults.update(env)
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update({"PATH": saved.get("PATH", "/usr/bin:/bin")})
    os.environ.update({k: v for k, v in defaults.items() if v is not None})
    try:
        spec = importlib.util.spec_from_file_location("wd", WATCHDOG)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(saved)


def _only_healthz(mod):
    """nginx answers; the metrics endpoint is unreachable. Isolates the two signals."""
    import io

    class _Resp(io.BytesIO):
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def urlopen(url, *a, **kw):
        if "healthz" in str(getattr(url, "full_url", url)):
            return _Resp(b"ok\n")
        raise OSError("connection refused")

    return urlopen


METRICS_READY = """\
paths{{name="live-events",state="ready"}} 1
paths_inbound_bytes{{name="live-events",state="ready"}} {bytes}
paths_inbound_frames_in_error{{name="live-events",state="ready"}} {errs}
srt_conns_packets_received{{id="a",path="live-events",remoteAddr="1.2.3.4:1",state="publish"}} 1000000
srt_conns_packets_received_loss{{id="a",path="live-events",remoteAddr="1.2.3.4:1",state="publish"}} {loss}
paths{{name="news",state="notReady"}} 1
paths_inbound_bytes{{name="news",state="notReady"}} 0
"""


def fake_metrics(mod, text, nginx_ok=True):
    """Replace the HTTP layer only.

    parse_metrics, the delta logic and the severity rules all still run for real; only the
    two sockets are stood in for. nginx_ok=False is how the dead-nginx case is driven.
    """
    import io

    class _Resp(io.BytesIO):
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def urlopen(url, *a, **kw):
        target = str(getattr(url, "full_url", url))
        if "metrics" in target:
            return _Resp(text.encode())
        if "healthz" in target:
            if not nginx_ok:
                raise OSError("connection refused")
            return _Resp(b"ok\n")
        raise OSError("refused")

    mod.urllib.request.urlopen = urlopen


class PublisherLiveness(unittest.TestCase):
    """The failure a single reading cannot see."""

    def test_a_frozen_byte_counter_is_a_problem(self):
        """state stays `ready`, the container healthcheck passes, docker ps is green, and
        nothing reaches the displays. One non-zero reading cannot tell this from health -
        only the delta between two can."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=1000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("wedged" in p for p in snap["problems"]), snap["problems"])

    def test_the_first_pass_does_not_alert(self):
        """No previous sample yet. Alerting here would fire on every container start,
        which is every deploy - and an alert that always fires is an alert nobody reads."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=1000, loss=0))
        snap = mod.collect({})
        self.assertEqual(snap["problems"], [])
        self.assertIsNone(snap["paths"]["live-events"]["advancing"])

    def test_advancing_bytes_are_healthy(self):
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])
        self.assertTrue(snap["paths"]["live-events"]["advancing"])
        self.assertEqual(snap["paths"]["live-events"]["bytes_delta"], 1000)

    def test_an_expected_publisher_that_is_absent_is_a_problem(self):
        mod = load_watchdog(EXPECTED_PUBLISHERS="live-events,scenic")
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("scenic" in p for p in snap["problems"]), snap["problems"])

    def test_a_path_nobody_publishes_to_is_not_a_problem(self):
        """Seven of the eight paths exist with no publisher BY DESIGN - they have not cut
        over from Kaltura yet. Expecting all of them would page about seven correct
        absences, which is precisely how a monitor gets muted."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])
        self.assertEqual(snap["paths"]["news"]["state"], "notReady")

    # --- a counter that went backwards -------------------------------------------------
    # 2026-09-23: all nine producers dropped and reconnected twice. The second outage
    # (23:28:01-23:29:49) fell entirely between two passes, so the watchdog never saw it;
    # what it saw at 23:31 was eight restarted byte counters, and it paged for eight wedged
    # publishers 72 seconds after every one of them had recovered. The only alert anyone
    # got that time was the false one.

    def test_a_restarted_counter_is_a_reconnect_not_a_wedge(self):
        """Lower than last pass is impossible for one publisher session, so it is a new
        one. Calling that wedged pages for a channel that is up and streaming."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=500, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 900_000_000}}})
        self.assertEqual(snap["problems"], [], "a recovered channel must not page")
        self.assertTrue(snap["healthy"])
        self.assertTrue(snap["paths"]["live-events"]["reconnected"])

    def test_a_reconnect_is_still_said_out_loud(self):
        """The channel was down. At a 5-minute interval a 110-second drop is otherwise
        invisible, so silence here would trade a false alarm for a blind spot."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=500, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 900_000_000}}})
        self.assertTrue(
            any("reconnected" in w for w in snap["warnings"]), snap["warnings"]
        )

    def test_a_channel_that_keeps_reconnecting_eventually_fails(self):
        """Warning every pass would let a channel flap all night without ever failing.

        The readings are what a real flap looks like: each pass catches a session younger
        than the one before it, so the counter keeps landing lower. (Two sessions of the
        SAME age read equal, and that is the wedge case, not this one.)"""
        mod = load_watchdog()
        prev = {"paths": {"live-events": {"bytes": 900_000_000}}}
        for reading in (20_000_000, 5_000_000):
            fake_metrics(mod, METRICS_READY.format(errs=0, bytes=reading, loss=0))
            snap = mod.collect(prev)
            prev = snap
        self.assertEqual(snap["paths"]["live-events"]["reconnect_runs"],
                         mod.RECONNECT_RUNS_FAIL)
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("flapping" in p for p in snap["problems"]), snap["problems"])

    def test_recovering_clears_the_flap_count(self):
        """Two reconnects an hour apart are not a flapping channel. Only consecutive
        passes count, or one bad night would arm the failure forever."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=500, loss=0))
        first = mod.collect({"paths": {"live-events": {"bytes": 900_000_000}}})
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=5000, loss=0))
        steady = mod.collect(first)          # advanced normally; incident over
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=500, loss=0))
        later = mod.collect(steady)          # a fresh, unrelated reconnect
        self.assertEqual(later["problems"], [], later["problems"])
        self.assertEqual(later["paths"]["live-events"]["reconnect_runs"], 1)

    def test_an_unchanged_counter_is_still_a_wedge(self):
        """The guard above must not swallow the case it was built around: equal is not
        lower, and a frozen publisher stays a problem."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=1000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(any("wedged" in p for p in snap["problems"]), snap["problems"])


class Severity(unittest.TestCase):
    """Degraded, broken and cannot-see are three different things."""

    def test_srt_loss_is_recorded_but_never_warns(self):
        """It was the trigger and it was the wrong metric.

        With eight channels live it read 0.1% to 8.4%, tracking bitrate rather than
        anything visible; its drop counter matched its retransmit counter to the packet
        across four independent connections; and raising SRT latency tenfold moved it by
        noise while frames_in_error stayed at 0 and the displays stayed correct.
        """
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=90000))  # 9%
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(snap["healthy"])
        self.assertEqual(snap["warnings"], [], "loss still pages")
        self.assertEqual(snap["paths"]["live-events"]["srt_loss_percent"], 9.0,
                         "loss must still be recorded as a trend")

    def test_errored_frames_over_the_threshold_warn(self):
        """The signal that does mean picture damage."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=50, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000, "frame_errors": 0}}})
        self.assertTrue(snap["healthy"], "degrading is not an outage")
        self.assertTrue(any("errored frames" in w for w in snap["warnings"]), snap["warnings"])

    def test_errored_frames_are_measured_per_pass_not_cumulatively(self):
        """A lifetime counter warns forever after one blip. Only the delta matters."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=5000, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000, "frame_errors": 4998}}})
        self.assertEqual(snap["warnings"], [],
                         "a high lifetime count warned despite only 2 new errors")
        self.assertEqual(snap["paths"]["live-events"]["frame_errors_delta"], 2)

    def test_the_first_pass_cannot_judge_frame_errors(self):
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=9999, bytes=2000, loss=0))
        snap = mod.collect({})
        self.assertEqual(snap["warnings"], [])
        self.assertNotIn("frame_errors_delta", snap["paths"]["live-events"])

    def test_unreadable_metrics_is_a_watchdog_fault_not_a_healthy_relay(self):
        """The monitor could not see. Reporting that as healthy hides an outage."""
        mod = load_watchdog()
        fake_metrics(mod, "")            # nginx fine, metrics endpoint unreachable
        mod.urllib.request.urlopen = _only_healthz(mod)
        snap = mod.collect({})
        self.assertFalse(snap["healthy"])
        self.assertTrue(snap["faults"], "an unreachable metrics endpoint reported healthy")
        self.assertEqual(snap["problems"], [], "a fault must not masquerade as a problem")

    def test_unset_expectations_is_a_fault_not_an_empty_check(self):
        """A run that checked nothing must never report healthy. If the render stops
        emitting the variable, that is a rendering bug, not an empty estate."""
        mod = load_watchdog(EXPECTED_PUBLISHERS=None)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("unset" in f for f in snap["faults"]), snap["faults"])

    def test_nothing_expected_yet_warns_rather_than_claiming_health(self):
        """True today - no channel declares publishing: true. Distinct from unset."""
        mod = load_watchdog(EXPECTED_PUBLISHERS="")
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({})
        self.assertTrue(any("no channel" in w for w in snap["warnings"]), snap["warnings"])
        self.assertEqual(snap["faults"], [])


class MaintenanceSlate(unittest.TestCase):
    """While the flag is set, the producers being down is the point, not the outage.

    What becomes the outage instead is the slate itself: frozen while on air, every display
    is frozen; left on for hours, the wall says "back shortly" while everything reports
    healthy. Both have to be problems, or the feature trades one silent failure for two.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.maint = os.path.join(self.tmp, "maintenance")
        os.mkdir(self.maint)
        self.playlist = os.path.join(self.tmp, "main_stream.m3u8")
        self._touch(self.playlist)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    @staticmethod
    def _touch(path, age=0.0, body=""):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        t = time.time() - age
        os.utime(path, (t, t))

    def _mod(self, **env):
        return load_watchdog(MAINTENANCE_DIR=self.maint, SLATE_PLAYLIST=self.playlist,
                             SLATE_STALE_SECONDS="12", SLATE_MAX_HOURS="4", **env)

    def _set(self, age=0.0, by="a-maintainer"):
        since = datetime.now(timezone.utc).timestamp() - age
        body = json.dumps({"since": datetime.fromtimestamp(since, timezone.utc).isoformat(),
                           "by": by})
        self._touch(os.path.join(self.maint, "active"), age=age, body=body)

    def test_a_missing_publisher_in_maintenance_warns_instead_of_paging(self):
        """A planned producer reboot must not page. It must still say which are down -
        that is exactly the question before switching back."""
        mod = self._mod(EXPECTED_PUBLISHERS="live-events,scenic")
        self._set()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [], snap["problems"])
        self.assertTrue(snap["healthy"])
        self.assertTrue(any("in maintenance, expected" in w and "scenic" in w
                            for w in snap["warnings"]), snap["warnings"])

    def test_the_same_absence_outside_maintenance_still_pages(self):
        """The guard must not leak: without the flag, a missing publisher is an outage."""
        mod = self._mod(EXPECTED_PUBLISHERS="live-events,scenic")
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(any("scenic" in p for p in snap["problems"]), snap["problems"])

    def test_a_frozen_slate_on_air_is_a_problem(self):
        mod = self._mod()
        self._set()
        self._touch(self.playlist, age=60)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("every display is frozen" in p for p in snap["problems"]),
                        snap["problems"])

    def test_a_frozen_slate_off_air_warns(self):
        """Nobody is watching it yet, so it is not an outage - but it is the reason the
        next maintenance would fail, and that is worth knowing before it is needed."""
        mod = self._mod()
        self._touch(self.playlist, age=60)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])
        self.assertTrue(any("slate is not updating" in w for w in snap["warnings"]),
                        snap["warnings"])

    def test_a_missing_slate_playlist_is_not_fresh(self):
        mod = self._mod()
        os.unlink(self.playlist)
        self._set()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["slate"]["fresh"])
        self.assertTrue(any("every display is frozen" in p for p in snap["problems"]))

    def test_a_forgotten_flag_fails(self):
        mod = self._mod()
        self._set(age=5 * 3600)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("probably forgotten" in p for p in snap["problems"]),
                        snap["problems"])

    def test_a_recent_flag_is_announced_not_failed(self):
        mod = self._mod()
        self._set(age=600)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])
        self.assertTrue(snap["maintenance"]["active"])
        self.assertEqual(snap["maintenance"]["by"], "a-maintainer")
        self.assertTrue(any(w.startswith("MAINTENANCE:") for w in snap["warnings"]))

    def test_a_hand_made_flag_is_still_maintenance(self):
        """`touch active` on the host has no JSON in it. Its age comes from the file."""
        mod = self._mod()
        self._touch(os.path.join(self.maint, "active"), age=5 * 3600, body="")
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(snap["maintenance"]["active"])
        self.assertTrue(any("probably forgotten" in p for p in snap["problems"]))

    def test_a_stuck_gap_fails(self):
        """A switch-back that died half way leaves every playlist answering 503."""
        mod = self._mod()
        self._touch(os.path.join(self.maint, "gap"), age=mod.GAP_STUCK_SECONDS + 60)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(any("answering 503" in p for p in snap["problems"]), snap["problems"])

    def test_a_brief_gap_only_warns(self):
        mod = self._mod()
        self._touch(os.path.join(self.maint, "gap"), age=5)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])

    def test_no_slate_configured_checks_nothing(self):
        """An engine deployed without the feature must not fault on its absence."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])
        self.assertFalse(snap["maintenance"]["active"])
        self.assertFalse(snap["slate"]["configured"])

    def test_unreadable_metrics_still_report_maintenance(self):
        """The fault path returns early; the status report must still show the flag."""
        mod = self._mod()
        self._set()
        fake_metrics(mod, "")
        mod.urllib.request.urlopen = _only_healthz(mod)   # metrics unreachable
        snap = mod.collect({})
        self.assertTrue(snap["faults"])
        self.assertTrue(snap["maintenance"]["active"])


class Delivery(unittest.TestCase):
    def test_a_dead_nginx_is_a_problem_even_though_its_container_is_up(self):
        """PID 1 in that container is the SHELL - the command backgrounds nginx to loop on
        reloads - so when nginx dies the container stays up, restart: unless-stopped never
        fires, and docker ps shows it running. Nothing else in the stack notices."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0), nginx_ok=False)
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("nginx" in p for p in snap["problems"]), snap["problems"])
        self.assertIs(snap["nginx_serving"], False)


class ViewerTelemetry(unittest.TestCase):
    """Counts come from the nginx log, because MediaMTX cannot see a viewer at all."""

    def _with_log(self, lines, **env):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        tmp.write("".join(lines))
        tmp.close()
        self.addCleanup(os.unlink, tmp.name)
        mod = load_watchdog(ACCESS_LOG=tmp.name, **env)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        return mod, mod.collect({"paths": {"live-events": {"bytes": 1000}}}), tmp.name

    @staticmethod
    def _row(ip, ua, path="live-events", nbytes=1000):
        return json.dumps({"t": "2026-09-21T12:00:00+00:00", "ip": ip, "path": path,
                           "uri": f"/hls/{path}/seg1.ts", "status": 200,
                           "bytes": nbytes, "rt": 0.001, "tls": "TLSv1.3",
                           "ua": ua}) + "\n"

    APPLE = "AppleCoreMedia/1.0.0.23L773 (Apple TV; U; CPU OS 26_6 like Mac OS X; en_us)"

    def test_requests_are_counted_per_channel(self):
        _, snap, _ = self._with_log([
            self._row("140.180.240.72", self.APPLE),
            self._row("140.180.240.72", self.APPLE),
            self._row("128.112.1.1", "Mozilla/5.0", path="news"),
        ])
        self.assertEqual(snap["paths"]["live-events"]["viewers"]["requests"], 2)
        self.assertEqual(snap["paths"]["news"]["viewers"]["requests"], 1)

    def test_a_managed_display_keeps_its_address(self):
        """So a dead one can be named. 'Some Apple TV stopped fetching' is not actionable
        when there are ten of them."""
        _, snap, _ = self._with_log([self._row("140.180.240.72", self.APPLE)])
        devices = snap["paths"]["live-events"]["viewers"]["devices"]
        self.assertIn("apple-tv:140.180.240.72", devices)

    def test_an_anonymous_viewer_is_counted_but_never_identified(self):
        """A person watching from their desk is counted and their address discarded, in
        the watchdog, before it can reach status.json or a ping body."""
        _, snap, _ = self._with_log([
            self._row("128.112.9.9", "Mozilla/5.0 (Macintosh) Safari/605"),
            self._row("128.112.9.9", "VLC/3.0.20 LibVLC/3.0.20"),
        ])
        viewers = snap["paths"]["live-events"]["viewers"]
        self.assertEqual(viewers["requests"], 2)
        self.assertEqual(viewers["devices"], {}, "an anonymous viewer's IP was retained")
        blob = json.dumps(snap)
        self.assertNotIn("128.112.9.9", blob,
                         "an unretained address leaked into the snapshot")

    def test_class_counts_survive_a_hostile_user_agent(self):
        """Quotes and brackets are what broke the combined format. escape=json handles it
        in nginx; this pins that the watchdog does not re-break it."""
        _, snap, _ = self._with_log([
            self._row("10.0.0.1", 'Mozilla/5.0 "quoted" [bracket] \\slash'),
        ])
        self.assertEqual(snap["paths"]["live-events"]["viewers"]["classes"]["other"], 1)

    def test_a_torn_line_is_counted_not_swallowed(self):
        """nginx may be mid-write. Dropping parse failures silently is how a broken
        log_format looks exactly like nobody watching."""
        _, snap, _ = self._with_log([self._row("10.0.0.1", self.APPLE), '{"partial"\n'])
        self.assertTrue(any("unparseable" in w for w in snap["warnings"]), snap["warnings"])

    def test_the_log_is_truncated_after_reading(self):
        """Nothing else bounds this file: it is on a volume, so Docker's json-file
        rotation does not touch it. Draining each pass keeps it to one interval."""
        _, _, path = self._with_log([self._row("10.0.0.1", self.APPLE)])
        self.assertEqual(os.path.getsize(path), 0, "the access log was not drained")

    def test_a_missing_access_log_does_not_crash(self):
        """It does not exist until nginx has served its first /hls/ request."""
        mod = load_watchdog(ACCESS_LOG="/nonexistent/access.log")
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])


class Certificate(unittest.TestCase):
    """Read from the handshake, so it reports what nginx is SERVING.

    A renewal that nginx has not reloaded leaves the old certificate on the wire while a
    fresh one sits on disk. Checking the file would report healthy through exactly that
    outage - and certbot keeps live/ at 0700 root anyway, so reading it would have meant
    loosening a directory that also holds the private key.
    """

    def _snap(self, days):
        server = TLSServer(days)
        self.addCleanup(server.close)
        mod = load_watchdog(TLS_HOST="127.0.0.1", TLS_PORT=str(server.port),
                            TLS_SNI="relay-test")
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        return mod.collect({"paths": {"live-events": {"bytes": 1000}}})

    def test_a_healthy_certificate_is_silent(self):
        snap = self._snap(90)
        self.assertEqual(snap["warnings"], [])
        self.assertGreater(snap["cert_days_left"], 80)

    def test_an_expiring_certificate_warns_but_does_not_fail(self):
        snap = self._snap(14)
        self.assertTrue(snap["healthy"], "21 days out is a warning, not an outage")
        self.assertTrue(any("certificate" in w for w in snap["warnings"]))

    def test_an_almost_expired_certificate_fails(self):
        """The adopted deployment ran `certonly` once and its certificate expired on
        2026-05-03 with nothing saying so."""
        snap = self._snap(3)
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("certificate" in p for p in snap["problems"]))

    def test_an_unreachable_listener_is_a_fault_not_a_pass(self):
        """Cannot-see, again. A silent None here would read as a healthy certificate."""
        mod = load_watchdog(TLS_HOST="127.0.0.1", TLS_PORT="1", TLS_SNI="relay-test")
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(any("certificate" in f for f in snap["faults"]), snap["faults"])


class Reporting(unittest.TestCase):
    def test_a_missing_ping_url_is_reported_not_swallowed(self):
        """A monitor that cannot deliver must say so. Silence would be indistinguishable
        from a healthy estate, which is the one thing it must never be."""
        mod = load_watchdog()
        self.assertIn("nothing was reported", mod.ping("", "body", fail=False))

    def test_a_trailing_slash_cannot_produce_a_double_slash(self):
        """'<url>//fail' 404s silently, so the one signal that matters most never lands."""
        mod = load_watchdog(HEALTHCHECKS_URL="https://hc-ping.com/abc/")
        self.assertEqual(mod.HC_URL, "https://hc-ping.com/abc")

    def test_the_summary_names_the_next_command(self):
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        text = mod.summarise(mod.collect({"paths": {"live-events": {"bytes": 1000}}}))
        self.assertIn("gh workflow run watchdog.yml", text)

    def test_a_fault_is_labelled_as_a_watchdog_problem(self):
        """So a reader can tell 'the relay is down' from 'I could not look'."""
        mod = load_watchdog()
        fake_metrics(mod, "")
        mod.urllib.request.urlopen = _only_healthz(mod)
        text = mod.summarise(mod.collect({}))
        self.assertIn("WATCHDOG PROBLEM", text)

    def test_the_status_file_is_written_atomically(self):
        """The scheduled workflow reads it on its own cadence and must never catch a
        half-written one."""
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(d, ignore_errors=True))
        target = os.path.join(d, "sub", "status.json")
        mod = load_watchdog(STATUS_PATH=target)
        fake_metrics(mod, METRICS_READY.format(errs=0, bytes=2000, loss=0))
        mod.write_status(mod.collect({"paths": {"live-events": {"bytes": 1000}}}))
        self.assertTrue(os.path.exists(target))
        json.load(open(target))
        self.assertFalse(os.path.exists(target + ".tmp"), "the temp file was left behind")


if __name__ == "__main__":
    unittest.main(verbosity=2)
