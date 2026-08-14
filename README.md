# machine-admin-shared

Scripts and knowledge shared across personal machine-admin repos (currently
[haribo-admin](https://github.com/Jake-Brewer/haribo-admin) and
[talon-admin](https://github.com/jakez-gh/talon-admin)), included as a git
submodule at `shared/` in each.

## scripts/restart-vscode-resume.sh

Restarts the VSCode snap for a given project directory, then types a resume
message into the Claude Code chat input via `xdotool` so a VSCode restart
doesn't require a human to manually retype anything to continue the
conversation.

```
scripts/restart-vscode-resume.sh <project-dir> [resume-message]
```

Must be launched detached from outside the VSCode process tree — see the
script header for details and known timing/coordinate caveats.

## docs/gui-automation-notes.md

Broader `xdotool`/VSCode GUI-automation gotchas beyond the restart/resume
script — notably how to open a second, independent VSCode window and drive
a fresh Claude Code session in it (wrong-sidebar-panel risk, stale window
geometry, screenshot-relative vs. screen-absolute coordinates, eval-quoting
failures on long prompts).
