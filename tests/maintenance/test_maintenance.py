#!/usr/bin/env python3
"""Offline tests for scripts/maintenance.py.

No nginx, no docker, no relay. The two things it talks to - nginx and MediaMTX's metrics -
are stood in for, and the nginx stand-in is a MODEL of the rendered rules rather than a
canned answer: it reads the same flag files and decides slate / 503 / real exactly as the
rendered /hls/ location does. So a test that turns maintenance on and then asks what a
viewer is served is testing the outcome, not that a file was written.

The real nginx rules are exercised against the real image in the config repo's suite and
by hand; this suite is about the tool's decisions.
"""
import importlib.util
import io
import json
import os
import shutil
import signal
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent.parent / "scripts" / "maintenance.py"

spec = importlib.util.spec_from_file_location("maintenance", TOOL)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

PATHS = ["news", "scenic", "live-events"]


def metrics_text(counts: dict) -> str:
    """Prometheus text for {path: bytes-or-None}. None = not publishing."""
    lines = []
    for name, b in counts.items():
        state = "ready" if b is not None else "notReady"
        lines.append(f'paths{{name="{name}",state="{state}"}} 1')
        if b is not None:
            lines.append(f'paths_inbound_bytes{{name="{name}",state="ready"}} {b}')
    return "\n".join(lines) + "\n"


