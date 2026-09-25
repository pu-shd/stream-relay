#!/usr/bin/env python3
"""Put every channel on the maintenance slate, and take it off again.

    maintenance.py on     --env <deploy.env> [--reason TEXT] [--force]
    maintenance.py off    --env <deploy.env> [--force]
    maintenance.py status --env <deploy.env>

Runs ON the relay host, as the Actions runner's account, from the maintenance workflow.
It needs no sudo: the only thing it writes is a flag file in a directory relay-apply.sh
gave that account, and nginx tests for the file on every /hls/ request.

  on      Refuses if the slate is not updating (switching to it would freeze every
          display); writes the flag; confirms through nginx that EVERY channel is now
          served from the slate - and takes the flag back down if not, because a flag
          nginx is not honouring would have the watchdog report maintenance while viewers
          see something else.

  off     Refuses until every expected publisher is ready AND advancing across two
          samples - the watchdog's own test - and names the ones that are not. That is
          the "once I know it is back" check, done here rather than by eye. --force
          overrides. Then: playlists answer 503 for gap_seconds, then the real channels.

  status  The flag, the slate, and each publisher.

Exit: 0 done, 1 refused or failed (and why), 2 misconfigured.

WHY THE GAP. The slate numbers its segments from the Unix epoch, so switching ONTO it is a
forward jump in media sequence - a player that has fallen behind the live edge. Switching
back is the reverse: MediaMTX restarts its sequence at 0 whenever a publisher reconnects.
A sequence that goes backwards is something a player is entitled to reject. What players
demonstrably survive is what happens on every producer reconnect: the playlist is gone
for a while, then back, fresh. The gap reproduces that. Its length is unverified on the
Apple TVs; rehearse on one display.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

METRIC = re.compile(r'^(?P<name>[a-z_]+)\{(?P<labels>[^}]*)\}\s+(?P<value>[0-9.e+-]+)$')
LABEL = re.compile(r'(\w+)="([^"]*)"')


class Refused(Exception):
    """A precondition failed. Said plainly, with what to do next."""


class Misconfigured(Exception):
    pass


# --- configuration ----------------------------------------------------------------------

def read_env(path: str) -> dict:
    env: dict[str, str] = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise Misconfigured(f"cannot read {path}: {exc}") from exc
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
    return env


class Config:
    def __init__(self, env: dict):
        def need(key: str) -> str:
            v = env.get(key, "")
            if not v:
                raise Misconfigured(
                    f"{key} is not in deploy.env. The config repo predates the maintenance "
                    "slate, or render-relay.py was not re-run."
                )
            return v

        self.maintenance_dir = Path(need("RELAY_MAINTENANCE_DIR"))
        self.slate_dir = Path(need("RELAY_SLATE_DIR"))
        self.host = need("RELAY_HOST")
        self.http_path = env.get("RELAY_HTTP_PATH", "/hls/")
        self.paths = [p for p in need("RELAY_PATHS").split(",") if p]
        # Deliberately NOT need(): empty is legitimate before any channel has cut over.
        self.expected = [p for p in env.get("RELAY_EXPECTED_PUBLISHERS", "").split(",") if p]
        self.gap_seconds = int(env.get("SLATE_GAP_SECONDS", "30"))
        self.segment_seconds = int(env.get("HLS_SEGMENT_SECONDS", "4"))

    @property
    def active(self) -> Path:
        return self.maintenance_dir / "active"

    @property
    def gap(self) -> Path:
        return self.maintenance_dir / "gap"

    @property
    def slate_playlist(self) -> Path:
        return self.slate_dir / "main_stream.m3u8"


# --- the outside world, replaceable in tests --------------------------------------------

def metrics_from_watchdog() -> str:
    """MediaMTX's metrics, read the way the watchdog reads them.

    From inside the watchdog container, because MediaMTX grants `metrics` to that
    container's /32 and nothing else - which is the point of the grant.
    """
    r = subprocess.run(
        ["docker", "exec", "relay-watchdog", "wget", "-qO-", "http://stream-relay:9998/metrics"],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode != 0:
        raise Refused(
            f"cannot read the relay's metrics through relay-watchdog "
            f"({r.stderr.strip() or 'exit ' + str(r.returncode)}). Is it running? "
            "docker ps --filter name=relay-watchdog"
        )
    return r.stdout


def fetch_through_nginx(cfg: Config, path: str) -> tuple[int, str]:
    """GET a path through nginx exactly as a viewer would, TLS and all, from this host.

    --resolve to 127.0.0.1 rather than the public name: from inside the VM the public
    address is not on the NSG allowlist. The certificate is still verified against the
    real hostname, so this also proves what viewers are being served.
    """
    r = subprocess.run(
        ["curl", "-s", "--max-time", "10", "--resolve", f"{cfg.host}:443:127.0.0.1",
         "-w", "\n%{http_code}", f"https://{cfg.host}{path}"],
        capture_output=True, text=True, timeout=20,
    )
    body, _, code = r.stdout.rpartition("\n")
    try:
        return int(code), body
    except ValueError:
        return 0, r.stderr.strip()


# --- the pieces -------------------------------------------------------------------------

def publishers(text: str) -> dict[str, tuple[bool, int | None]]:
    """{path: (ready, inbound_bytes)} from Prometheus text."""
    ready: dict[str, bool] = {}
    counted: dict[str, int] = {}
    for line in text.splitlines():
        m = METRIC.match(line.strip())
        if not m:
            continue
        labels = dict(LABEL.findall(m.group("labels")))
        name = labels.get("name")
        if not name:
            continue
        if m.group("name") == "paths":
            ready[name] = ready.get(name, False) or (
                labels.get("state") == "ready" and float(m.group("value")) > 0
            )
        elif m.group("name") == "paths_inbound_bytes":
            counted[name] = int(float(m.group("value")))
    return {n: (ready.get(n, False), counted.get(n)) for n in set(ready) | set(counted)}


def producer_report(cfg: Config, metrics, sleep, interval: float) -> tuple[list, list]:
    """(lines, not_back). Two samples, because a ready path with a frozen counter is the
    wedged publisher the watchdog exists to catch - one reading cannot tell it from live."""
    first = publishers(metrics())
    sleep(interval)
    second = publishers(metrics())
    lines, not_back = [], []
    for name in cfg.expected:
        ready, b1 = first.get(name, (False, None))
        ready2, b2 = second.get(name, (False, None))
        if not (ready and ready2):
            state = "not publishing"
        elif b1 is None or b2 is None:
            state = "ready, but no byte counter"
        elif b2 > b1:
            lines.append(f"  ✓ {name}: live, {b2 - b1:,} bytes in {interval:g}s")
            continue
        elif b2 < b1:
            # Reconnected between the samples. Up, but not yet shown to be staying up.
            state = "reconnected during the check"
        else:
            state = "ready but not advancing (wedged)"
        lines.append(f"  ✗ {name}: {state}")
        not_back.append(name)
    return lines, not_back


def slate_age(cfg: Config, now: float) -> float | None:
    try:
        return now - cfg.slate_playlist.stat().st_mtime
    except OSError:
        return None


def write_atomically(path: Path, text: str) -> None:
    """Write then rename, in the same directory, so nginx never sees a half-written flag
    and a crash never leaves one."""
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def serving(cfg: Config, fetch, name: str) -> tuple[int, str]:
    """(status, "slate" | "real" | "?") for one channel's media playlist."""
    code, body = fetch(cfg, f"{cfg.http_path}{name}/main_stream.m3u8")
    if code != 200:
        return code, "?"
    return code, "slate" if "slate_seg" in body else "real"


