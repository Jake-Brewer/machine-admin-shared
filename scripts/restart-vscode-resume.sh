#!/bin/bash
# Restarts the VSCode snap for a given project, then types a resume message
# into the Claude Code chat input so the conversation continues without a
# human needing to type anything.
#
# Usage: restart-vscode-resume.sh <project-dir> [resume-message]
#
# Must be launched detached from OUTSIDE the VSCode process tree (e.g.
# `setsid nohup bash restart-vscode-resume.sh <dir> >log 2>&1 </dev/null & disown`
# from a terminal that isn't a child of VSCode), since killing VSCode would
# otherwise kill whatever launched this script.
#
# Safety: the chat input this script types into is the user's live input
# box. It only clicks/types immediately after a fresh window launch, when
# the box is guaranteed empty — never mid-conversation. If a human is
# already typing into a freshly-launched window at the exact moment this
# fires, keystrokes could still interleave; there's no way to fully rule
# that out for a synthetic-input approach.
set -u

PROJECT_DIR="${1:?usage: restart-vscode-resume.sh <project-dir> [resume-message]}"
RESUME_MESSAGE="${2:-continue}"

STRIP_ENV="env -u SNAP -u SNAP_NAME -u SNAP_REVISION -u SNAP_ARCH -u SNAP_LIBRARY_PATH \
    -u GTK_PATH -u GDK_PIXBUF_MODULE_FILE -u GDK_PIXBUF_MODULEDIR \
    -u GIO_MODULE_DIR -u XDG_DATA_DIRS -u LD_LIBRARY_PATH DISPLAY=:0"

log() { echo "$(date +%s.%N) $*" >> /tmp/vscode_restart_timing.log; }

log "restart_start"

MAIN_PID=$(pgrep -f "^/snap/code/[0-9]+/usr/share/code/code --no-sandbox" | head -1)
if [ -n "$MAIN_PID" ]; then
  kill "$MAIN_PID" 2>/dev/null
  for _ in $(seq 1 20); do
    kill -0 "$MAIN_PID" 2>/dev/null || break
    sleep 0.2
  done
  kill -9 "$MAIN_PID" 2>/dev/null
fi
log "old_process_dead"

sleep 0.5

eval "$STRIP_ENV setsid /snap/bin/code '$PROJECT_DIR' >/tmp/vscode_restart.log 2>&1 < /dev/null &"
disown
log "relaunch_issued"

WIN_ID=""
for _ in $(seq 1 40); do
  WIN_ID=$(eval "$STRIP_ENV xdotool search --name 'Visual Studio Code'" | head -1)
  [ -n "$WIN_ID" ] && break
  sleep 0.3
done
log "window_found"

if [ -z "$WIN_ID" ]; then
  log "window_never_appeared"
  exit 1
fi

# Give the extension host + chat webview time to finish loading before
# clicking — the outer window appears well before the webview is ready.
# Measured (1s-interval screenshot test): webview becomes interactive
# ~5.4s after window_found; 6s left only ~0.6s margin, so use 7s.
sleep 7
log "settle_wait_done"

eval "$STRIP_ENV xdotool windowactivate --sync $WIN_ID"
sleep 0.3

# Chat input box position, measured relative to window origin on a
# 1854x1048 window (offsets ~= absolute 1015,984 minus window origin
# 66,32). Re-derive from live geometry so this survives the window being
# moved or resized. If your VSCode layout differs (different panel sizes,
# no chat tab open, etc.), re-measure these offsets for your setup.
eval "$(eval "$STRIP_ENV xdotool getwindowgeometry --shell $WIN_ID")"
CLICK_X=$((X + 949))
CLICK_Y=$((Y + 952))

eval "$STRIP_ENV xdotool mousemove --sync $CLICK_X $CLICK_Y"
eval "$STRIP_ENV xdotool click 1"
sleep 0.15
eval "$STRIP_ENV xdotool type --delay 20 '$RESUME_MESSAGE'"
sleep 0.1
eval "$STRIP_ENV xdotool key --clearmodifiers ctrl+Return"
log "resume_message_sent"
