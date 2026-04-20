import SwiftUI
import AppKit
import ApplicationServices
import Combine
import ServiceManagement

final class NoteEditorState: ObservableObject {
    @Published var text = ""
}

struct NoteEditorView: View {
    @ObservedObject var state: NoteEditorState
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $state.text)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(width: 320, height: 140)
            .focused($isFocused)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isFocused = true
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var rightClickMenu: NSMenu!
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var popoverKeyMonitor: Any?
    private var originalStatusImage: NSImage?
    private var saveFlashToken = 0
    private let editorState = NoteEditorState()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        configurePopover()
        buildRightClickMenu()
        registerHotkeyMonitors()
        promptForAccessibilityIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyChanged),
            name: .jotHotkeyChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appBecameActive() {
        registerHotkeyMonitors()
    }

    private func promptForAccessibilityIfNeeded() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        guard !trusted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Jot needs Accessibility access"
            alert.informativeText = "macOS requires Accessibility permission for the global keyboard shortcut (⌥N) to work. Open System Settings → Privacy & Security → Accessibility and enable Jot."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Jot")
        image?.isTemplate = true
        originalStatusImage = image
        if let button = statusItem.button {
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 140)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: NoteEditorView(state: editorState)
        )
    }

    private func buildRightClickMenu() {
        let menu = NSMenu()

        let openHK = Hotkey.load(.open)
        let open = NSMenuItem(title: "Open Jot", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        applyHotkeyToMenuItem(openHK, item: open)
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Jot", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        if UserDefaults.standard.bool(forKey: DefaultsKey.quitHotkeyEnabled) {
            applyHotkeyToMenuItem(Hotkey.load(.quit), item: quitItem)
        }
        menu.addItem(quitItem)

        rightClickMenu = menu
    }

    private func applyHotkeyToMenuItem(_ hk: Hotkey, item: NSMenuItem) {
        let chars = hk.characters.lowercased()
        guard !chars.isEmpty, chars.count == 1 else { return }
        item.keyEquivalent = chars
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: hk.modifiers)
            .intersection(.deviceIndependentFlagsMask)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            statusItem.menu = rightClickMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc private func openFromMenu() {
        togglePopover()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Jot Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        editorState.text = ""
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        installPopoverKeyMonitor()
    }

    private func installPopoverKeyMonitor() {
        if let existing = popoverKeyMonitor {
            NSEvent.removeMonitor(existing)
            popoverKeyMonitor = nil
        }
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                self.save()
                return nil
            }
            if event.keyCode == 53 {
                self.popover.performClose(nil)
                return nil
            }
            return event
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = popoverKeyMonitor {
            NSEvent.removeMonitor(m)
            popoverKeyMonitor = nil
        }
    }

    private func save() {
        let trimmed = editorState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            popover.performClose(nil)
            return
        }
        do {
            try NoteAppender.append(trimmed)
            editorState.text = ""
            popover.performClose(nil)
            flashSaveCheckmark()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't save note"
            alert.runModal()
        }
    }

    private func flashSaveCheckmark() {
        saveFlashToken &+= 1
        let token = saveFlashToken
        statusItem.button?.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Saved"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.saveFlashToken == token else { return }
            self.statusItem.button?.image = self.originalStatusImage
        }
    }

    private func registerHotkeyMonitors() {
        removeHotkeyMonitors()
        let bindings = currentBindings()
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if let action = self.matchedAction(for: event, in: bindings) {
                DispatchQueue.main.async { action() }
            }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let action = self.matchedAction(for: event, in: bindings) {
                action()
                return nil
            }
            return event
        }
    }

    private func currentBindings() -> [(Hotkey, () -> Void)] {
        var bindings: [(Hotkey, () -> Void)] = []
        bindings.append((Hotkey.load(.open), { [weak self] in self?.togglePopover() }))
        if UserDefaults.standard.bool(forKey: DefaultsKey.quitHotkeyEnabled) {
            bindings.append((Hotkey.load(.quit), { NSApp.terminate(nil) }))
        }
        return bindings
    }

    private func matchedAction(for event: NSEvent, in bindings: [(Hotkey, () -> Void)]) -> (() -> Void)? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for (hk, action) in bindings {
            let target = NSEvent.ModifierFlags(rawValue: hk.modifiers)
                .intersection(.deviceIndependentFlagsMask)
            if event.keyCode == hk.keyCode && flags == target {
                return action
            }
        }
        return nil
    }

    private func removeHotkeyMonitors() {
        if let g = globalHotkeyMonitor { NSEvent.removeMonitor(g); globalHotkeyMonitor = nil }
        if let l = localHotkeyMonitor { NSEvent.removeMonitor(l); localHotkeyMonitor = nil }
    }

    @objc private func hotkeyChanged() {
        registerHotkeyMonitors()
        buildRightClickMenu()
    }
}

enum NoteAppender {
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func append(_ text: String) throws {
        let path = UserDefaults.standard.string(forKey: DefaultsKey.targetFilePath)
            ?? defaultTargetFilePath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("# Jot Notes\n\n".utf8).write(to: url)
        }
        let stamp = stampFormatter.string(from: Date())
        let entry = "\n### \(stamp)\n\(text)\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(entry.utf8))
    }
}

func defaultTargetFilePath() -> String {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    return docs.appendingPathComponent("JotNotes.md").path
}

extension Notification.Name {
    static let jotHotkeyChanged = Notification.Name("JotHotkeyChanged")
}
