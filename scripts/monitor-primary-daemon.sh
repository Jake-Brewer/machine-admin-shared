#!/usr/bin/env bash
# Reacts to GNOME/mutter MonitorsChanged (KVM switch, plug/unplug) and keeps
# the external monitor primary+extended. Falls back to mirroring if the
# extended+primary apply doesn't stick after a retry.
set -u

DEST=org.gnome.Mutter.DisplayConfig
PATH_=/org/gnome/Mutter/DisplayConfig
IFACE=org.gnome.Mutter.DisplayConfig
EXTERNAL_CONNECTOR="HDMI-1"
BUILTIN_CONNECTOR="eDP-1"
LOG="$HOME/.cache/monitor-primary-daemon.log"

log() { echo "$(date -Is) $*" >>"$LOG"; }

get_state() {
    gdbus call --session --dest "$DEST" --object-path "$PATH_" \
        --method "$IFACE.GetCurrentState" 2>/dev/null
}

# Extract serial (first field) and whether EXTERNAL_CONNECTOR is present.
apply_layout() {
    local state serial mode_ext mode_builtin
    state=$(get_state) || { log "GetCurrentState failed"; return 1; }
    serial=$(echo "$state" | grep -oP '^\(uint32 \K[0-9]+')

    if ! echo "$state" | grep -q "'$EXTERNAL_CONNECTOR'"; then
        log "external monitor not present, nothing to do"
        return 0
    fi

    mode_ext=$(echo "$state" | grep -oP "\('$EXTERNAL_CONNECTOR'.*?is-preferred.*?\}\)" | grep -oP "^\('[^']*@[0-9.]+'" | head -1 | tr -d "('")
    mode_builtin=$(echo "$state" | grep -oP "\('$BUILTIN_CONNECTOR'.*?is-preferred.*?\}\)" | grep -oP "^\('[^']*@[0-9.]+'" | head -1 | tr -d "('")

    [ -z "$mode_ext" ] && mode_ext="1920x1080@60.000"
    [ -z "$mode_builtin" ] && mode_builtin="1920x1080@60.020"

    log "applying extended layout, external primary (serial=$serial, ext=$mode_ext, builtin=$mode_builtin)"
    gdbus call --session --dest "$DEST" --object-path "$PATH_" \
        --method "$IFACE.ApplyMonitorsConfig" \
        "$serial" 1 \
        "[(0, 0, 1.0, uint32 0, false, [('$BUILTIN_CONNECTOR', '$mode_builtin', @a{sv} {})]), (1920, 0, 1.0, uint32 0, true, [('$EXTERNAL_CONNECTOR', '$mode_ext', @a{sv} {})])]" \
        "@a{sv} {}" >>"$LOG" 2>&1
}

verify_primary() {
    get_state | grep -q "true, \[('$EXTERNAL_CONNECTOR'"
}

fallback_mirror() {
    local state serial mode_ext
    state=$(get_state) || return 1
    serial=$(echo "$state" | grep -oP '^\(uint32 \K[0-9]+')
    mode_ext=$(echo "$state" | grep -oP "\('$EXTERNAL_CONNECTOR'.*?is-preferred.*?\}\)" | grep -oP "^\('[^']*@[0-9.]+'" | head -1 | tr -d "('")
    [ -z "$mode_ext" ] && mode_ext="1920x1080@60.000"
    log "extended+primary didn't stick, falling back to mirror"
    gdbus call --session --dest "$DEST" --object-path "$PATH_" \
        --method "$IFACE.ApplyMonitorsConfig" \
        "$serial" 1 \
        "[(0, 0, 1.0, uint32 0, true, [('$BUILTIN_CONNECTOR', '$mode_ext', @a{sv} {}), ('$EXTERNAL_CONNECTOR', '$mode_ext', @a{sv} {})])]" \
        "@a{sv} {}" >>"$LOG" 2>&1
}

react() {
    sleep 1.5  # let EDID/hotplug settle after a KVM switch
    apply_layout
    sleep 1
    if ! verify_primary; then
        fallback_mirror
    fi
}

log "daemon started, watching for MonitorsChanged"
gdbus monitor --session --dest "$DEST" 2>/dev/null | while read -r line; do
    case "$line" in
        *MonitorsChanged*)
            log "MonitorsChanged event: $line"
            react
            ;;
    esac
done
