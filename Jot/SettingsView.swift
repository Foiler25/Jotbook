import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum DefaultsKey {
    static let targetFilePath     = "targetFilePath"
    static let openHotkey         = "hotkey"
    static let quitHotkey         = "quitHotkey"
    static let quitHotkeyEnabled  = "quitHotkeyEnabled"
}

enum HotkeyKind {
    case open, quit

    var defaultsKey: String {
        switch self {
        case .open: return DefaultsKey.openHotkey
        case .quit: return DefaultsKey.quitHotkey
        }
    }

    var defaultValue: Hotkey {
        switch self {
        case .open: return Hotkey(keyCode: 45, modifiers: NSEvent.ModifierFlags.option.rawValue, characters: "N")
        case .quit: return Hotkey(keyCode: 12, modifiers: NSEvent.ModifierFlags.option.rawValue, characters: "Q")
        }
    }
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var characters: String

    static func load(_ kind: HotkeyKind) -> Hotkey {
        guard let data = UserDefaults.standard.data(forKey: kind.defaultsKey),
              let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) else {
            return kind.defaultValue
        }
        return decoded
    }

    func save(_ kind: HotkeyKind) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: kind.defaultsKey)
        }
    }

    var displayString: String {
        var s = ""
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += KeyCodeMap.displayName(keyCode: keyCode, fallback: characters)
        return s
    }
}

struct SettingsView: View {
    @AppStorage(DefaultsKey.targetFilePath) private var targetFilePath: String = defaultTargetFilePath()
    @State private var quitHotkeyEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.quitHotkeyEnabled)
    @State private var openHotkey: Hotkey = .load(.open)
    @State private var quitHotkey: Hotkey = .load(.quit)
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Target markdown file") {
                HStack {
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseFile() }
                    Button("Show in Finder") { showInFinder() }
                }
            }
            Section("Open shortcut") {
                HStack {
                    ShortcutRecorderView(hotkey: $openHotkey) { new in
                        new.save(.open)
                        NotificationCenter.default.post(name: .jotHotkeyChanged, object: nil)
                    }
                    .frame(width: 160, height: 24)
                    Text("Click, then press a shortcut")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Quit shortcut") {
                Toggle("Enable global quit shortcut", isOn: $quitHotkeyEnabled)
                    .onChange(of: quitHotkeyEnabled) { newValue in
                        UserDefaults.standard.set(newValue, forKey: DefaultsKey.quitHotkeyEnabled)
                        NotificationCenter.default.post(name: .jotHotkeyChanged, object: nil)
                    }
            }
            Section {
                HStack {
                    ShortcutRecorderView(hotkey: $quitHotkey) { new in
                        new.save(.quit)
                        NotificationCenter.default.post(name: .jotHotkeyChanged, object: nil)
                    }
                    .frame(width: 160, height: 24)
                    Text("Quits Jot from anywhere when enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { toggleLaunchAtLogin($0) }
                ))
                if let e = launchError {
                    Text(e).font(.caption).foregroundStyle(.red)
                }
                Text("Jot will open automatically when you log in. macOS may ask you to approve this in System Settings → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480)
    }

    private var displayPath: String {
        (targetFilePath as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType, .plainText]
        }
        if panel.runModal() == .OK, let url = panel.url {
            targetFilePath = url.path
        }
    }

    private func showInFinder() {
        let url = URL(fileURLWithPath: (targetFilePath as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        launchError = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var hotkey: Hotkey
    var onChange: (Hotkey) -> Void

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.hotkey = hotkey
        view.onCapture = { new in
            self.hotkey = new
            self.onChange(new)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.hotkey = hotkey
    }
}

final class RecorderNSView: NSView {
    var hotkey: Hotkey = HotkeyKind.open.defaultValue { didSet { needsDisplay = true } }
    var onCapture: ((Hotkey) -> Void)?
    private var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let meaningful: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard !flags.intersection(meaningful).isEmpty else { NSSound.beep(); return }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        let new = Hotkey(keyCode: event.keyCode, modifiers: flags.rawValue, characters: chars)
        onCapture?(new)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.separatorColor.setStroke()
        border.stroke()

        let text = isRecording ? "Press shortcut…" : hotkey.displayString
        let color: NSColor = isRecording ? .secondaryLabelColor : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}

enum KeyCodeMap {
    private static let table: [UInt16: String] = [
        0x24: "↩", 0x4C: "↩", 0x35: "⎋", 0x30: "⇥", 0x31: "␣", 0x33: "⌫", 0x75: "⌦",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x74: "⇞", 0x79: "⇟", 0x73: "↖", 0x77: "↘",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12"
    ]

    static func displayName(keyCode: UInt16, fallback: String) -> String {
        if let glyph = table[keyCode] { return glyph }
        if !fallback.isEmpty { return fallback }
        return "Key \(keyCode)"
    }
}
