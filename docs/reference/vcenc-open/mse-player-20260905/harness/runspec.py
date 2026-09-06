"""Shared argument parsing + run timeline for ff_ui.py / cdp_ui.py.

Both drivers take the same command line:

    <script> <url> <video-mode> <seconds> <screenshot.png>
             [--port N] [--probe-at 6,20,40] [--shot-each]
             [--action T:JS] ... [--console-full]

--probe-at   comma-separated seconds at which to evaluate probe.js
             (default: 6 and <seconds>). The run always lasts <seconds>.
--shot-each  screenshot at every probe checkpoint, named <shot>-t<N>s.png,
             instead of one screenshot at the end.
--action     evaluate a JavaScript expression in the page at T seconds and
             print its value. Repeatable. Promises are awaited, so a fetch
             works directly -- this is how a run changes something on the
             device mid-stream, through the same API the UI calls, e.g.

               --action "12:fetch('/api/vm/edid',{method:'POST',
                  headers:{'Content-Type':'application/json'},
                  body:JSON.stringify({edid:'E54-1080P60FPS'})})
                  .then(r=>r.text())"

--console-full  print every console entry in order with its timestamp instead
             of the de-duplicated summary (what you want for a timeline: the
             player logs one report line every 5 s and one line per init
             segment).
"""
import os
import sys


class RunSpec:
    def __init__(self, argv, here, default_port, default_shot):
        self.url = argv[1]
        self.mode = argv[2]
        self.run_for = float(argv[3]) if len(argv) > 3 else 20
        self.shot = os.path.abspath(argv[4]) if len(argv) > 4 else os.path.join(here, default_shot)
        self.port = default_port
        self.shot_each = False
        self.console_full = False
        self.actions = []          # [(seconds, js expression)]
        probe_at = None

        i = 5
        while i < len(argv):
            arg = argv[i]
            if arg == "--port":
                self.port = int(argv[i + 1]); i += 2
            elif arg == "--probe-at":
                probe_at = [float(x) for x in argv[i + 1].split(",") if x.strip()]; i += 2
            elif arg == "--action":
                t, _, expr = argv[i + 1].partition(":")
                self.actions.append((float(t), expr)); i += 2
            elif arg == "--shot-each":
                self.shot_each = True; i += 1
            elif arg == "--console-full":
                self.console_full = True; i += 1
            else:
                raise SystemExit(f"unknown argument {arg!r}\n{__doc__}")

        self.probes = sorted(probe_at if probe_at else [6, self.run_for])

    def timeline(self):
        """[(seconds, kind, payload)] in time order; kind is 'probe' or 'action'."""
        events = [(t, "probe", None) for t in self.probes]
        events += [(t, "action", expr) for t, expr in self.actions]
        events.sort(key=lambda e: e[0])
        return events

    def shot_path(self, seconds):
        if not self.shot_each:
            return self.shot
        base, ext = os.path.splitext(self.shot)
        return f"{base}-t{int(seconds)}s{ext or '.png'}"

    def describe(self):
        return (f"--- run mode={self.mode} for={self.run_for}s probes={self.probes} "
                f"actions={[t for t, _ in self.actions]} port={self.port}")


def print_console(entries, full):
    """entries: [(t_relative, text)]."""
    print("--- console")
    if full:
        for t, c in entries:
            print(f"  [{t:7.2f}] {c}")
        return
    seen = set()
    for t, c in entries:
        if c not in seen:
            seen.add(c)
            print(f"  [{t:7.2f}] {c}")


def usage_guard(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)
