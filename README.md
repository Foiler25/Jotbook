<div align="center">

<img src="Jot/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Jot" width="160" height="160" />

# Jot

**A lightweight menubar note-taker for macOS.**
One hotkey, one popover, one markdown file.

</div>

---

## What is Jot?

Jot lives in your menubar and lets you capture a quick thought without context-switching. Hit a global shortcut from anywhere, type your note, press ⌘↩, and it's timestamped and appended to a markdown file of your choosing. That's it — no database, no cloud, no sync conflicts. Just a plain `.md` file you can open, grep, back up, or sync however you already handle text files.

## Features

### Capture
- **Menubar popover** — click the ✎ icon (or use the hotkey) to open a compact editor.
- **Global open shortcut** — `⌥N` by default, configurable from Settings. Works from any app.
- **`⌘↩` to save, `Esc` to dismiss** — never touch the mouse.
- **Transient popover** — click outside and it closes without saving (for now — auto-save on close is on the roadmap below).
- **Save flash** — the menubar icon briefly turns into a ✓ so you know the write landed.

### Storage
- **Plain markdown** — your notes live in a single `.md` file you pick (default: `~/Documents/JotNotes.md`).
- **Timestamped entries** — each note is prepended with `### yyyy-MM-dd HH:mm` and appended to the end of the file.
- **Owned by you** — no accounts, no telemetry, no network calls. The file is yours; sync it with iCloud/Dropbox/Git/whatever.

### Settings
- **Target file picker** — choose any `.md` or `.txt` file, or let Jot create one for you.
- **Show in Finder** — jump to the target file from Settings.
- **Configurable open shortcut** — click the recorder and press the key combo you want.
- **Optional global quit shortcut** — `⌥Q` by default, off until you enable it.
- **Launch at login** — uses `SMAppService`, survives macOS updates.

### macOS integration
- **Runs as an accessory** — no dock icon, no app switcher clutter.
- **Accessibility prompt** — on first launch, Jot asks for the permission needed to capture global keystrokes, with a direct link to the right Privacy pane.
- **Right-click the menubar icon** for Open Jot · Settings… · Quit Jot (with key equivalents shown inline).

## Install & run

Jot is built with SwiftUI + AppKit and targets macOS.

1. Open `Jot.xcodeproj` in Xcode.
2. Select the **Jot** scheme.
3. Build and run (`⌘R`).
4. On first launch, grant **Accessibility** access when prompted — this is required for the global hotkey.

## Using it

1. Press `⌥N` (or click the menubar icon).
2. Type your note.
3. Press `⌘↩` to save → the note is appended to your target file with a timestamp. The menubar icon flashes ✓.
4. Press `Esc` to dismiss without saving.

Your file looks like this:

```markdown
# Jot Notes

### 2026-04-19 14:32
Remember to refactor the hotkey monitor to handle app activation edge cases.

### 2026-04-19 15:07
Book idea: a noir set entirely inside a compiler.
```

---

<div align="center">
  <img src="Jot/Assets.xcassets/AppIcon.appiconset/icon_128.png" alt="Jot" width="80" height="80" />
</div>

## Roadmap

Jot is intentionally small, but a richer set of features is planned. Each phase below ships independently; phases 1–8 are additive on the current single-file model, and phase 9 is a larger refactor that layers multiple notebooks on top.

### Phase 1 — Open Note File (`⌥⌘N`)
A dedicated shortcut and menu item to open the target `.md` in its default editor (Obsidian, Msty Studio, iA Writer, etc.), creating it if it doesn't exist yet.

### Phase 2 — Date format & newest-first append
Pick a timestamp format from a preset list (`yyyy-MM-dd HH:mm`, `MMM d, yyyy h:mm a`, `EEE, MMM d 'at' h:mm a`, …) with a live preview. Optional "newest first" toggle to insert new entries at the top of the file instead of appending.

### Phase 3 — Auto-save on close
Optionally persist whatever you typed when the popover is dismissed (click-outside, app switch), instead of discarding. `Esc` still discards.

### Phase 4 — Daily file rotation
Split notes across per-day files (e.g., `2026-04-19.md`) in a directory of your choice. Format is configurable, so per-hour or per-week layouts work too.

### Phase 5 — Tag prefixes
A row of one-click capsule buttons above the editor (`TODO:`, `Idea:`, `?:`…). Tap to insert at the cursor. Fully editable list in Settings.

### Phase 6 — Recent entries in the popover
Show the last 3–5 entries above the editor for quick context. Read-only by default, with an optional "allow editing" mode that writes changes back to the file on close.

### Phase 7 — In-popover search (`⌘F`)
Search your note file from inside the popover. Matching lines appear with their timestamps; click a result to open the file in your external editor.

### Phase 8 — Markdown preview window
A separate read-only window that renders your notes as styled HTML via `WKWebView`, with optional auto-refresh when the file changes on disk.

### Phase 9 — Multiple notebooks
Maintain several named targets (Work / Personal / Ideas), each with its own path and optional dedicated capture and open-file shortcuts. Switch the active notebook from the right-click menu; per-notebook hotkeys route captures to a specific file without switching. This is the largest change on the list because every earlier feature needs to resolve its path through the active notebook — so it's intentionally last.

---

<div align="center">
  <sub>Built with SwiftUI + AppKit • macOS menubar • no cloud, no telemetry</sub>
</div>
