# xdotool/VSCode GUI automation notes

Lessons learned driving VSCode + Claude Code via `xdotool` on Ubuntu/GNOME
(snap install). Applies across all repos using this submodule.

## Restart-and-resume an existing window

See `scripts/restart-vscode-resume.sh` header comments for the full recipe
(detached launch, snap-confinement env stripping, settle timing, chat-input
coordinates, Ctrl+Enter to submit).

## Opening a second, independent window + fresh Claude Code session

`code --new-window <dir>` opens a new VSCode instance without killing any
existing one — safe to run alongside a live session.

- **Wrong sidebar panel risk:** a fresh window's default-visible sidebar
  "CHAT" panel can belong to a *different* extension entirely (seen: a
  "GPT-5.2 coding agent" panel with unrelated old sessions). Don't type into
  that. Find the actual Claude Code activity-bar icon (an orange/white
  asterisk/starburst; position varies by VSCode version/layout — screenshot
  and look), click it, click "New session", then click the chat input box
  before typing.
- **Stale geometry:** window position/size can change between measurement
  and click (e.g. the user tiling the window mid-task). Re-run
  `xdotool getwindowgeometry --shell` immediately before every click — never
  reuse a cached value.
- **Coordinate space mismatch:** `import -window` / `gnome-screenshot -w`
  screenshots are captured in *window-relative* pixels, but
  `xdotool mousemove` needs *screen-absolute* coordinates. Always add the
  window's current origin (`$X`/`$Y` from `getwindowgeometry --shell`) to any
  image-derived click target. Forgetting this produces a silent no-op click
  with no error — hard to distinguish from other failures.
- **Eval-quoting breaks on long/multi-line text:** don't build the
  `xdotool type` invocation via a quoted `eval "..."` string when typing a
  long, multi-line prompt with special characters (quotes, apostrophes) —
  the quoting silently fails and nothing gets typed, with no error. Write
  the prompt to a real file and pass it as a plain argument instead:
  `xdotool type --clearmodifiers --delay 6 -- "$(cat prompt.txt)"`.
- **Submit key:** Ctrl+Enter, not plain Enter — consistent with the
  restart/resume script.

## Live-desktop collision risk

Any of this automation clicks/types into the user's real, active screen.
Only run against a window/session guaranteed to be empty and not something
the user might be mid-typing into. Don't over-sample with screenshots for
diagnosis — a handful of well-timed shots beats a dense polling loop.
