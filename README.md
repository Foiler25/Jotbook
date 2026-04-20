<div align="center">

<img src="Jot/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Jot" width="160" height="160" />

# Jot

**A lightweight menubar note-taker for macOS.**
Any number of Jotbooks (notebooks), one popover per capture, plain markdown files on disk.

</div>

---

## What is Jot?

Jot lives in your menubar and lets you capture a quick thought without context-switching. Click the icon (or assign a per-jotbook hotkey), type your note, press ⌘↩, and it's timestamped and appended to the active jotbook's markdown file. Run as many Jotbooks as you want, each with its own file and optional dedicated shortcuts. No database, no cloud, no sync conflicts — just plain `.md` files you can open, grep, back up, or sync however you already handle text files.

## Features

### Capture
- **Menubar popover** — click the ✎ icon (or use a per-jotbook hotkey) to open a compact editor.
- **Per-jotbook capture shortcuts** — each jotbook can define its own global hotkey. Pressing one makes that jotbook active and opens the popover in one step. Nothing is set by default for new Jotbooks — assign your own combo.
- **`⌘↩` to save, `Esc` to dismiss** — never touch the mouse.
- **Optional auto-save on close** — toggle in Settings. When on, clicking outside or otherwise dismissing the popover saves your text instead of discarding it. `Esc` still discards.
- **Recent entries above the editor** — toggle in Settings to show the last 3–5 notes above the capture field. Read-only by default, or flip the "allow editing" toggle to fix a typo in an earlier note and have the change written back when the popover closes. `Esc` discards any pending edits.
- **In-popover search (`⌘F`)** — from the popover, `⌘F` swaps in a search field; matching lines from the target file are listed with their timestamps. Click any result to open the file in your default editor. `Esc` returns to capture.
- **Snippet bar** — an optional row of capsule buttons above the editor (default: `TODO:`, `Idea:`, `?:`). Tap one to insert the snippet at the cursor. Fully editable in Settings; disable the bar entirely if you don't want it.
- **Markdown formatting bar** — an optional row of capsule buttons below the editor (Bold, Italic, code, link). Click one to wrap the selected text (or position the cursor between markers if nothing is selected). Also works on recent entries when editing is enabled.
- **Markdown preview window** — optional separate window that renders the target file as styled HTML via `WKWebView`. Auto-refreshes on file change; optional global hotkey to toggle it from anywhere (`⇧⌥P` by default, off until you enable it).
- **Save flash** — the menubar icon briefly turns into a ✓ so you know the write landed.

### Storage
- **Plain markdown** — your notes live in `.md` files you pick (default: `~/Documents/JotBook.md`).
- **Multiple Jotbooks** — manage any number of named Jotbooks, each with its own file path. Switch the active one from the right-click menu's "Switch Jotbook" submenu. Each jotbook can have its own dedicated capture and open-file shortcuts.
- **Smart path defaults** — brand-new installs get `JotBook.md`; existing users keep whatever file they already had. New Jotbooks auto-name their file as `JotBook-{name}.md` and the path follows the name as you rename the Jotbook. You can pin a specific file by explicitly picking one from the Choose… dialog.
- **Folder-or-file picker** — Choose… accepts either a folder (Jot auto-creates/auto-names the file from the jotbook's name) or a specific `.md` file (Jot uses that exact path and stops auto-renaming).
- **Rename warning** — when renaming a jotbook with auto-named path would leave notes behind in the old file, Jot shows a confirmation alert after you click out of the name field, with a "Don't show again" checkbox. An "About rename behavior" link in Settings re-surfaces the explanation so you can read it or un-suppress the alert.
- **Delete confirmation** — removing a jotbook prompts you with three choices: Keep File (remove the jotbook but leave the `.md` file on disk), Delete File (remove both), or Cancel.
- **Timestamped entries** — each note is prepended with `### <timestamp>` and written to the file.
- **Configurable date format** — pick from 4 presets (`yyyy-MM-dd HH:mm`, `yyyy-MM-dd HH:mm:ss`, `MMM d, yyyy h:mm a`, `EEE, MMM d 'at' h:mm a`) with a live preview in Settings.
- **Append or prepend** — by default entries are appended to the end of the file (fast, incremental). Flip the "newest first" toggle in Settings to insert new entries right under the `# Jot Notes` header instead.
- **Daily file rotation** — optional toggle in Settings to route notes into a new file per day. Jot prepends the active Jotbook's base filename to the date (e.g. `JotBook-2026-04-20.md` or `JotBook-Work-2026-04-20.md`). The date pattern is editable; the directory can follow your active Jotbook's folder or be pointed anywhere else.
- **Owned by you** — no accounts, no telemetry, no network calls. The file is yours; sync it with iCloud/Dropbox/Git/whatever.
- **Open in your editor** — the right-click menu's "Open Note File" item (or a per-jotbook hotkey you configure) opens the jotbook's `.md` in whatever app is set as the default for Markdown (Obsidian, Msty Studio, iA Writer, …). With daily rotation on, it opens today's file. The file is created with a `# Jot Notes` header if it doesn't exist yet.

### Settings
- **Jotbook management** — name, pick a file or folder, configure per-jotbook capture and open-file shortcuts. All shortcuts are blank by default; any recorded shortcut is automatically active (Clear resets it).
- **Show in Finder** — jump to each jotbook's file from its row.
- **Optional global quit shortcut** — `⌥Q` by default, off until you enable it.
- **Optional global preview shortcut** — `⇧⌥P` by default, off until you enable it.
- **Launch at login** — uses `SMAppService`, survives macOS updates.

### macOS integration
- **Runs as an accessory** — no dock icon, no app switcher clutter.
- **Accessibility prompt** — on first launch, Jot asks for the permission needed to capture global keystrokes, with a direct link to the right Privacy pane.
- **Right-click the menubar icon** for Open Jot · Open Note File · Show Preview · Settings… · Switch Jotbook (submenu, when you have more than one) · Quit Jot. Key equivalents are shown inline for shortcuts you've enabled.

## Install & run

Jot is built with SwiftUI + AppKit and targets macOS.

1. Open `Jot.xcodeproj` in Xcode.
2. Select the **Jot** scheme.
3. Build and run (`⌘R`).
4. On first launch, grant **Accessibility** access when prompted — this is required for the global hotkey.

## Using it

1. Click the menubar icon (or press a capture hotkey you've set on a jotbook).
2. Type your note.
3. Press `⌘↩` to save → the note is appended to the active jotbook's file with a timestamp. The menubar icon flashes ✓.
4. Press `Esc` to dismiss without saving.

On first launch Jot creates a single "Notes" Jotbook pointing at `~/Documents/JotBook.md` (existing installs keep whatever file they were already using). Open Settings to rename it, add more Jotbooks, and assign whichever global capture/open-file shortcuts you like (none are assigned by default).

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

All originally-planned phases have shipped. 🎉 See the Features section above for what's currently in the app.

---

<div align="center">
  <sub>Built with SwiftUI + AppKit • macOS menubar • no cloud, no telemetry</sub>
</div>