# --- actions ----------------------------------------------------------------------------

def do_on(cfg: Config, fetch, now, by: str, reason: str, run: str, force: bool,
          out: list) -> list[str]:
    stale_after = 3 * cfg.segment_seconds
    age = slate_age(cfg, now())
    if age is None or age > stale_after:
        what = "has no playlist" if age is None else f"playlist is {age:.0f}s old"
        msg = (f"the slate is not updating ({what}); switching to it would freeze every "
               "display. Check: docker logs relay-slate --tail 30")
        if not force:
            raise Refused(msg)
        out.append(f"WARNING (forced): {msg}")

    if cfg.active.exists():
        out.append(f"Already in maintenance since {_since(cfg)}. Nothing changed.")
        return out

    # A gap left by an interrupted switch-back is 503 on every playlist; entering
    # maintenance must not inherit it.
    unlink(cfg.gap)
    write_atomically(cfg.active, json.dumps({
        "since": datetime.fromtimestamp(now(), timezone.utc).isoformat(),
        "by": by, "reason": reason, "run": run,
    }) + "\n")

    results = {name: serving(cfg, fetch, name) for name in cfg.paths}
    wrong = {n: r for n, r in results.items() if r != (200, "slate")}
    if wrong:
        # Not honoured. Most likely nginx predates the maintenance mounts - the deploy
        # that ships this feature has not run. Put everything back as it was.
        unlink(cfg.active)
        detail = ", ".join(f"{n}={c} {w}" for n, (c, w) in sorted(wrong.items()))
        raise Refused(
            f"set the flag but nginx is not serving the slate for: {detail}. Flag removed; "
            "nothing is in maintenance. Has the deploy that adds the slate run?"
        )
    out.append(f"MAINTENANCE ON: all {len(results)} channels are showing the slate.")
    out.append(f"  The real output stays at https://{cfg.host}/hls-live/<channel>/index.m3u8")
    out.append("  Switch back with: gh workflow run maintenance.yml -f action=off")
    return out


