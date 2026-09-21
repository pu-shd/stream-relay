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
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
WATCHDOG = REPO_ROOT / "docker" / "watchdog" / "watchdog.py"

# A real certificate for the default environment, so the openssl path runs for real in
# every case rather than being stubbed. An absent CERT_PATH is itself a fault - correctly,
# since the compose always sets it - which would otherwise make every unrelated case
# unhealthy for the wrong reason.
_CERT_DIR = tempfile.mkdtemp()
GOOD_CERT = os.path.join(_CERT_DIR, "fullchain.pem")
subprocess.run(
    ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "90",
     "-subj", "/CN=relay-test", "-keyout", os.path.join(_CERT_DIR, "key.pem"),
     "-out", GOOD_CERT],
    capture_output=True, check=True,
)
atexit.register(lambda: shutil.rmtree(_CERT_DIR, ignore_errors=True))


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
        "CERT_PATH": GOOD_CERT,
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
paths_inbound_frames_in_error{{name="live-events",state="ready"}} 0
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
        fake_metrics(mod, METRICS_READY.format(bytes=1000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("wedged" in p for p in snap["problems"]), snap["problems"])

    def test_the_first_pass_does_not_alert(self):
        """No previous sample yet. Alerting here would fire on every container start,
        which is every deploy - and an alert that always fires is an alert nobody reads."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(bytes=1000, loss=0))
        snap = mod.collect({})
        self.assertEqual(snap["problems"], [])
        self.assertIsNone(snap["paths"]["live-events"]["advancing"])

    def test_advancing_bytes_are_healthy(self):
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])
        self.assertTrue(snap["paths"]["live-events"]["advancing"])
        self.assertEqual(snap["paths"]["live-events"]["bytes_delta"], 1000)

    def test_an_expected_publisher_that_is_absent_is_a_problem(self):
        mod = load_watchdog(EXPECTED_PUBLISHERS="live-events,scenic")
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("scenic" in p for p in snap["problems"]), snap["problems"])

    def test_a_path_nobody_publishes_to_is_not_a_problem(self):
        """Seven of the eight paths exist with no publisher BY DESIGN - they have not cut
        over from Kaltura yet. Expecting all of them would page about seven correct
        absences, which is precisely how a monitor gets muted."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])
        self.assertEqual(snap["paths"]["news"]["state"], "notReady")


class Severity(unittest.TestCase):
    """Degraded, broken and cannot-see are three different things."""

    def test_srt_loss_warns_and_does_not_fail(self):
        """Measured 1.69% on the live ingest while planning this. A lossy uplink is worth
        knowing about and is not an outage; flipping the check to down for it would make a
        bad afternoon and a dead wall indistinguishable."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=90000))  # 9%
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(snap["healthy"], "SRT loss must not fail the check")
        self.assertTrue(any("SRT loss" in w for w in snap["warnings"]), snap["warnings"])

    def test_loss_below_the_threshold_is_silent(self):
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=10000))  # 1%
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["warnings"], [])
        self.assertEqual(snap["paths"]["live-events"]["srt_loss_percent"], 1.0)

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
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"])
        self.assertTrue(any("unset" in f for f in snap["faults"]), snap["faults"])

    def test_nothing_expected_yet_warns_rather_than_claiming_health(self):
        """True today - no channel declares publishing: true. Distinct from unset."""
        mod = load_watchdog(EXPECTED_PUBLISHERS="")
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({})
        self.assertTrue(any("no channel" in w for w in snap["warnings"]), snap["warnings"])
        self.assertEqual(snap["faults"], [])


class Delivery(unittest.TestCase):
    def test_a_dead_nginx_is_a_problem_even_though_its_container_is_up(self):
        """PID 1 in that container is the SHELL - the command backgrounds nginx to loop on
        reloads - so when nginx dies the container stays up, restart: unless-stopped never
        fires, and docker ps shows it running. Nothing else in the stack notices."""
        mod = load_watchdog()
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0), nginx_ok=False)
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
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
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
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["problems"], [])


class Certificate(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.dir, ignore_errors=True))

    def _cert(self, days):
        path = os.path.join(self.dir, "fullchain.pem")
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-days", str(days), "-subj", "/CN=relay-test",
             "-keyout", os.path.join(self.dir, "key.pem"), "-out", path],
            capture_output=True, check=True,
        )
        return path

    def test_a_healthy_certificate_is_silent(self):
        mod = load_watchdog(CERT_PATH=self._cert(90))
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertEqual(snap["warnings"], [])
        self.assertGreater(snap["cert_days_left"], 80)

    def test_an_expiring_certificate_warns_then_fails(self):
        """The adopted deployment ran `certonly` once and its certificate expired on
        2026-05-03 with nothing saying so."""
        mod = load_watchdog(CERT_PATH=self._cert(14))
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertTrue(snap["healthy"], "21 days out is a warning, not an outage")
        self.assertTrue(any("certificate" in w for w in snap["warnings"]))

        mod = load_watchdog(CERT_PATH=self._cert(3))
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        snap = mod.collect({"paths": {"live-events": {"bytes": 1000}}})
        self.assertFalse(snap["healthy"], "3 days out must fail")

    def test_an_unreadable_certificate_is_a_fault(self):
        mod = load_watchdog(CERT_PATH="/nonexistent/fullchain.pem")
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
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
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
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
        fake_metrics(mod, METRICS_READY.format(bytes=2000, loss=0))
        mod.write_status(mod.collect({"paths": {"live-events": {"bytes": 1000}}}))
        self.assertTrue(os.path.exists(target))
        json.load(open(target))
        self.assertFalse(os.path.exists(target + ".tmp"), "the temp file was left behind")


if __name__ == "__main__":
    unittest.main(verbosity=2)
