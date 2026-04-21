<div align="center">

<img src="Jotbook/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Jotbook" width="160" height="160" />

# Jotbook

**A lightweight menubar note-taker for macOS.**
Any number of Jotbooks (notebooks), one popover per capture, plain markdown files on disk.

</div>

---

## What is Jotbook?

Jotbook lives in your menubar and lets you capture a quick thought without context-switching. Click the icon (or assign a per-Jotbook hotkey), type your note, press ⌘↩, and it's timestamped and appended to the active Jotbook's markdown file. Run as many Jotbooks as you want, each with its own file and optional dedicated shortcuts. No database, no cloud, no sync conflicts — just plain `.md` files you can open, grep, back up, or sync however you already handle text files.

## Features

### Capture
- **Menubar popover** — click the ✎ icon (or use a per-Jotbook hotkey) to open a compact editor.
- **Per-Jotbook capture shortcuts** — each Jotbook can define its own global hotkey. Pressing one makes that Jotbook active and opens the popover in one step. Nothing is set by default for new Jotbooks — assign your own combo.
- **`⌘↩` to save, `Esc` to dismiss** — never touch the mouse.
- **Optional auto-save on close** — toggle in Settings. When on, clicking outside or otherwise dismissing the popover saves your text instead of discarding it. `Esc` still discards.
- **Recent entries above the editor** — toggle in Settings to show the last 3–5 notes above the capture field. Read-only by default, or flip the "allow editing" toggle to fix a typo in an earlier note and have the change written back when the popover closes. `Esc` discards any pending edits.
- **In-popover search (`⌘F`)** — from the popover, `⌘F` swaps in a search field; matching lines from the target file are listed with their timestamps. Click any result to open the file in your default editor. `Esc` returns to capture.
- **Snippet bar** — an optional row of capsule buttons above the editor (default: `TODO:`, `Idea:`, `?:`). Tap one to insert the snippet at the cursor. Fully editable in Settings; disable the bar entirely if you don't want it.
- **Markdown formatting bar** — an optional row of capsule buttons below the editor (Bold, Italic, code, link). Click one to wrap the selected text (or position the cursor between markers if nothing is selected). Also works on recent entries when editing is enabled.
- **Markdown preview window** — optional separate window that renders the target file as styled HTML via `WKWebView`. Auto-refreshes on file change; optional global hotkey to toggle it from anywhere (`⇧⌥P` by default, off until you enable it).
- **Save flash** — the menubar icon briefly turns into a ✓ so you know the write landed.

