#!/usr/bin/env bash
# Generate a distinctive per-project VSCode color theme (minimal tier) and
# register it in theme-registry.tsv so future projects don't collide.
#
# Usage:
#   apply-project-theme.sh <target-repo-dir> [--label "Display Name"] \
#       [--hue N] [--mode light|dark] [--emoji "🟢"] [--registry PATH] [--dry-run]
#
# Without --hue, the hue is seeded deterministically from the project label
# (sha256 hash -> 0-360) so the same project name always lands on roughly the
# same color even across separate runs/registry states — not order-dependent
# on how many other projects were themed first. If that seed hue collides
# (within 18°) with something already in the registry, it's nudged forward in
# small fixed steps until clear.
#
# Without --mode, light-vs-dark base is ALSO seeded from the label hash —
# projects aren't all forced onto the same dark chrome. Maximize the visible
# difference between projects (hue AND light/dark inversion), not just hue,
# while keeping foreground/background contrast correct on both the title/
# activity/status bar fill and the editor/sidebar surface. See
# ../docs/vscode-theming.md (haribo-admin) for the full design rationale
# (contrast math, foreground-choice rule, template tiers).
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
MODE=""
EMOJI=""
DRY_RUN=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --hue) HUE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --emoji) EMOJI="$2"; shift 2 ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    *) if [[ -z "$TARGET" ]]; then TARGET="$1"; shift; else echo "Unexpected arg: $1" >&2; exit 1; fi ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Usage: apply-project-theme.sh <target-repo-dir> [--label NAME] [--hue N] [--emoji EMOJI] [--dry-run]" >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
[[ -z "$LABEL" ]] && LABEL="$(basename "$TARGET")"
[[ -f "$REGISTRY" ]] || { echo "project	hue	fill	accent	foreground	emoji	tier	mode" > "$REGISTRY"; }

