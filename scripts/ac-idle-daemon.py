#!/usr/bin/env python3
"""Keep the screen awake while on AC, restore idle blanking on battery.

GNOME has one idle-delay for both power states, so plugging in cannot by
itself stop the monitor blanking. This watches UPower's OnBattery property
and switches org.gnome.desktop.session idle-delay on the transition: 0
(never blank) on AC, the remembered battery delay on battery.

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
        self.battery_delay = self.load_battery_delay()
        self.on_battery = None

    def load_battery_delay(self):
        try:
            with open(STATE_FILE) as f:
                value = int(json.load(f)["battery_delay"])
            return value if value > 0 else DEFAULT_BATTERY_DELAY
        except (OSError, ValueError, KeyError, TypeError):
            return DEFAULT_BATTERY_DELAY

    def save_battery_delay(self, value):
        self.battery_delay = value
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"battery_delay": value}, f)
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

    def apply(self, on_battery):
        current = self.settings.get_uint(IDLE_KEY)
        if on_battery:
            if current > 0:
                # Screen already blanks; take that as the battery preference.
                self.save_battery_delay(current)
            else:
                self.settings.set_uint(IDLE_KEY, self.battery_delay)
                log(f"on battery: idle-delay -> {self.battery_delay}s")
        else:
            if current > 0:
                self.save_battery_delay(current)
            self.settings.set_uint(IDLE_KEY, 0)
            log("on AC: idle-delay -> never blank")

    def on_properties_changed(self, *args):
        changed = args[5].unpack()[1]
        if "OnBattery" not in changed:
            return
        on_battery = bool(changed["OnBattery"])
        if on_battery == self.on_battery:
            return
        self.on_battery = on_battery
        self.apply(on_battery)

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
