#!/usr/bin/env python3
"""Remember and restore the monitor layout per connection state.

Each distinct set of connected outputs (KVM attached vs not) gets its own
remembered layout. When the set changes, the layout last used with that set
is restored; while the set is unchanged, any arrangement made in Settings is
learned as the new remembered layout for that state.

Layouts are keyed on connector names rather than EDID, because a KVM often
re-presents a monitor with absent or altered EDID -- which is exactly why
GNOME's own monitors.xml matching fails to restore across a switch.

A state seen for the first time gets a default layout: outputs extended with
an external monitor primary. MONITOR_DAEMON_MODE=mirror makes that default
mirrored instead. Once a state is remembered, the default no longer applies.

Rearranging displays by hand is never overridden. The layout is only ever
applied on an observed change of connection state; a change made while the
connected set is unchanged is recorded as the new preference for that state,
and the layout on screen at startup is adopted rather than replaced.
"""

import json
import os
import sys
import time
import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

BUS_NAME = "org.gnome.Mutter.DisplayConfig"
OBJ_PATH = "/org/gnome/Mutter/DisplayConfig"
IFACE = "org.gnome.Mutter.DisplayConfig"

METHOD_PERSISTENT = 2

SETTLE_MS = 2000
SUPPRESS_LEARN_S = 4.0
MODE = os.environ.get("MONITOR_DAEMON_MODE", "primary")

STATE_DIR = os.environ.get(
    "MONITOR_DAEMON_STATE_DIR",
    os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "monitor-layouts",
    ),
)
STATE_FILE = os.path.join(STATE_DIR, "layouts.json")


def log(msg):
    print(msg, flush=True)