# --- color math (python3: HSL->hex fill/accent, luma-based foreground choice,
#     light/dark mode selection, and golden-angle next-hue picker that avoids
#     existing registry hues) ---
read -r PICKED_HUE FILL ACCENT FOREGROUND PICKED_EMOJI PICKED_MODE EDITOR_BG EDITOR_FG SIDEBAR_BG SIDEBAR_FG PANEL_BG SECTION_BG SECTION_FG SIDEBAR_TITLE_FG BASE_FG STATUS_BORDER TAB_BORDER <<EOF
$(python3 - "$REGISTRY" "$HUE" "$EMOJI" "$LABEL" "$MODE" <<'PYEOF'
import sys, colorsys, hashlib

registry_path, hue_arg, emoji_arg, label, mode_arg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

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

# Mode (light vs dark base): a SECOND, independent axis so projects don't
# all end up on the same near-black chrome — maximizes visible difference
# between windows at a glance, not just hue. Seeded from a different slice
# of the same label hash (not the hue bytes) so hue and mode vary
# independently; --mode overrides for a manual pick.
if mode_arg in ("light", "dark"):
    mode = mode_arg
else:
    digest = hashlib.sha256(label.encode("utf-8")).digest()
    mode = "light" if digest[4] % 2 == 0 else "dark"

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
def luma_of(r255, g255, b255):
    return 0.299 * r255 + 0.587 * g255 + 0.114 * b255

fr, fg, fb = round(fill_r * 255), round(fill_g * 255), round(fill_b * 255)
foreground = "dark" if luma_of(fr, fg, fb) >= 120 else "light"

# Editor/sidebar surface colors, derived per mode. Dark mode reuses the
# existing near-black base (as in haribo-admin/zuzzax) tinted faintly toward
# the hue; light mode mirrors work/teters' pattern (warm-ish off-white base,
# pale hue-tinted sidebar, dark neutral text). Contrast is re-verified via
# the same luma rule rather than assumed correct for either mode.
if mode == "dark":
    er, eg, eb = colorsys.hls_to_rgb(hue / 360, 0.05, 0.15)
    sr, sg, sb = colorsys.hls_to_rgb(hue / 360, 0.09, 0.15)
    pr, pg, pb = colorsys.hls_to_rgb(hue / 360, 0.07, 0.15)
    hr, hg, hb = colorsys.hls_to_rgb(hue / 360, 0.11, 0.15)
    editor_fg_hex, sidebar_fg_hex = "#f0f0f0", "#f0f0f0"
else:
    er, eg, eb = colorsys.hls_to_rgb(hue / 360, 0.985, 0.35)
    sr, sg, sb = colorsys.hls_to_rgb(hue / 360, 0.94, 0.35)
    pr, pg, pb = colorsys.hls_to_rgb(hue / 360, 0.90, 0.35)
    hr, hg, hb = colorsys.hls_to_rgb(hue / 360, 0.87, 0.35)
    editor_fg_hex, sidebar_fg_hex = "#1a1a1a", "#1a1a1a"

editor_bg_hex = to_hex(er, eg, eb)
sidebar_bg_hex = to_hex(sr, sg, sb)
panel_bg_hex = to_hex(pr, pg, pb)
section_bg_hex = to_hex(hr, hg, hb)

# Section-header (folder-heading) foreground: same luma rule as the fill's
# foreground, applied to the section-header's OWN background rather than
# assumed from sidebar_fg_hex. Fixes a real bug (2026-08-14, GoogleDrive):
# a near-white pale-pink section-header background paired with the default
# VSCode header foreground read as near-invisible.
sh_luma = luma_of(round(hr * 255), round(hg * 255), round(hb * 255))
section_fg_hex = "#0E0F11" if sh_luma >= 120 else "#f5f5f5"
sb_luma = luma_of(round(sr * 255), round(sg * 255), round(sb * 255))
sidebar_title_fg_hex = "#0E0F11" if sb_luma >= 120 else "#f5f5f5"

# Base "foreground" key: some extension webviews (observed: Claude Code's own
# chat panel) render normal text against OUR computed editor.background, but
# render certain blocks (user-turn bubbles) against their OWN fixed near-black
# background (~#191a1b) regardless of project theme mode — and both read the
# SAME generic `foreground` CSS var, with no separate override available.
# A flat dark value (as used for editor.foreground) reads great on our pale
# light-mode background but is then invisible on that fixed dark bubble; a
# flat light value does the opposite. No single flat gray hits 4.5:1 against
# both when the two backgrounds are this far apart (proven 2026-08-14,
# GoogleDrive regression) — so instead compute the WCAG "maximin" gray: the
# one value whose contrast ratio against the light surface equals its
# contrast ratio against the fixed dark surface, maximizing the worse of the
# two rather than perfecting one at the other's expense. See
# docs/vscode-theming.md for the derivation.
def srgb_to_linear(c255):
    c = c255 / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def rel_luminance(r255, g255, b255):
    r, g, b = srgb_to_linear(r255), srgb_to_linear(g255), srgb_to_linear(b255)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def linear_to_srgb255(lin):
    lin = max(0.0, min(1.0, lin))
    c = lin * 12.92 if lin <= 0.0031308 else 1.055 * (lin ** (1 / 2.4)) - 0.055
    return round(max(0.0, min(1.0, c)) * 255)

FIXED_DARK_BUBBLE_RGB = (25, 26, 27)  # measured, extension-hardcoded, not theme-derived
# VSCode's built-in menu.background default (dark_modern theme, unset by us) —
# a THIRD fixed-dark surface the Claude Code "/" command popup renders this
# same `foreground` var against (its commandLabel/sectionHeader CSS reads
# --app-primary-foreground -> --vscode-foreground, NOT --vscode-menu-foreground,
# despite the extension exposing a separate menu-foreground var it doesn't use
# here — found 2026-08-14 by reading the extension's own minified CSS after
# the first "menu.foreground" fix attempt turned out to target the wrong var).
# Slightly LIGHTER than the bubble, which makes it the binding (harder)
# constraint: a gray balanced only against the bubble reads fine there but
# undershoots against this one. Solve against whichever of the two fixed dark
# surfaces has higher luminance, so contrast against BOTH ends up >= this.
FIXED_MENU_BG_RGB = (0x1F, 0x1F, 0x1F)

if mode == "dark":
    # Editor surface is already near-black here, same ballpark as the fixed
    # dark bubble — no conflict, the existing light foreground works for both.
    base_fg_hex = editor_fg_hex
else:
    l_light = rel_luminance(round(er * 255), round(eg * 255), round(eb * 255))
    l_dark = max(rel_luminance(*FIXED_DARK_BUBBLE_RGB), rel_luminance(*FIXED_MENU_BG_RGB))
    l_mid = ((l_light + 0.05) * (l_dark + 0.05)) ** 0.5 - 0.05
    mid255 = linear_to_srgb255(l_mid)
    base_fg_hex = "#{:02x}{:02x}{:02x}".format(mid255, mid255, mid255)

# Border accent floor (2026-08-14, user request): borders were just the flat
# ACCENT color with no contrast check against whatever background they sit
# on -- fine at some hues, washed out at others. Require each border to hit
# at least HALF the contrast ratio of that region's own text/background
# pair, by nudging the accent's LIGHTNESS (never hue/saturation, so it still
# reads as "the accent color") toward whichever direction increases contrast
# against that specific background, via search.
def contrast_ratio(rgb1, rgb2):
    l1, l2 = rel_luminance(*rgb1), rel_luminance(*rgb2)
    lighter, darker = max(l1, l2), min(l1, l2)
    return (lighter + 0.05) / (darker + 0.05)

def border_for(bg_rgb255, target_ratio, accent_hue, accent_s=0.95, base_l=0.58, steps=40):
    best = None
    for direction in (1, -1):
        bound = 1.0 if direction > 0 else 0.0
        for i in range(steps + 1):
            l = base_l + direction * (i / steps) * abs(bound - base_l)
            l = max(0.0, min(1.0, l))
            r, g, b = colorsys.hls_to_rgb(accent_hue / 360, l, accent_s)
            rgb255 = (round(r * 255), round(g * 255), round(b * 255))
            ratio = contrast_ratio(rgb255, bg_rgb255)
            if ratio >= target_ratio:
                dist = abs(l - base_l)
                if best is None or dist < best[0]:
                    best = (dist, rgb255)
                break
    if best is None:
        # Target unreachable even at the lightness extremes (very close bg
        # luminances) -- fall back to whichever extreme has higher contrast.
        r0, g0, b0 = colorsys.hls_to_rgb(accent_hue / 360, 0.0, accent_s)
        r1, g1, b1 = colorsys.hls_to_rgb(accent_hue / 360, 1.0, accent_s)
        rgb0 = (round(r0 * 255), round(g0 * 255), round(b0 * 255))
        rgb1 = (round(r1 * 255), round(g1 * 255), round(b1 * 255))
        c0, c1 = contrast_ratio(rgb0, bg_rgb255), contrast_ratio(rgb1, bg_rgb255)
        best = (0, rgb0) if c0 >= c1 else (0, rgb1)
    return "#{:02x}{:02x}{:02x}".format(*best[1])

fg_hex_rgb = (14, 15, 17) if foreground == "dark" else (245, 245, 245)
fill_rgb255 = (fr, fg, fb)
status_target = contrast_ratio(fg_hex_rgb, fill_rgb255) / 2
status_border_hex = border_for(fill_rgb255, status_target, (hue + 6) % 360)

editor_fg_rgb = (240, 240, 240) if mode == "dark" else (26, 26, 26)
editor_bg_rgb255 = (round(er * 255), round(eg * 255), round(eb * 255))
editor_target = contrast_ratio(editor_fg_rgb, editor_bg_rgb255) / 2
tab_border_hex = border_for(editor_bg_rgb255, editor_target, (hue + 6) % 360)

if emoji_arg:
    picked_emoji = emoji_arg
else:
    # Independent axis (2026-08-14, distinctiveness pass): previously bucketed
    # from hue, which meant emoji added zero real combinations (it was fully
    # determined by hue -> collided in lockstep with every hue collision).
    # Seeded from a separate hash byte so a hue collision doesn't ALSO produce
    # an emoji collision -- window.title icon + color together, not just
    # color. 24 emoji x 20 guaranteed hue slots x 2 modes = 960 combinations
    # vs. the old 20 x 2 = 40 (see docs/vscode-theming.md for the derivation).
    emoji_pool = [
        "🔴", "🟠", "🟡", "🟢", "🩵", "🔵", "🟣", "🩷",
        "⭐", "🌙", "☀️", "⚡", "🔥", "❄️", "🌊", "🍀",
        "🎯", "🚀", "🔶", "🔷", "🟩", "🟪", "🎲", "🧭",
    ]
    digest = hashlib.sha256(label.encode("utf-8")).digest()
    picked_emoji = emoji_pool[digest[5] % len(emoji_pool)]

print(hue, fill_hex, accent_hex, foreground, picked_emoji, mode,
      editor_bg_hex, editor_fg_hex, sidebar_bg_hex, sidebar_fg_hex,
      panel_bg_hex, section_bg_hex, section_fg_hex, sidebar_title_fg_hex,
      base_fg_hex, status_border_hex, tab_border_hex)
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
    // shared/docs/vscode-theming.md for the design rationale.
    // hue=${PICKED_HUE} mode=${PICKED_MODE}
    // Diff add/remove colors are intentionally NOT set here — they stay on
    // VSCode's default semantic green/red so they read the same across
    // every themed project regardless of brand hue. Don't add
    // diffEditor.*Background overrides to this template.
    "titleBar.activeBackground": "${FILL}",
    "titleBar.activeForeground": "${FG_HEX}",
    "titleBar.inactiveBackground": "${FILL}",
    "activityBar.background": "${FILL}",
    "activityBar.foreground": "${FG_HEX}",
    "activityBar.activeBorder": "${STATUS_BORDER}",
    "statusBar.background": "${FILL}",
    "statusBar.foreground": "${FG_HEX}",
    "statusBar.border": "${STATUS_BORDER}",
    "statusBarItem.remoteBackground": "${ACCENT}",
    "statusBarItem.remoteForeground": "${FG_HEX}",
    "tab.activeBorderTop": "${TAB_BORDER}",
    "foreground": "${BASE_FG}",
    // VSCode's native menu/dropdown chrome (incl. the Claude Code "/" command
    // menu, which reads --vscode-foreground / --vscode-disabledForeground)
    // defaults menu.foreground to the generic "foreground" token above -- but
    // renders it against menu.background, which we never override and which
    // is ALWAYS VSCode's built-in dark_modern #1F1F1F regardless of project
    // mode (no workbench.colorTheme is set anywhere). BASE_FG is tuned for
    // two OTHER backgrounds (editor.background + the fixed dark chat bubble)
    // and measured ~3.9:1 here -- below AA. Fixed constants, not
    // project-derived, since menu.background is itself a fixed constant.
    // (2026-08-14, GoogleDrive: user-reported illegible "/" menu.)
    "menu.foreground": "#e6e6e6",
    "disabledForeground": "#b0b0b0",
    "editor.background": "${EDITOR_BG}",
    "editor.foreground": "${EDITOR_FG}",
    "descriptionForeground": "${EDITOR_FG}",
    "sideBar.background": "${SIDEBAR_BG}",
    "sideBar.foreground": "${SIDEBAR_FG}",
    "sideBarSectionHeader.background": "${SECTION_BG}",
    "sideBarSectionHeader.foreground": "${SECTION_FG}",
    "sideBarTitle.foreground": "${SIDEBAR_TITLE_FG}",
    "panel.background": "${PANEL_BG}",
    "terminal.background": "${PANEL_BG}",
    "terminal.foreground": "${SIDEBAR_FG}"
  },
  "window.title": "${PICKED_EMOJI} ${LABEL} \${separator} \${activeEditorShort}"
}
JSONEOF

