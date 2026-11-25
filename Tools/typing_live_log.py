#!/usr/bin/env python3
"""Live log of the Murmur iPhone keyboard's touches while the owner types.

The keyboard, with Setup's "Typing diagnostics" switched on, appends one JSON object per line
to `typing-diagnostics.jsonl` in the App Group. This script copies that file off the cabled
iPhone about once a second with `xcrun devicectl` and prints each new event as it arrives, so a
dropped key shows up while typing:

- `hit`: UIKit asked the key plane whether a touch-down at this point is its own. It happens
  before any touch is delivered, so a hit with no `began` after it means a touch reached the
  keyboard's window and was held back or swallowed before the plane saw it (a gesture
  recognizer, most likely).
- `began` / `ended` / `cancelled`: the plane's touch callbacks.
- `insert` / `delete`: what the keyboard typed.
- `gesture`: a state change of a gesture recognizer between the plane and its window.

Ctrl-C prints a summary. With `--expect "the sentence you will type"` it also lines up what
was typed against what was meant and lists the missing and extra characters.

Usage:
    uv run Tools/typing_live_log.py [--device UDID] [--expect TEXT] [--interval 1.0]

Nothing is sent anywhere; the copied file stays in a temporary folder that is deleted on exit.
"""

from __future__ import annotations

import argparse
import difflib
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

GROUP = "group.ai.pivotstudio.murmur"
SOURCE = "Library/Application Support/Murmur/typing-diagnostics.jsonl"
# A touch-down the plane never received within this long after UIKit hit-tested it counts as
# lost before the keyboard.
LOST_AFTER = 0.25

DIM, RED, YELLOW, GREEN, RESET = "\033[2m", "\033[31m", "\033[33m", "\033[32m", "\033[0m"


def physical_device() -> str:
    """The first physical iPhone devicectl knows. It need not be connected yet: each copy
    connects to it, and the loop waits while it is away."""
    with tempfile.TemporaryDirectory() as folder:
        listing = Path(folder) / "devices.json"
        subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--json-output", str(listing)],
            capture_output=True, check=True,
        )
        devices = json.loads(listing.read_text())["result"]["devices"]
    for device in devices:
        hardware = device.get("hardwareProperties", {})
        if hardware.get("deviceType") == "iPhone" and hardware.get("reality") == "physical":
            return hardware["udid"]
    sys.exit("No physical iPhone is paired with this Mac.")


def pull(device: str, destination: Path) -> bool:
    result = subprocess.run(
        [
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", device,
            "--domain-type", "appGroupDataContainer",
            "--domain-identifier", GROUP,
            "--source", SOURCE,
            "--destination", str(destination),
        ],
        capture_output=True, text=True,
    )
    return result.returncode == 0 and destination.exists()