### Storage
- **Plain markdown** — your notes live in `.md` files you pick (default: `~/Documents/Jotbook.md`).
- **Multiple Jotbooks** — manage any number of named Jotbooks, each with its own file path. Switch the active one from the right-click menu's "Switch Jotbook" submenu. Each Jotbook can have its own dedicated capture and open-file shortcuts.
- **Smart path defaults** — brand-new installs get `Jotbook.md`; existing users keep whatever file they already had. New Jotbooks auto-name their file as `Jotbook-{name}.md` and the path follows the name as you rename the Jotbook. You can pin a specific file by explicitly picking one from the Choose… dialog.
- **Folder-or-file picker** — Choose… accepts either a folder (Jotbook auto-creates/auto-names the file from the Jotbook's name) or a specific `.md` file (Jotbook uses that exact path and stops auto-renaming).
- **Rename warning** — when renaming a Jotbook with auto-named path would leave notes behind in the old file, Jotbook shows a confirmation alert after you click out of the name field, with a "Don't show again" checkbox. An "About rename behavior" link in Settings re-surfaces the explanation so you can read it or un-suppress the alert.
- **Delete confirmation** — removing a Jotbook prompts you with three choices: Keep File (remove the Jotbook but leave the `.md` file on disk), Delete File (remove both), or Cancel.
- **Timestamped entries** — each note is prepended with `### <timestamp>` and written to the file.
- **Configurable date format** — pick from 4 presets (`yyyy-MM-dd HH:mm`, `yyyy-MM-dd HH:mm:ss`, `MMM d, yyyy h:mm a`, `EEE, MMM d 'at' h:mm a`) with a live preview in Settings.
- **Append or prepend** — by default entries are appended to the end of the file (fast, incremental). Flip the "newest first" toggle in Settings to insert new entries right under the `# Jotbook Notes` header instead.
- **Daily file rotation** — optional toggle in Settings to route notes into a new file per day. Jotbook prepends the active Jotbook's base filename to the date (e.g. `Jotbook-2026-04-20.md` or `Jotbook-Work-2026-04-20.md`). The date pattern is editable; the directory can follow your active Jotbook's folder or be pointed anywhere else.
- **Owned by you** — no accounts, no telemetry, no network calls. The file is yours; sync it with iCloud/Dropbox/Git/whatever.
- **Open in your editor** — the right-click menu's "Open Note File" item (or a per-Jotbook hotkey you configure) opens the Jotbook's `.md` in whatever app is set as the default for Markdown (Obsidian, Msty Studio, iA Writer, …). With daily rotation on, it opens today's file. The file is created with a `# Jotbook Notes` header if it doesn't exist yet.

### Settings
- **Jotbook management** — name, pick a file or folder, configure per-Jotbook capture and open-file shortcuts. All shortcuts are blank by default; any recorded shortcut is automatically active (Clear resets it).
- **Show in Finder** — jump to each Jotbook's file from its row.
- **Optional global quit shortcut** — `⌥Q` by default, off until you enable it.
- **Optional global preview shortcut** — `⇧⌥P` by default, off until you enable it.
- **Launch at login** — uses `SMAppService`, survives macOS updates.

### macOS integration
- **Runs as an accessory** — no dock icon, no app switcher clutter.
- **Right-click the menubar icon** for Open Jotbook · Open Note File · Show Preview · Settings… · Switch Jotbook (submenu, when you have more than one) · Quit Jotbook. Key equivalents are shown inline for shortcuts you've enabled.

## Install

### From a release

Grab the latest `.dmg` from the [Releases](../../releases) page, open it, and drag Jotbook into `/Applications`.

The first launch needs a one-time extra step because the app isn't signed with an Apple Developer ID:

1. Right-click `Jotbook.app` in `/Applications` → **Open**.
2. macOS will block the launch — open **System Settings → Privacy & Security**, scroll to the "*Jotbook* was blocked" notice, and click **Open Anyway**. Authenticate with Touch ID or your password.
3. Click **Open** in the final confirmation dialog.

After that, launch it like any other app. Global hotkeys work out of the box — no permission prompts.

### Build from source

Jotbook is built with SwiftUI + AppKit and targets macOS 13+.

1. Clone the repo.
2. Open `Jotbook.xcodeproj` in Xcode.
3. Select the **Jotbook** scheme.
4. Build and run (`⌘R`).

Because Jotbook is licensed under GPLv3 (see [LICENSE](LICENSE)), you're free to modify and redistribute your own builds — as long as the source for those builds is made available under the same license.

## Using it

1. Click the menubar icon (or press a capture hotkey you've set on a Jotbook).
2. Type your note.
3. Press `⌘↩` to save → the note is appended to the active Jotbook's file with a timestamp. The menubar icon flashes ✓.
4. Press `Esc` to dismiss without saving.

On first launch Jotbook creates a single "Notes" Jotbook pointing at `~/Documents/Jotbook.md` (existing installs keep whatever file they were already using). Open Settings to rename it, add more Jotbooks, and assign whichever global capture/open-file shortcuts you like (none are assigned by default).

Your file looks like this:

```markdown
# Jotbook Notes

### 2026-04-19 14:32
Remember to refactor the hotkey monitor to handle app activation edge cases.

### 2026-04-19 15:07
Book idea: a noir set entirely inside a compiler.
```

---

<div align="center">
  <img src="Jotbook/Assets.xcassets/AppIcon.appiconset/icon_128.png" alt="Jotbook" width="80" height="80" />
</div>

## Roadmap

All originally-planned phases have shipped. 🎉 See the Features section above for what's currently in the app.

---

## License

Jotbook is licensed under the [GNU General Public License v3.0](LICENSE).

---

## Support

Jotbook is free and always will be. If it's saved you time, made your day better, or helped you at work like it has for me, you can throw me a tip to say thanks at [Paypal](https://paypal.me/barbiebutt) — no pressure, truly appreciated either way. If you'd rather just say thanks without a payment, you can reach me at [@foiler25](https://twitter.com/foiler25) on Twitter.

---

## Feedback & contributions

Have an idea to make Jotbook better, or run into a bug? Feel free to open an [issue](../../issues) or start a [discussion](../../discussions) on GitHub — suggestions and bug reports are always welcome.

---

<div align="center">
  <sub>Built with SwiftUI + AppKit • macOS menubar • no cloud, no telemetry</sub>
</div>