echo "Target:     $TARGET"
echo "Label:      $LABEL"
echo "Hue:        $PICKED_HUE"
echo "Mode:       $PICKED_MODE"
echo "Fill:       $FILL"
echo "Accent:     $ACCENT"
echo "Foreground: $FOREGROUND ($FG_HEX)"
echo "Editor bg:  $EDITOR_BG"
echo "Sidebar bg: $SIDEBAR_BG"
echo "Base fg:    $BASE_FG"
echo "Status brd: $STATUS_BORDER"
echo "Tab brd:    $TAB_BORDER"
echo "Emoji:      $PICKED_EMOJI"
echo

if [[ "$DRY_RUN" == "1" ]]; then
  echo "--- dry run: would write $SETTINGS_FILE ---"
  echo "$SETTINGS_JSON"
  exit 0
fi

if [[ -f "$SETTINGS_FILE" ]] && grep -q "workbench.colorCustomizations" "$SETTINGS_FILE" 2>/dev/null; then
  if [[ "$FORCE" == "1" ]] && grep -q "Auto-generated distinctive project theme" "$SETTINGS_FILE" 2>/dev/null; then
    : # marker comment present -> this is our own prior output, safe to regenerate
  else
    echo "Refusing to overwrite existing theme at $SETTINGS_FILE (has workbench.colorCustomizations already)." >&2
    if [[ "$FORCE" == "1" ]]; then
      echo "--force given but no 'Auto-generated distinctive project theme' marker found — this looks hand-authored, not regenerating it." >&2
    else
      echo "Delete/edit it by hand first, or pass --force (only regenerates files carrying the auto-generated marker comment)." >&2
    fi
    exit 1
  fi
fi

mkdir -p "$SETTINGS_DIR"
echo "$SETTINGS_JSON" > "$SETTINGS_FILE"
if grep -qP "^${LABEL//\//\\/}\t" "$REGISTRY" 2>/dev/null; then
  # Regenerating an already-registered project (--force path): replace its
  # row in place instead of appending a duplicate.
  TMP_REGISTRY="$(mktemp)"
  awk -F'\t' -v label="$LABEL" -v row="$LABEL	$PICKED_HUE	$FILL	$ACCENT	$FOREGROUND	$PICKED_EMOJI	minimal	$PICKED_MODE" \
    'BEGIN{OFS="\t"} $1==label{print row; next} {print}' "$REGISTRY" > "$TMP_REGISTRY"
  mv "$TMP_REGISTRY" "$REGISTRY"
else
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$LABEL" "$PICKED_HUE" "$FILL" "$ACCENT" "$FOREGROUND" "$PICKED_EMOJI" "minimal" "$PICKED_MODE" >> "$REGISTRY"
fi

echo "Wrote $SETTINGS_FILE and registered in $REGISTRY."
echo "Review, then commit in the target repo yourself."