def do_off(cfg: Config, fetch, metrics, sleep, force: bool, out: list) -> list[str]:
    if not cfg.active.exists() and not cfg.gap.exists():
        out.append("Not in maintenance. Nothing changed.")
        return out

    out.append("Producers:")
    lines, not_back = producer_report(cfg, metrics, sleep, float(2 * cfg.segment_seconds))
    out += lines or ["  (no channel is expected to be publishing)"]
    if not_back:
        msg = (f"{len(not_back)} of {len(cfg.expected)} expected publishers are not back: "
               f"{', '.join(not_back)}. Switching now would put them on the wall dark. "
               f"Check them at https://{cfg.host}/hls-live/<channel>/index.m3u8, or pass "
               "force to switch back anyway.")
        if not force:
            if cfg.gap.exists() and not cfg.active.exists():
                # A switch-back that was killed half way: no flag, gap still set, every
                # playlist answering 503. Refusing must not leave it like that - put the
                # wall back on the slate, which is where it was meant to be until now.
                write_atomically(cfg.active, json.dumps({"since": datetime.now(timezone.utc).isoformat(), "by": "maintenance.py",
                                                         "reason": "interrupted switch-back"}) + "\n")
                unlink(cfg.gap)
                msg += " The wall was left answering 503 by an interrupted switch-back; it is back on the slate."
            raise Refused(msg)
        out.append(f"WARNING (forced): {msg}")

    # Gap FIRST, then drop the flag, so there is no instant at which a player is handed a
    # real playlist before the gap - which would defeat the gap entirely.
    if cfg.gap_seconds > 0:
        write_atomically(cfg.gap, "switching back\n")
    unlink(cfg.active)
    if cfg.gap_seconds > 0:
        out.append(f"Playlists answering 503 for {cfg.gap_seconds}s...")
        sleep(cfg.gap_seconds)
        unlink(cfg.gap)

    results = {name: serving(cfg, fetch, name) for name in cfg.expected}
    wrong = {n: r for n, r in results.items() if r != (200, "real")}
    if wrong:
        detail = ", ".join(f"{n}={c} {w}" for n, (c, w) in sorted(wrong.items()))
        raise Refused(f"out of maintenance, but these are not serving a live playlist: {detail}")
    out.append(f"MAINTENANCE OFF: {len(results)} channels back on their producers.")
    return out