class Relay:
    """The flag directory, the slate, and a model of nginx reading them."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp())
        self.maint = self.root / "maintenance"
        self.slate = self.root / "slate"
        self.maint.mkdir()
        self.slate.mkdir()
        self.env_file = self.root / "deploy.env"
        self.env_file.write_text(
            f"RELAY_MAINTENANCE_DIR={self.maint}\n"
            f"RELAY_SLATE_DIR={self.slate}\n"
            "RELAY_HOST=relay.example\n"
            "RELAY_HTTP_PATH=/hls/\n"
            f"RELAY_PATHS={','.join(PATHS)}\n"
            f"RELAY_EXPECTED_PUBLISHERS={','.join(PATHS)}\n"
            "SLATE_GAP_SECONDS=30\n"
            "HLS_SEGMENT_SECONDS=4\n"
        )
        self.clock = 1_790_000_000.0
        self.slept: list[float] = []
        self.nginx_honours_flags = True
        # Channels whose producer is down: MediaMTX removes their files, nginx 404s.
        self.dark: set[str] = set()
        self.samples: list[dict] = []
        self.seen_during_sleep: list[tuple[int, str]] = []
        self.fresh_slate()

    def fresh_slate(self, age=1.0):
        pl = self.slate / "main_stream.m3u8"
        pl.write_text("#EXTM3U\nslate_seg1790000000.ts\n")
        os.utime(pl, (self.clock - age, self.clock - age))

    # --- stand-ins ---
    def now(self):
        return self.clock

    def sleep(self, seconds):
        self.slept.append(seconds)
        # What a viewer would get while the tool waits - that is where the gap lives.
        self.seen_during_sleep.append(self.fetch(None, "/hls/news/main_stream.m3u8"))
        self.clock += seconds

    def fetch(self, _cfg, path):
        """The rendered /hls/ location, in Python."""
        if not self.nginx_honours_flags:
            return 200, "#EXTM3U\nreal_seg1.ts\n"
        if (self.maint / "gap").exists() and path.endswith(".m3u8"):
            return 503, "<html>503</html>"
        if (self.maint / "active").exists():
            return 200, "#EXTM3U\nslate_seg1790000000.ts\n"
        if path.split("/")[2] in self.dark:
            return 404, "<html>404</html>"
        return 200, "#EXTM3U\nreal_seg1.ts\n"

    def metrics(self):
        return metrics_text(self.samples.pop(0))

    def producers(self, first: dict, second: dict):
        self.samples = [first, second]

    def run(self, *args):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = m.main([*args, "--env", str(self.env_file)], fetch=self.fetch,
                          metrics=self.metrics, sleep=self.sleep, now=self.now)
        return code, buf.getvalue()

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


ALL_LIVE_1 = {p: 1000 for p in PATHS}
ALL_LIVE_2 = {p: 5000 for p in PATHS}


class On(unittest.TestCase):
    def setUp(self):
        self.r = Relay()

    def tearDown(self):
        self.r.cleanup()

    def test_on_puts_every_channel_on_the_slate(self):
        code, out = self.r.run("on", "--reason", "rebooting display-1")
        self.assertEqual(code, 0, out)
        for p in PATHS:
            self.assertEqual(self.r.fetch(None, f"/hls/{p}/main_stream.m3u8")[1].split()[1],
                             "slate_seg1790000000.ts")
        meta = json.loads((self.r.maint / "active").read_text())
        self.assertEqual(meta["reason"], "rebooting display-1")
        self.assertIn("since", meta)

    def test_a_frozen_slate_is_refused(self):
        """Switching the wall onto a playlist that stopped updating freezes every display."""
        self.r.fresh_slate(age=120)
        code, out = self.r.run("on")
        self.assertEqual(code, 1)
        self.assertIn("not updating", out)
        self.assertFalse((self.r.maint / "active").exists())

    def test_a_missing_slate_is_refused(self):
        (self.r.slate / "main_stream.m3u8").unlink()
        code, out = self.r.run("on")
        self.assertEqual(code, 1)
        self.assertFalse((self.r.maint / "active").exists())

    def test_a_flag_nginx_ignores_is_taken_back_down(self):
        """If nginx predates the maintenance mounts, the flag changes nothing viewers see -
        and left in place, the watchdog would report maintenance while they see the real
        channels. So it is removed, and the run fails saying why."""
        self.r.nginx_honours_flags = False
        code, out = self.r.run("on")
        self.assertEqual(code, 1)
        self.assertIn("not serving the slate", out)
        self.assertFalse((self.r.maint / "active").exists(), "an unhonoured flag was left set")

    def test_on_twice_changes_nothing(self):
        self.r.run("on", "--reason", "first")
        before = (self.r.maint / "active").read_text()
        code, out = self.r.run("on", "--reason", "second")
        self.assertEqual(code, 0)
        self.assertIn("Already in maintenance", out)
        self.assertEqual((self.r.maint / "active").read_text(), before,
                         "a second `on` overwrote when maintenance began")

    def test_on_clears_a_leftover_gap(self):
        (self.r.maint / "gap").write_text("x")
        code, _ = self.r.run("on")
        self.assertEqual(code, 0)
        self.assertEqual(self.r.fetch(None, "/hls/news/main_stream.m3u8")[0], 200)


class Off(unittest.TestCase):
    def setUp(self):
        self.r = Relay()
        self.assertEqual(self.r.run("on")[0], 0)

    def tearDown(self):
        self.r.cleanup()

    def test_off_refuses_while_a_producer_is_down(self):
        """THE check. Switching back before the producers are up puts them on the wall dark."""
        down = dict(ALL_LIVE_2, scenic=None)
        self.r.producers(dict(ALL_LIVE_1, scenic=None), down)
        code, out = self.r.run("off")
        self.assertEqual(code, 1, out)
        self.assertIn("scenic", out)
        self.assertEqual(self.r.fetch(None, "/hls/news/main_stream.m3u8")[1].split()[1],
                         "slate_seg1790000000.ts", "a refused off still switched the wall")

    def test_off_refuses_a_wedged_producer(self):
        """ready with a frozen counter is the watchdog's wedge. One sample cannot see it."""
        self.r.producers(ALL_LIVE_1, dict(ALL_LIVE_2, news=1000))
        code, out = self.r.run("off")
        self.assertEqual(code, 1)
        self.assertIn("wedged", out)

    def test_off_refuses_a_producer_that_reconnected_during_the_check(self):
        self.r.producers(ALL_LIVE_1, dict(ALL_LIVE_2, news=10))
        code, out = self.r.run("off")
        self.assertEqual(code, 1)
        self.assertIn("reconnected during the check", out)

    def test_off_with_every_producer_back_restores_the_channels(self):
        self.r.producers(ALL_LIVE_1, ALL_LIVE_2)
        code, out = self.r.run("off")
        self.assertEqual(code, 0, out)
        for p in PATHS:
            self.assertEqual(self.r.fetch(None, f"/hls/{p}/main_stream.m3u8"),
                             (200, "#EXTM3U\nreal_seg1.ts\n"))
        self.assertFalse((self.r.maint / "gap").exists(), "the gap outlived the switch-back")

    def test_the_gap_is_503_and_never_a_real_playlist_first(self):
        """What viewers get at EVERY step of the switch back. Dropping the flag before
        setting the gap would hand players one real playlist - a sequence regression, the
        thing the gap exists to avoid - in the instant between the two file operations.
        Checking only during the wait could never see that, so every flag operation
        records what a viewer would be served immediately after it."""
        self.r.producers(ALL_LIVE_1, ALL_LIVE_2)
        seen = []
        real_write, real_unlink = m.write_atomically, m.unlink

        def write(path, text):
            real_write(path, text)
            seen.append(("write " + path.name, self.r.fetch(None, "/hls/news/main_stream.m3u8")))

        def unlink(path):
            real_unlink(path)
            seen.append(("unlink " + path.name, self.r.fetch(None, "/hls/news/main_stream.m3u8")))

        m.write_atomically, m.unlink = write, unlink
        try:
            self.r.run("off")
        finally:
            m.write_atomically, m.unlink = real_write, real_unlink

        served = [what for _, what in seen]
        first_real = next(i for i, (c, b) in enumerate(served) if c == 200 and "real_seg" in b)
        self.assertTrue(any(c == 503 for c, _ in served[:first_real]),
                        f"a real playlist was served before any 503: {seen}")
        self.assertEqual(served[-1], (200, "#EXTM3U\nreal_seg1.ts\n"))
        self.assertIn(30, self.r.slept, "the configured gap was not waited out")

    def test_force_switches_back_with_a_producer_down(self):
        """Forced back with scenic dark: it switches, says it was forced, and still fails
        the run naming scenic - the wall is back, but not all of it."""
        self.r.dark = {"scenic"}
        self.r.producers(dict(ALL_LIVE_1, scenic=None), dict(ALL_LIVE_2, scenic=None))
        code, out = self.r.run("off", "--force")
        self.assertFalse((self.r.maint / "active").exists(), "force did not switch back")
        self.assertIn("WARNING (forced)", out)
        self.assertEqual(code, 1, "a forced off with a dark channel reported success")
        self.assertIn("scenic=404", out)

    def test_a_zero_gap_switches_straight_back(self):
        env = self.r.env_file.read_text().replace("SLATE_GAP_SECONDS=30", "SLATE_GAP_SECONDS=0")
        self.r.env_file.write_text(env)
        self.r.producers(ALL_LIVE_1, ALL_LIVE_2)
        code, _ = self.r.run("off")
        self.assertEqual(code, 0)
        self.assertNotIn(0, self.r.slept)
        self.assertFalse((self.r.maint / "gap").exists())

    def test_a_refused_off_after_an_interrupted_one_puts_the_wall_back_on_the_slate(self):
        """Killed mid-gap: no flag, gap set, every playlist 503. A refusal must not leave
        the wall like that."""
        (self.r.maint / "active").unlink()
        (self.r.maint / "gap").write_text("switching back\n")
        self.r.producers(dict(ALL_LIVE_1, scenic=None), dict(ALL_LIVE_2, scenic=None))
        code, out = self.r.run("off")
        self.assertEqual(code, 1)
        self.assertEqual(self.r.fetch(None, "/hls/news/main_stream.m3u8")[0], 200,
                         "left every playlist answering 503")
        self.assertIn("back on the slate", out)

    def test_off_when_not_in_maintenance_changes_nothing(self):
        (self.r.maint / "active").unlink()
        code, out = self.r.run("off")
        self.assertEqual(code, 0)
        self.assertIn("Not in maintenance", out)