class MonitorDaemon:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.pending = None
        self.last_key = None
        self.suppress_until = 0.0
        self.layouts = self.load()

    # ---------- persistence ----------

    def load(self):
        try:
            with open(STATE_FILE) as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return {}

    def save(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(self.layouts, fh, indent=2, sort_keys=True)
        os.replace(tmp, STATE_FILE)

    # ---------- dbus ----------

    def call(self, method, params=None):
        return self.bus.call_sync(
            BUS_NAME, OBJ_PATH, IFACE, method, params, None,
            Gio.DBusCallFlags.NONE, 5000, None,
        )

    def get_state(self):
        serial, monitors, logicals, _props = self.call("GetCurrentState").unpack()
        return serial, monitors, logicals

    # ---------- model helpers ----------

    @staticmethod
    def is_builtin(monitor):
        return bool(monitor[2].get("is-builtin", False))

    @staticmethod
    def state_key(monitors):
        return "+".join(sorted(m[0][0] for m in monitors))

    @staticmethod
    def current_mode(monitor):
        for mode in monitor[1]:
            if mode[6].get("is-current", False):
                return mode
        for mode in monitor[1]:
            if mode[6].get("is-preferred", False):
                return mode
        return monitor[1][0] if monitor[1] else None

    def classify(self, monitors):
        builtin, external = None, []
        for mon in monitors:
            if self.is_builtin(mon):
                builtin = mon
            else:
                external.append(mon)
        return builtin, external

    def resolve_mode(self, monitor, wanted_id, wanted_size):
        """Pick the stored mode, or the closest survivor if EDID shifted."""
        ids = {m[0] for m in monitor[1]}
        if wanted_id in ids:
            return wanted_id
        if wanted_size:
            same = [m for m in monitor[1]
                    if [m[1], m[2]] == list(wanted_size)]
            if same:
                pref = next((m for m in same if m[6].get("is-preferred")), same[0])
                return pref[0]
        cur = self.current_mode(monitor)
        return cur[0] if cur else None

    # ---------- layout shapes ----------

    def serialize(self, monitors, logicals):
        by_conn = {m[0][0]: m for m in monitors}
        out = []
        for x, y, scale, transform, primary, specs, _props in logicals:
            entries = []
            for spec in specs:
                mon = by_conn.get(spec[0])
                if mon is None:
                    continue
                mode = self.current_mode(mon)
                if mode is None:
                    continue
                entries.append(
                    {"connector": spec[0], "mode": mode[0],
                     "size": [mode[1], mode[2]]}
                )
            if entries:
                out.append({
                    "x": int(x), "y": int(y), "scale": float(scale),
                    "transform": int(transform), "primary": bool(primary),
                    "monitors": entries,
                })
        return out

    def to_apply(self, monitors, layout):
        by_conn = {m[0][0]: m for m in monitors}
        out = []
        for lm in layout:
            entries = []
            for ent in lm["monitors"]:
                mon = by_conn.get(ent["connector"])
                if mon is None:
                    return None
                mode_id = self.resolve_mode(mon, ent.get("mode"), ent.get("size"))
                if mode_id is None:
                    return None
                entries.append((ent["connector"], mode_id, {}))
            if entries:
                out.append((
                    lm["x"], lm["y"], float(lm["scale"]),
                    int(lm["transform"]), bool(lm["primary"]), entries,
                ))
        return out or None

    def default_layout(self, monitors):
        builtin, externals = self.classify(monitors)
        if MODE == "mirror" and externals and builtin:
            return self.mirror_layout(monitors)
        ordered = ([builtin] if builtin else []) + externals
        primary_conn = externals[0][0][0] if externals else (
            builtin[0][0] if builtin else None
        )
        out, x = [], 0
        for mon in ordered:
            mode = self.current_mode(mon)
            if mode is None:
                return None
            conn = mon[0][0]
            out.append({
                "x": x, "y": 0, "scale": 1.0, "transform": 0,
                "primary": conn == primary_conn,
                "monitors": [{"connector": conn, "mode": mode[0],
                              "size": [mode[1], mode[2]]}],
            })
            x += mode[1]
        return out

    def mirror_layout(self, monitors):
        if not monitors:
            return None
        common = None
        for mode in monitors[0][1]:
            size = (mode[1], mode[2])
            if all(any((m[1], m[2]) == size for m in mon[1])
                   for mon in monitors[1:]):
                common = size
                break
        if common is None:
            return None
        entries = []
        for mon in monitors:
            pick = next((m for m in mon[1] if (m[1], m[2]) == common), None)
            if pick is None:
                return None
            entries.append({"connector": mon[0][0], "mode": pick[0],
                            "size": [pick[1], pick[2]]})
        return [{"x": 0, "y": 0, "scale": 1.0, "transform": 0,
                 "primary": True, "monitors": entries}]

    # ---------- actions ----------

    def apply(self, serial, monitors, layout, label):
        payload = self.to_apply(monitors, layout)
        if payload is None:
            log(f"cannot build apply payload for {label}")
            return False
        params = GLib.Variant(
            "(uua(iiduba(ssa{sv}))a{sv})",
            (serial, METHOD_PERSISTENT, payload, {}),
        )
        try:
            self.call("ApplyMonitorsConfig", params)
        except GLib.Error as err:
            log(f"apply failed ({label}): {err.message}")
            return False
        log(f"applied: {label}")
        self.suppress_until = time.monotonic() + SUPPRESS_LEARN_S
        return True

    def reconcile(self):
        self.pending = None
        try:
            serial, monitors, logicals = self.get_state()
        except GLib.Error as err:
            log(f"GetCurrentState failed: {err.message}")
            return False

        if not monitors:
            return False

        key = self.state_key(monitors)
        current = self.serialize(monitors, logicals)
        first_run = self.last_key is None
        changed_state = not first_run and key != self.last_key
        self.last_key = key

        if first_run:
            # Never override at startup: a layout on screen now is either one
            # GNOME restored or one set by hand while this was not running,
            # and those are indistinguishable. Adopt it instead of fighting.
            if current and self.layouts.get(key) != current:
                self.layouts[key] = current
                self.save()
                log(f"[{key}] adopted layout already on screen")
            else:
                log(f"[{key}] startup, matches remembered layout")
            return False

        if changed_state:
            remembered = self.layouts.get(key)
            if remembered:
                if remembered == current:
                    log(f"[{key}] already matches remembered layout")
                else:
                    self.apply(serial, monitors, remembered,
                               f"[{key}] restored remembered layout")
            else:
                default = self.default_layout(monitors)
                if default and default != current:
                    self.apply(serial, monitors, default,
                               f"[{key}] new state, applied default")
                self.layouts[key] = default or current
                self.save()
                log(f"[{key}] remembered as new state")
            return False

        if time.monotonic() < self.suppress_until:
            return False

        if current and self.layouts.get(key) != current:
            self.layouts[key] = current
            self.save()
            log(f"[{key}] learned new layout")
        return False

    def schedule(self, delay_ms=SETTLE_MS):
        if self.pending is not None:
            GLib.source_remove(self.pending)
        self.pending = GLib.timeout_add(delay_ms, self.reconcile)

    def on_signal(self, *_args):
        self.schedule()

    def show(self):
        if not self.layouts:
            log("no layouts remembered yet")
            return
        for key, layout in sorted(self.layouts.items()):
            log(key)
            for lm in layout:
                conns = ", ".join(
                    f"{e['connector']}@{e['size'][0]}x{e['size'][1]}"
                    for e in lm["monitors"]
                )
                star = " *primary" if lm["primary"] else ""
                log(f"  ({lm['x']},{lm['y']}) scale={lm['scale']} {conns}{star}")

    def run(self):
        self.bus.signal_subscribe(
            BUS_NAME, IFACE, "MonitorsChanged", OBJ_PATH, None,
            Gio.DBusSignalFlags.NONE, self.on_signal,
        )
        log(f"daemon started (mode={MODE}, state={STATE_FILE})")
        self.schedule(delay_ms=500)
        GLib.MainLoop().run()


if __name__ == "__main__":
    daemon = MonitorDaemon()
    if "--show" in sys.argv:
        daemon.show()
    elif "--once" in sys.argv:
        daemon.reconcile()
    else:
        daemon.run()