class Tracker:
    """Follows hits, touches and inserts to flag what went missing."""

    def __init__(self) -> None:
        self.start: float | None = None
        self.pending_hits: list[dict] = []   # hits not yet matched by a began
        self.open_touches: dict[int, dict] = {}
        self.counts = {"stall": 0, "window": 0, "hit": 0, "began": 0, "ended": 0, "cancelled": 0, "insert": 0,
                       "lost": 0, "silent": 0, "gesture": 0}
        self.typed: list[str] = []

    def stamp(self, t: float) -> str:
        if self.start is None:
            self.start = t
        return f"{t - self.start:8.3f}"

    def flush_lost(self, now: float) -> None:
        keep = []
        for hit in self.pending_hits:
            if now - hit["t"] > LOST_AFTER:
                self.counts["lost"] += 1
                print(f"{RED}{self.stamp(hit['t'])}  LOST  touch at ({hit['x']:.0f},{hit['y']:.0f}) "
                      f"was hit-tested but never reached the plane{RESET}")
            else:
                keep.append(hit)
        self.pending_hits = keep

    def feed(self, event: dict) -> None:
        kind = event.get("e")
        t = float(event.get("t", 0))
        self.flush_lost(t)
        if kind in self.counts:
            self.counts[kind] += 1
        if kind == "session":
            print(f"{GREEN}--- new diagnostics session {event.get('start', '')} ---{RESET}")
            self.start = t
            # The comparison covers the latest session only.
            self.typed = []
        elif kind == "hit":
            self.pending_hits.append(event)
            print(f"{DIM}{self.stamp(t)}  hit   ({event['x']:.0f},{event['y']:.0f}){RESET}")
        elif kind == "began":
            # The oldest pending hit near this point is this touch's.
            for i, hit in enumerate(self.pending_hits):
                if abs(hit["x"] - event["x"]) < 30 and abs(hit["y"] - event["y"]) < 30:
                    self.pending_hits.pop(i)
                    break
            self.open_touches[event["id"]] = event
            print(f"{self.stamp(t)}  began #{event['id']} on {event.get('key', '?')!r} "
                  f"({event.get('n', 1)} finger(s) down)")
        elif kind in ("ended", "cancelled"):
            began = self.open_touches.pop(event["id"], None)
            held = f"{(t - float(began['t'])) * 1000:.0f} ms" if began else "?"
            colour = YELLOW if kind == "cancelled" else ""
            print(f"{colour}{self.stamp(t)}  {kind} #{event['id']} after {held}{RESET if colour else ''}")
        elif kind == "insert":
            text = event.get("text", "")
            self.typed.append(text)
            print(f"{GREEN}{self.stamp(t)}  typed {text!r}{RESET}")
        elif kind == "delete":
            if self.typed:
                last = self.typed[-1]
                self.typed[-1] = last[:-1]
            print(f"{self.stamp(t)}  delete")
        elif kind == "gesture":
            print(f"{YELLOW}{self.stamp(t)}  gesture {event.get('cls')} → {event.get('state')}{RESET}")
        elif kind == "stall":
            print(f"{RED}{self.stamp(t)}  main thread stalled {event.get('ms', 0):.0f} ms{RESET}")
        elif kind == "window":
            view = event.get("view", "?")
            colour = DIM if view == "KeyPlaneView" else YELLOW
            print(f"{colour}{self.stamp(t)}  window touch on {view} (tap count {event.get('taps')}){RESET}")
        elif kind == "disabled":
            print(f"{YELLOW}{self.stamp(t)}  disabled {event.get('cls')}{RESET}")
        elif kind == "silent":
            print(f"{RED}{self.stamp(t)}  touch #{event.get('id')} reached the plane but typed nothing{RESET}")

    def summary(self, expect: str | None) -> None:
        self.flush_lost(float("inf"))
        c = self.counts
        print()
        print("Summary")
        print(f"  main-thread stalls       {c['stall']}")
        print(f"  touches the window saw   {c['window']}")
        print(f"  hit-tested touch-downs   {c['hit']}")
        print(f"  reached the plane        {c['began']}")
        print(f"  lost before the plane    {c['lost']}")
        print(f"  cancelled                {c['cancelled']}")
        print(f"  inserts                  {c['insert']}")
        print(f"  gesture state changes    {c['gesture']}")
        typed = "".join(self.typed)
        if expect is not None:
            print(f"  expected  {expect!r}")
            print(f"  typed     {typed!r}")
            matcher = difflib.SequenceMatcher(a=expect, b=typed, autojunk=False)
            missing, extra = [], []
            for op, a0, a1, b0, b1 in matcher.get_opcodes():
                if op in ("delete", "replace"):
                    missing.append(expect[a0:a1])
                if op in ("insert", "replace"):
                    extra.append(typed[b0:b1])
            print(f"  missing   {missing}")
            print(f"  extra     {extra}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--device", help="UDID of the iPhone (default: the first cabled one)")
    parser.add_argument("--expect", help="the text you are about to type, to compare against")
    parser.add_argument("--interval", type=float, default=1.0, help="seconds between copies")
    args = parser.parse_args()

    device = args.device or physical_device()
    folder = Path(tempfile.mkdtemp(prefix="murmur-typing-"))
    tracker = Tracker()
    seen = 0
    waiting_since: float | None = None
    print(f"Watching the keyboard on {device}. Switch on Setup → Typing diagnostics, then type.")
    print("Ctrl-C to stop.\n")
    try:
        while True:
            target = folder / "typing-diagnostics.jsonl"
            target.unlink(missing_ok=True)
            if not pull(device, target):
                now = time.monotonic()
                if waiting_since is None or now - waiting_since > 15:
                    waiting_since = now
                    print(f"{DIM}waiting for the phone (cable it and unlock it), or for the log file "
                          f"(switch on Setup → Typing diagnostics, then open the keyboard){RESET}")
            else:
                waiting_since = None
                lines = target.read_text(errors="replace").splitlines()
                if len(lines) < seen:   # the keyboard started a new session and truncated it
                    seen = 0
                for line in lines[seen:]:
                    try:
                        tracker.feed(json.loads(line))
                    except (json.JSONDecodeError, KeyError, ValueError):
                        continue
                seen = len(lines)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        tracker.summary(args.expect)
    finally:
        shutil.rmtree(folder, ignore_errors=True)


if __name__ == "__main__":
    main()
