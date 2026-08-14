#!/usr/bin/env bash
# Generate a distinctive per-project VSCode color theme (minimal tier) and
# register it in theme-registry.tsv so future projects don't collide.
#
# Usage:
#   apply-project-theme.sh <target-repo-dir> [--label "Display Name"] \
#       [--hue N] [--emoji "🟢"] [--registry PATH] [--dry-run]
#
# Without --hue, the hue is seeded deterministically from the project label
# (sha256 hash -> 0-360) so the same project name always lands on roughly the
# same color even across separate runs/registry states — not order-dependent
# on how many other projects were themed first. If that seed hue collides
# (within 18°) with something already in the registry, it's nudged forward in
# small fixed steps until clear. See ../docs/vscode-theming.md (haribo-admin)
# for the design rationale (contrast math, foreground-choice rule, template
# tiers).
#
# This only WRITES <target-repo-dir>/.vscode/settings.json and appends a row
# to the registry — it does not git add/commit/push. Review and commit in the
# target repo yourself (some of these are client/work repos where a cosmetic
# commit needs a deliberate decision, not an automatic one).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$SCRIPT_DIR/../theme-registry.tsv"
TARGET=""
LABEL=""
HUE=""
EMOJI=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --hue) HUE="$2"; shift 2 ;;
    --emoji) EMOJI="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) if [[ -z "$TARGET" ]]; then TARGET="$1"; shift; else echo "Unexpected arg: $1" >&2; exit 1; fi ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: apply-project-theme.sh <target-repo-dir> [--label NAME] [--hue N] [--emoji EMOJI] [--dry-run]" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
[[ -z "$LABEL" ]] && LABEL="$(basename "$TARGET")"
[[ -f "$REGISTRY" ]] || { echo "project	hue	fill	accent	foreground	emoji	tier" > "$REGISTRY"; }

# --- color math (python3: HSL->hex fill/accent, luma-based foreground choice,
#     and golden-angle next-hue picker that avoids existing registry hues) ---
read -r PICKED_HUE FILL ACCENT FOREGROUND PICKED_EMOJI <<EOF
$(python3 - "$REGISTRY" "$HUE" "$EMOJI" "$LABEL" <<'PYEOF'
import sys, colorsys, hashlib

registry_path, hue_arg, emoji_arg, label = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

used_hues = []
with open(registry_path) as f:
    next(f, None)  # header
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            try:
                used_hues.append(float(parts[1]))
            except ValueError:
                pass

def far_enough(h, used, min_gap=18.0):
    for u in used:
        d = abs(h - u) % 360
        d = min(d, 360 - d)
        if d < min_gap:
            return False
    return True

if hue_arg:
    hue = float(hue_arg)
else:
    # Deterministic seed from the project name/label -> same name always
    # lands on ~the same hue regardless of what else has been themed since,
    # instead of depending on registry order. Nudge forward in small fixed
    # steps only if the seed collides with something already registered.
    digest = hashlib.sha256(label.encode("utf-8")).digest()
    hue = int.from_bytes(digest[:4], "big") % 360
    step = 11
    tries = 0
    while not far_enough(hue, used_hues) and tries < 400:
        hue = (hue + step) % 360
        tries += 1

# Fill: muted, dark-ish brand color (matches the S~65-90%/L~25-40% cluster
# observed across existing themes). Accent: bright, reserved for borders/
# text highlights only, never a large fill.
fill_r, fill_g, fill_b = colorsys.hls_to_rgb(hue / 360, 0.30, 0.65)
accent_r, accent_g, accent_b = colorsys.hls_to_rgb(((hue + 6) % 360) / 360, 0.58, 0.95)

def to_hex(r, g, b):
    return "#{:02x}{:02x}{:02x}".format(round(r * 255), round(g * 255), round(b * 255))

fill_hex = to_hex(fill_r, fill_g, fill_b)
accent_hex = to_hex(accent_r, accent_g, accent_b)

# Foreground choice: ITU BT.601 perceptual luma of the FILL color, threshold
# ~120/255 — validated against every theme already in use (see
# docs/vscode-theming.md for the worked examples: red/blue/green/purple fills
# all luma <120 -> light text; the one amber fill at luma 128 -> dark text).
fr, fg, fb = round(fill_r * 255), round(fill_g * 255), round(fill_b * 255)
luma = 0.299 * fr + 0.587 * fg + 0.114 * fb
foreground = "dark" if luma >= 120 else "light"

if emoji_arg:
    picked_emoji = emoji_arg
else:
    # coarse hue->emoji mapping, purely cosmetic (window.title prefix)
    buckets = [
        (15, "🔴"), (45, "🟠"), (70, "🟡"), (170, "🟢"),
        (200, "🩵"), (250, "🔵"), (290, "🟣"), (330, "🩷"), (360, "🔴"),
    ]
    picked_emoji = next(e for limit, e in buckets if hue < limit)

print(hue, fill_hex, accent_hex, foreground, picked_emoji)
PYEOF
)
EOF

if [[ "$FOREGROUND" == "dark" ]]; then
  FG_HEX="#0E0F11"
else
  FG_HEX="#f5f5f5"
fi

SETTINGS_DIR="$TARGET/.vscode"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

read -r -d '' SETTINGS_JSON <<JSONEOF || true
{
  "workbench.colorCustomizations": {
    // Auto-generated distinctive project theme (minimal tier) — see
    // shared/docs/vscode-theming.md for the design rationale. hue=${PICKED_HUE}
    "titleBar.activeBackground": "${FILL}",
    "titleBar.activeForeground": "${FG_HEX}",
    "titleBar.inactiveBackground": "${FILL}",
    "activityBar.background": "${FILL}",
    "activityBar.foreground": "${FG_HEX}",
    "activityBar.activeBorder": "${ACCENT}",
    "statusBar.background": "${FILL}",
    "statusBar.foreground": "${FG_HEX}",
    "statusBarItem.remoteBackground": "${ACCENT}",
    "statusBarItem.remoteForeground": "${FG_HEX}"
  },
  "window.title": "${PICKED_EMOJI} ${LABEL} \${separator} \${activeEditorShort}"
}
JSONEOF

echo "Target:     $TARGET"
echo "Label:      $LABEL"
echo "Hue:        $PICKED_HUE"
echo "Fill:       $FILL"
echo "Accent:     $ACCENT"
echo "Foreground: $FOREGROUND ($FG_HEX)"
echo "Emoji:      $PICKED_EMOJI"
echo

if [[ "$DRY_RUN" == "1" ]]; then
  echo "--- dry run: would write $SETTINGS_FILE ---"
  echo "$SETTINGS_JSON"
  exit 0
fi

if [[ -f "$SETTINGS_FILE" ]] && grep -q "workbench.colorCustomizations" "$SETTINGS_FILE" 2>/dev/null; then
  echo "Refusing to overwrite existing theme at $SETTINGS_FILE (has workbench.colorCustomizations already)." >&2
  echo "Delete/edit it by hand first if you really want to re-theme this project." >&2
  exit 1
fi

mkdir -p "$SETTINGS_DIR"
echo "$SETTINGS_JSON" > "$SETTINGS_FILE"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$LABEL" "$PICKED_HUE" "$FILL" "$ACCENT" "$FOREGROUND" "$PICKED_EMOJI" "minimal" >> "$REGISTRY"

echo "Wrote $SETTINGS_FILE and registered in $REGISTRY."
echo "Review, then commit in the target repo yourself."