class Configuration(unittest.TestCase):
    def test_an_old_deploy_env_is_misconfigured_not_a_crash(self):
        r = Relay()
        try:
            r.env_file.write_text("RELAY_HOST=relay.example\n")
            code, out = r.run("status")
            self.assertEqual(code, 2)
            self.assertIn("MISCONFIGURED", out)
        finally:
            r.cleanup()

    def test_a_missing_maintenance_dir_says_the_deploy_has_not_run(self):
        r = Relay()
        try:
            shutil.rmtree(r.maint)
            code, out = r.run("on")
            self.assertEqual(code, 2)
            self.assertIn("has not run", out)
        finally:
            r.cleanup()

    def test_status_reports_what_viewers_are_served(self):
        r = Relay()
        try:
            r.run("on")
            r.producers(ALL_LIVE_1, ALL_LIVE_2)
            code, out = r.run("status")
            self.assertEqual(code, 0)
            self.assertIn("MAINTENANCE ON", out)
            self.assertIn("served: slate", out)
            self.assertIn("✓ news", out)
        finally:
            r.cleanup()

    def test_the_flag_is_written_atomically(self):
        """No temporary file left beside the flag, and no half-written flag ever visible."""
        r = Relay()
        try:
            r.run("on")
            self.assertEqual(sorted(x.name for x in r.maint.iterdir()), ["active"])
        finally:
            r.cleanup()


if __name__ == "__main__":
    unittest.main(verbosity=2)
