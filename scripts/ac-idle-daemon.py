#!/usr/bin/env python3
"""Keep the screen awake while on AC, restore idle blanking/dimming on battery.

GNOME has one idle-delay for both power states, so plugging in cannot by
itself stop the monitor blanking. This watches UPower's OnBattery property
and switches org.gnome.desktop.session idle-delay on the transition: 0
(never blank) on AC, the remembered battery delay on battery. The power
plugin's idle-dim is handled the same way: off on AC, restored on battery.

The delay used on battery is learned -- whatever idle-delay is in effect
when the machine goes onto battery power is remembered as the preference for
battery, so changing it in Settings sticks. Nothing is applied while the
power state is unchanged, so a manual change made while plugged in is never
overridden.
"""

import json
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

UPOWER_BUS = "org.freedesktop.UPower"
UPOWER_PATH = "/org/freedesktop/UPower"

SESSION_SCHEMA = "org.gnome.desktop.session"
IDLE_KEY = "idle-delay"
POWER_SCHEMA = "org.gnome.settings-daemon.plugins.power"
DIM_KEY = "idle-dim"

DEFAULT_BATTERY_DELAY = 300

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "ac-idle",
)
STATE_FILE = os.path.join(STATE_DIR, "state.json")


def log(msg):
    print(msg, flush=True)


class AcIdleDaemon:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.settings = Gio.Settings.new(SESSION_SCHEMA)
        self.power_settings = Gio.Settings.new(POWER_SCHEMA)
        self.battery_delay, self.battery_dim = self.load_state()
        self.on_battery = None

    def load_state(self):
        try:
            with open(STATE_FILE) as f:
                state = json.load(f)
        except (OSError, ValueError):
            state = {}
        try:
            delay = int(state.get("battery_delay", DEFAULT_BATTERY_DELAY))
        except (ValueError, TypeError):
            delay = DEFAULT_BATTERY_DELAY
        if delay <= 0:
            delay = DEFAULT_BATTERY_DELAY
        return delay, bool(state.get("battery_dim", True))

    def save_state(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(
                {"battery_delay": self.battery_delay, "battery_dim": self.battery_dim},
                f,
            )
        os.replace(tmp, STATE_FILE)

    def upower_on_battery(self):
        result = self.bus.call_sync(
            UPOWER_BUS,
            UPOWER_PATH,
            "org.freedesktop.DBus.Properties",
            "Get",
            GLib.Variant("(ss)", (UPOWER_BUS, "OnBattery")),
            GLib.VariantType("(v)"),
            Gio.DBusCallFlags.NONE,
            -1,
            None,
        )
        return result.unpack()[0]

    def apply(self, on_battery, was_on_battery=None):
        current = self.settings.get_uint(IDLE_KEY)
        dim = self.power_settings.get_boolean(DIM_KEY)
        if on_battery:
            if current > 0:
                # Screen already blanks; take that as the battery preference.
                self.battery_delay = current
            else:
                self.settings.set_uint(IDLE_KEY, self.battery_delay)
                log(f"on battery: idle-delay -> {self.battery_delay}s")
            if dim:
                self.battery_dim = True
            elif self.battery_dim:
                self.power_settings.set_boolean(DIM_KEY, True)
                log("on battery: idle-dim -> on")
        else:
            if current > 0:
                self.battery_delay = current
            if was_on_battery or dim:
                # Coming off battery, idle-dim is the battery preference.
                self.battery_dim = dim
            self.settings.set_uint(IDLE_KEY, 0)
            self.power_settings.set_boolean(DIM_KEY, False)
            log("on AC: idle-delay -> never blank, idle-dim -> off")
        self.save_state()

    def on_properties_changed(self, *args):
        changed = args[5].unpack()[1]
        if "OnBattery" not in changed:
            return
        on_battery = bool(changed["OnBattery"])
        if on_battery == self.on_battery:
            return
        was_on_battery = self.on_battery
        self.on_battery = on_battery
        self.apply(on_battery, was_on_battery)

    def run(self):
        self.on_battery = self.upower_on_battery()
        log(f"start: on_battery={self.on_battery}")
        self.apply(self.on_battery)
        self.bus.signal_subscribe(
            UPOWER_BUS,
            "org.freedesktop.DBus.Properties",
            "PropertiesChanged",
            UPOWER_PATH,
            None,
            Gio.DBusSignalFlags.NONE,
            self.on_properties_changed,
        )
        GLib.MainLoop().run()


if __name__ == "__main__":
    AcIdleDaemon().run()
