#!/usr/bin/env python3
"""Keep an external monitor primary across KVM switches and hotplugs.

GNOME only restores a stored monitors.xml config when the connected set
matches exactly; after a KVM flip mutter often re-enables the built-in panel
as primary. This watches mutter's MonitorsChanged signal and moves the
primary flag back onto an external monitor, preserving the existing
arrangement. If the primary flag refuses to stick it mirrors instead.
"""

import os
import sys
import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

BUS_NAME = "org.gnome.Mutter.DisplayConfig"
OBJ_PATH = "/org/gnome/Mutter/DisplayConfig"
IFACE = "org.gnome.Mutter.DisplayConfig"

METHOD_TEMPORARY = 1
METHOD_PERSISTENT = 2

SETTLE_MS = 2000
MAX_PRIMARY_ATTEMPTS = 2
# Mirroring is the fallback when the primary flag will not stick; set
# MONITOR_DAEMON_MODE=mirror to skip straight to it.
MODE = os.environ.get("MONITOR_DAEMON_MODE", "primary")


def log(msg):
    print(msg, flush=True)


class MonitorDaemon:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.pending = None
        self.attempts = 0

    def call(self, method, params=None):
        return self.bus.call_sync(
            BUS_NAME, OBJ_PATH, IFACE, method, params, None,
            Gio.DBusCallFlags.NONE, 5000, None,
        )

    def get_state(self):
        serial, monitors, logicals, _props = self.call("GetCurrentState").unpack()
        return serial, monitors, logicals

    @staticmethod
    def is_builtin(monitor):
        return bool(monitor[2].get("is-builtin", False))

    @staticmethod
    def current_mode_id(monitor):
        for mode in monitor[1]:
            if mode[6].get("is-current", False):
                return mode[0]
        return monitor[1][0][0] if monitor[1] else None

    @staticmethod
    def mode_size(monitor, mode_id):
        for mode in monitor[1]:
            if mode[0] == mode_id:
                return (mode[1], mode[2])
        return None

    def classify(self, monitors):
        builtin, external = None, []
        for mon in monitors:
            if self.is_builtin(mon):
                builtin = mon
            else:
                external.append(mon)
        return builtin, external

    def external_is_primary(self, monitors, logicals):
        builtin_conn = None
        b, _ = self.classify(monitors)
        if b:
            builtin_conn = b[0][0]
        for lm in logicals:
            if not lm[4]:
                continue
            for spec in lm[5]:
                if spec[0] != builtin_conn:
                    return True
        return False

    def build_primary_fix(self, monitors, logicals, target_conn):
        """Re-emit current logicals with primary moved onto target_conn."""
        by_conn = {m[0][0]: m for m in monitors}
        out = []
        for lm in logicals:
            x, y, scale, transform, _primary, specs, _props = lm
            conns = [s[0] for s in specs]
            is_target = target_conn in conns
            entries = []
            for conn in conns:
                mon = by_conn.get(conn)
                if mon is None:
                    return None
                entries.append((conn, self.current_mode_id(mon), {}))
            out.append((x, y, float(scale), int(transform), is_target, entries))
        return out

    def build_extended(self, builtin, externals):
        out, x = [], 0
        ordered = ([builtin] if builtin else []) + externals
        primary_conn = externals[0][0][0] if externals else None
        for mon in ordered:
            conn = mon[0][0]
            mode_id = self.current_mode_id(mon)
            size = self.mode_size(mon, mode_id)
            if size is None:
                return None
            out.append((x, 0, 1.0, 0, conn == primary_conn, [(conn, mode_id, {})]))
            x += size[0]
        return out

    def build_mirror(self, builtin, externals):
        """One logical monitor containing every output at a shared resolution."""
        mons = ([builtin] if builtin else []) + externals
        common = None
        for mode in mons[0][1]:
            size = (mode[1], mode[2])
            if all(
                any((m[1], m[2]) == size for m in mon[1]) for mon in mons[1:]
            ):
                common = size
                break
        if common is None:
            return None
        entries = []
        for mon in mons:
            pick = next(
                (m[0] for m in mon[1] if (m[1], m[2]) == common), None
            )
            if pick is None:
                return None
            entries.append((mon[0][0], pick, {}))
        return [(0, 0, 1.0, 0, True, entries)]

    def apply(self, serial, logicals, label):
        if not logicals:
            log(f"nothing to apply for {label}")
            return False
        params = GLib.Variant(
            "(uua(iiduba(ssa{sv}))a{sv})",
            (serial, METHOD_PERSISTENT, logicals, {}),
        )
        try:
            self.call("ApplyMonitorsConfig", params)
            log(f"applied: {label}")
            return True
        except GLib.Error as err:
            log(f"apply failed ({label}): {err.message}")
            return False

    def reconcile(self):
        self.pending = None
        try:
            serial, monitors, logicals = self.get_state()
        except GLib.Error as err:
            log(f"GetCurrentState failed: {err.message}")
            return False

        builtin, externals = self.classify(monitors)
        if not externals:
            log("no external monitor present; nothing to do")
            self.attempts = 0
            return False

        if self.external_is_primary(monitors, logicals):
            log("external already primary; no change")
            self.attempts = 0
            return False

        if MODE == "mirror" or self.attempts >= MAX_PRIMARY_ATTEMPTS:
            plan = self.build_mirror(builtin, externals)
            self.attempts = 0
            self.apply(serial, plan, "mirror fallback")
            return False

        self.attempts += 1
        target = externals[0][0][0]
        active = {s[0] for lm in logicals for s in lm[5]}
        if target in active:
            plan = self.build_primary_fix(monitors, logicals, target)
            label = f"primary -> {target} (arrangement preserved)"
        else:
            plan = self.build_extended(builtin, externals)
            label = f"extended layout, primary -> {target}"
        self.apply(serial, plan, label)
        return False

    def schedule(self, delay_ms=SETTLE_MS):
        if self.pending is not None:
            GLib.source_remove(self.pending)
        self.pending = GLib.timeout_add(delay_ms, self.reconcile)

    def on_signal(self, *_args):
        log("MonitorsChanged")
        self.schedule()

    def run(self):
        self.bus.signal_subscribe(
            BUS_NAME, IFACE, "MonitorsChanged", OBJ_PATH, None,
            Gio.DBusSignalFlags.NONE, self.on_signal,
        )
        log(f"daemon started (mode={MODE})")
        self.schedule(delay_ms=500)
        GLib.MainLoop().run()


if __name__ == "__main__":
    if "--once" in sys.argv:
        MonitorDaemon().reconcile()
    else:
        MonitorDaemon().run()