def do_status(cfg: Config, fetch, metrics, sleep, now, out: list) -> list[str]:
    if cfg.active.exists():
        out.append(f"MAINTENANCE ON since {_since(cfg)}.")
    elif cfg.gap.exists():
        out.append("Switching back: playlists are answering 503.")
    else:
        out.append("Not in maintenance.")
    age = slate_age(cfg, now())
    out.append("Slate: " + ("no playlist" if age is None else
                            f"playlist {age:.0f}s old" +
                            (" (fresh)" if age <= 3 * cfg.segment_seconds else " (NOT UPDATING)")))
    if cfg.paths:
        code, what = serving(cfg, fetch, cfg.paths[0])
        out.append(f"Viewers of {cfg.paths[0]} are being served: {what} (HTTP {code})")
    out.append("Producers:")
    try:
        lines, _ = producer_report(cfg, metrics, sleep, float(2 * cfg.segment_seconds))
        out += lines or ["  (no channel is expected to be publishing)"]
    except Refused as exc:
        out.append(f"  cannot tell: {exc}")
    return out


def _since(cfg: Config) -> str:
    try:
        meta = json.loads(cfg.active.read_text(encoding="utf-8"))
        who = f" by {meta['by']}" if meta.get("by") else ""
        why = f" ({meta['reason']})" if meta.get("reason") else ""
        return f"{meta.get('since', '?')}{who}{why}"
    except (OSError, ValueError, AttributeError):
        return datetime.fromtimestamp(cfg.active.stat().st_mtime, timezone.utc).isoformat()


# --- entry point ------------------------------------------------------------------------

def main(argv=None, *, fetch=fetch_through_nginx, metrics=metrics_from_watchdog,
         sleep=time.sleep, now=time.time) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("action", choices=["on", "off", "status"])
    ap.add_argument("--env", required=True, help="the department's deploy.env")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--reason", default="")
    args = ap.parse_args(argv)

    lines: list[str] = []
    try:
        cfg = Config(read_env(args.env))
        if not cfg.maintenance_dir.is_dir():
            raise Misconfigured(
                f"{cfg.maintenance_dir} does not exist. relay-apply.sh creates it; the "
                "deploy that adds the maintenance slate has not run on this host."
            )
        by = os.environ.get("GITHUB_ACTOR") or os.environ.get("USER") or "unknown"
        run = ""
        if os.environ.get("GITHUB_RUN_ID"):
            run = (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
                   f"{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/"
                   f"{os.environ['GITHUB_RUN_ID']}")

        if args.action == "on":
            do_on(cfg, fetch, now, by, args.reason, run, args.force, lines)
        elif args.action == "off":
            # A cancelled run mid-gap would leave every playlist answering 503. The
            # watchdog fails on that after ten minutes; this makes it not happen at all.
            def _clear_gap(signum, _frame):
                unlink(cfg.gap)
                print(f"interrupted ({signal.Signals(signum).name}); gap cleared", file=sys.stderr)
                sys.exit(1)
            signal.signal(signal.SIGTERM, _clear_gap)
            signal.signal(signal.SIGINT, _clear_gap)
            do_off(cfg, fetch, metrics, sleep, args.force, lines)
        else:
            do_status(cfg, fetch, metrics, sleep, now, lines)
    except Misconfigured as exc:
        print(f"MISCONFIGURED: {exc}")
        return 2
    except Refused as exc:
        # What happened before the refusal matters - which producers were checked, that a
        # force was used - so it is printed, not dropped.
        if lines:
            print("\n".join(lines))
        print(f"REFUSED: {exc}")
        return 1
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
