import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum DefaultsKey {
    static let targetFilePath     = "targetFilePath"
    static let openHotkey         = "hotkey"
    static let quitHotkey         = "quitHotkey"
    static let quitHotkeyEnabled  = "quitHotkeyEnabled"
    static let openFileHotkey     = "openFileHotkey"
    static let dateFormat         = "dateFormat"
    static let newestFirst        = "newestFirst"
    static let autoSaveOnClose    = "autoSaveOnClose"
    static let dailyRotation          = "dailyRotation"
    static let dailyRotationFormat    = "dailyRotationFormat"
    static let dailyRotationDirectory = "dailyRotationDirectory"
    static let tagPrefixes            = "tagPrefixes"
    static let showPrefixBar          = "showPrefixBar"
    static let showRecentInPopover    = "showRecentInPopover"
    static let popoverRecentCount     = "popoverRecentCount"
    static let popoverRecentEditable  = "popoverRecentEditable"
    static let previewHotkey          = "previewHotkey"
    static let previewHotkeyEnabled   = "previewHotkeyEnabled"
    static let previewAutoRefresh     = "previewAutoRefresh"
    static let showFormattingBar      = "showFormattingBar"
    static let jotbooks              = "notebooks"
    static let activeJotbookID       = "activeNotebookID"
    static let orphanWarningSuppressed = "orphanWarningSuppressed"
    static let legacyFilePathMigrated  = "legacyFilePathMigrated"
}

struct Jotbook: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var path: String
    /// Nil is treated as "true" for backward compatibility with jotbooks
    /// serialized before this flag existed. `true` means the user explicitly
    /// picked a file for this Jotbook (so its path does NOT auto-follow the
    /// name). `false` means the path is derived from the Jotbook's name and
    /// parent directory.
    var pathIsExplicit: Bool?
    var captureHotkey: Hotkey
    var captureHotkeyEnabled: Bool
    var openFileHotkey: Hotkey
    var openFileHotkeyEnabled: Bool

    var isPathExplicit: Bool { pathIsExplicit ?? true }
}

enum Jotbooks {
    static func all() -> [Jotbook] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.jotbooks),
              let decoded = try? JSONDecoder().decode([Jotbook].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ jotbooks: [Jotbook]) {
        if let data = try? JSONEncoder().encode(jotbooks) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.jotbooks)
            NotificationCenter.default.post(name: .jotJotbooksChanged, object: nil)
        }
    }

    static func active() -> Jotbook? {
        let list = all()
        guard !list.isEmpty else { return nil }
        if let idString = UserDefaults.standard.string(forKey: DefaultsKey.activeJotbookID),
           let id = UUID(uuidString: idString),
           let match = list.first(where: { $0.id == id }) {
            return match
        }
        return list.first
    }

    static func setActive(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: DefaultsKey.activeJotbookID)
        NotificationCenter.default.post(name: .jotJotbooksChanged, object: nil)
    }

    /// If the jotbook list is empty, create a default "Notes" jotbook. The first ever
    /// empty-state seen also honors any legacy `targetFilePath` so users coming from
    /// pre-multi-jotbook versions don't lose their existing file. After that first
    /// migration, subsequent empty states (e.g. user deleted every jotbook) fall back
    /// to the standard default file path.
    static func ensureAtLeastOne() {
        guard all().isEmpty else { return }

        let defaults = UserDefaults.standard
        let alreadyMigrated = defaults.bool(forKey: DefaultsKey.legacyFilePathMigrated)
        let legacyPath = defaults.string(forKey: DefaultsKey.targetFilePath)

        let path: String
        if !alreadyMigrated, let legacy = legacyPath, !legacy.isEmpty {
            path = legacy
            defaults.set(true, forKey: DefaultsKey.legacyFilePathMigrated)
        } else {
            path = defaultTargetFilePath()
        }

        let first = Jotbook(
            id: UUID(),
            name: "Notes",
            path: path,
            pathIsExplicit: true,
            captureHotkey: HotkeyKind.open.defaultValue,        // ⌥N
            captureHotkeyEnabled: true,
            openFileHotkey: HotkeyKind.openFile.defaultValue,   // ⇧⌥N
            openFileHotkeyEnabled: true
        )
        save([first])
        setActive(first.id)
    }
}

extension Notification.Name {
    static let jotJotbooksChanged = Notification.Name("JotJotbooksChanged")
}

enum TagPrefixDefaults {
    static let list: [String] = ["TODO: ", "Idea: ", "?: "]

    static func load() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.tagPrefixes),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return list
        }
        return decoded
    }

    static func save(_ prefixes: [String]) {
        if let data = try? JSONEncoder().encode(prefixes) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.tagPrefixes)
            NotificationCenter.default.post(name: .jotTagPrefixesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let jotTagPrefixesChanged = Notification.Name("JotTagPrefixesChanged")
}

enum DateFormatPreset: String, CaseIterable, Identifiable {
    case ymdHm   = "yyyy-MM-dd HH:mm"
    case ymdHms  = "yyyy-MM-dd HH:mm:ss"
    case medHma  = "MMM d, yyyy h:mm a"
    case eMedHma = "EEE, MMM d 'at' h:mm a"

    var id: String { rawValue }

    var label: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = rawValue
        let sample = DateComponents(calendar: Calendar(identifier: .gregorian),
                                    year: 2026, month: 4, day: 19,
                                    hour: 14, minute: 32, second: 5).date ?? Date()
        return f.string(from: sample)
    }
}

enum HotkeyKind {
    case open, quit, openFile, preview

    var defaultsKey: String {
        switch self {
        case .open:     return DefaultsKey.openHotkey
        case .quit:     return DefaultsKey.quitHotkey
        case .openFile: return DefaultsKey.openFileHotkey
        case .preview:  return DefaultsKey.previewHotkey
        }
    }

    var defaultValue: Hotkey {
        switch self {
        case .open: return Hotkey(keyCode: 45, modifiers: NSEvent.ModifierFlags.option.rawValue, characters: "N")
        case .quit: return Hotkey(keyCode: 12, modifiers: NSEvent.ModifierFlags.option.rawValue, characters: "Q")
        case .openFile: return Hotkey(
            keyCode: 45,
            modifiers: NSEvent.ModifierFlags([.shift, .option]).rawValue,
            characters: "N"
        )
        case .preview: return Hotkey(
            keyCode: 35,  // P
            modifiers: NSEvent.ModifierFlags([.shift, .option]).rawValue,
            characters: "P"
        )
        }
    }
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var characters: String

    static let empty = Hotkey(keyCode: 0, modifiers: 0, characters: "")
    var isEmpty: Bool { keyCode == 0 && modifiers == 0 && characters.isEmpty }

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
    @AppStorage(DefaultsKey.dateFormat) private var dateFormat: String = DateFormatPreset.ymdHm.rawValue
    @State private var jotbooks: [Jotbook] = Jotbooks.all()
    @State private var activeJotbookID: String = Jotbooks.active()?.id.uuidString ?? ""
    @State private var pendingOrphanOldPath: String? = nil
    @FocusState private var focusedNameJotbookID: UUID?
    @State private var newestFirst: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.newestFirst)
    @State private var autoSaveOnClose: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.autoSaveOnClose)
    @State private var dailyRotation: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.dailyRotation)
    @AppStorage(DefaultsKey.dailyRotationFormat) private var dailyRotationFormat: String = "yyyy-MM-dd"
    @AppStorage(DefaultsKey.dailyRotationDirectory) private var dailyRotationDirectory: String = ""
    @AppStorage(DefaultsKey.showPrefixBar) private var showPrefixBar: Bool = true
    @State private var tagPrefixes: [String] = TagPrefixDefaults.load()
    @AppStorage(DefaultsKey.showRecentInPopover) private var showRecentInPopover: Bool = false
    @AppStorage(DefaultsKey.popoverRecentCount) private var popoverRecentCount: Int = 3
    @AppStorage(DefaultsKey.popoverRecentEditable) private var popoverRecentEditable: Bool = false
    @State private var previewHotkeyEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.previewHotkeyEnabled)
    @State private var previewHotkey: Hotkey = .load(.preview)
    @AppStorage(DefaultsKey.previewAutoRefresh) private var previewAutoRefresh: Bool = true
    @AppStorage(DefaultsKey.showFormattingBar) private var showFormattingBar: Bool = true
    @State private var quitHotkeyEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.quitHotkeyEnabled)
    @State private var quitHotkey: Hotkey = .load(.quit)
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn
                .frame(width: 420)
            Divider()
            rightColumn
                .frame(width: 420)
        }
        .frame(minHeight: 720)
        .onReceive(NotificationCenter.default.publisher(for: .jotJotbooksChanged)) { _ in
            jotbooks = Jotbooks.all()
            if let active = Jotbooks.active() {
                activeJotbookID = active.id.uuidString
            }
        }
        .onChange(of: focusedNameJotbookID) { _ in
            flushPendingOrphanWarningIfNeeded()
        }
    }

    private func flushPendingOrphanWarningIfNeeded() {
        guard let oldPath = pendingOrphanOldPath else { return }
        pendingOrphanOldPath = nil
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.orphanWarningSuppressed) else { return }
        DispatchQueue.main.async {
            showOrphanAlert(orphanedPath: oldPath)
        }
    }

    private func showOrphanAlert(orphanedPath: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Jotbook target updated"
        if let orphanedPath {
            alert.informativeText = "The file at \((orphanedPath as NSString).abbreviatingWithTildeInPath) still contains your previous notes. Move them manually if you want them to appear in the renamed Jotbook."
        } else {
            alert.informativeText = "When you rename a Jotbook whose path is auto-generated from its name (e.g. JotBook-{name}.md), the target file changes to match the new name. Existing notes remain in the old file on disk — move them manually if you want them in the renamed Jotbook. A Jotbook whose file was picked explicitly does not auto-rename."
        }
        alert.addButton(withTitle: "OK")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this warning again"
        alert.suppressionButton?.state = UserDefaults.standard.bool(forKey: DefaultsKey.orphanWarningSuppressed) ? .on : .off
        alert.runModal()
        let suppressed = (alert.suppressionButton?.state ?? .off) == .on
        UserDefaults.standard.set(suppressed, forKey: DefaultsKey.orphanWarningSuppressed)
    }

    private var leftColumn: some View {
        Form {
            Section("Jotbooks") {
                Picker("Active Jotbook", selection: $activeJotbookID) {
                    ForEach(jotbooks) { nb in
                        Text(nb.name.isEmpty ? "(unnamed)" : nb.name).tag(nb.id.uuidString)
                    }
                }
                .onChange(of: activeJotbookID) { newValue in
                    if let uuid = UUID(uuidString: newValue) {
                        Jotbooks.setActive(uuid)
                    }
                }
            }
            ForEach($jotbooks) { jotbookBinding in
                jotbookSections(for: jotbookBinding)
            }
            Section {
                HStack {
                    Button("Add Jotbook") { addJotbook() }
                    Spacer()
                    Button("About rename behavior") { showOrphanAlert() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Section("Note format") {
                Picker("Date format", selection: $dateFormat) {
                    ForEach(DateFormatPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                Text("Preview: \(formattedNow)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Insert new entries at top of file", isOn: $newestFirst)
                    .onChange(of: newestFirst) { newValue in
                        UserDefaults.standard.set(newValue, forKey: DefaultsKey.newestFirst)
                    }
                Text("Top-of-file insert rewrites the whole file; the default end-append is incremental.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Editor behavior") {
                Toggle("Auto-save when the popover closes", isOn: $autoSaveOnClose)
                    .onChange(of: autoSaveOnClose) { newValue in
                        UserDefaults.standard.set(newValue, forKey: DefaultsKey.autoSaveOnClose)
                    }
            }
            Section {
                Text("When on, dismissing without ⌘↩ still saves your text. Esc still discards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Daily file rotation") {
                Toggle("Use a new file per day", isOn: $dailyRotation)
                    .onChange(of: dailyRotation) { newValue in
                        UserDefaults.standard.set(newValue, forKey: DefaultsKey.dailyRotation)
                    }
            }
            Section {
                TextField("Date pattern", text: $dailyRotationFormat)
                HStack {
                    Text(dailyDirectoryDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose directory…") { chooseDailyDirectory() }
                    if !dailyRotationDirectory.isEmpty {
                        Button("Reset") { dailyRotationDirectory = "" }
                    }
                }
                Text("Today: \(dailyRotationPreview)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!dailyRotation)
            .opacity(dailyRotation ? 1 : 0.5)
        }
        .formStyle(.grouped)
    }

    private var rightColumn: some View {
        Form {
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
            Section("Popover") {
                Toggle("Show recent entries in popover", isOn: $showRecentInPopover)
            }
            Section {
                Stepper("Recent count: \(popoverRecentCount)",
                        value: $popoverRecentCount, in: 1...5)
                Toggle("Allow editing recent entries", isOn: $popoverRecentEditable)
                Text("Edits are saved back to the file when the popover closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!showRecentInPopover)
            .opacity(showRecentInPopover ? 1 : 0.5)
            Section("Formatting bar") {
                Toggle("Show markdown formatting bar below the editor", isOn: $showFormattingBar)
                Text("Buttons for bold, italic, code, and link. Works on the main editor and on recent entries when editing is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Snippets") {
                Toggle("Show snippet bar in popover", isOn: $showPrefixBar)
            }
            Section {
                ForEach(tagPrefixes.indices, id: \.self) { idx in
                    HStack {
                        TextField("Snippet", text: Binding(
                            get: { tagPrefixes[idx] },
                            set: { newValue in
                                tagPrefixes[idx] = newValue
                                TagPrefixDefaults.save(tagPrefixes)
                            }
                        ))
                        Button {
                            tagPrefixes.remove(at: idx)
                            TagPrefixDefaults.save(tagPrefixes)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add snippet") {
                    tagPrefixes.append("")
                    TagPrefixDefaults.save(tagPrefixes)
                }
                Text("Clicking a snippet inserts it at the cursor in the popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Preview window") {
                Toggle("Enable global preview shortcut", isOn: $previewHotkeyEnabled)
                    .onChange(of: previewHotkeyEnabled) { newValue in
                        UserDefaults.standard.set(newValue, forKey: DefaultsKey.previewHotkeyEnabled)
                        NotificationCenter.default.post(name: .jotHotkeyChanged, object: nil)
                    }
            }
            Section {
                HStack {
                    ShortcutRecorderView(hotkey: $previewHotkey) { new in
                        new.save(.preview)
                        NotificationCenter.default.post(name: .jotHotkeyChanged, object: nil)
                    }
                    .frame(width: 160, height: 24)
                    .disabled(!previewHotkeyEnabled)
                    .opacity(previewHotkeyEnabled ? 1 : 0.4)
                    Text("Toggles the markdown preview window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle("Auto-refresh preview when the file changes", isOn: $previewAutoRefresh)
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
    }

    private var activeJotbookPath: String {
        Jotbooks.active()?.path ?? targetFilePath
    }

    private var formattedNow: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = dateFormat
        return f.string(from: Date())
    }

    private var dailyDirectoryDisplay: String {
        if dailyRotationDirectory.isEmpty {
            let parent = URL(fileURLWithPath: (activeJotbookPath as NSString).expandingTildeInPath)
                .deletingLastPathComponent().path
            return (parent as NSString).abbreviatingWithTildeInPath + "  (default, follows active Jotbook)"
        }
        return (dailyRotationDirectory as NSString).abbreviatingWithTildeInPath
    }

    private var dailyRotationPreview: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = dailyRotationFormat.isEmpty ? "yyyy-MM-dd" : dailyRotationFormat
        let base = URL(fileURLWithPath: (activeJotbookPath as NSString).expandingTildeInPath)
            .deletingPathExtension().lastPathComponent
        return "\(base)-\(f.string(from: Date())).md"
    }

    private func chooseDailyDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            dailyRotationDirectory = url.path
        }
    }

    private func persistJotbooks() {
        Jotbooks.save(jotbooks)
    }

    private func addJotbook() {
        let defaultName = "Jotbook \(jotbooks.count + 1)"
        let path = jotbookPath(
            in: defaultJotbookDirectory(),
            filename: jotbookFilename(for: defaultName)
        )
        let new = Jotbook(
            id: UUID(),
            name: defaultName,
            path: path,
            pathIsExplicit: false,
            captureHotkey: .empty,
            captureHotkeyEnabled: false,
            openFileHotkey: .empty,
            openFileHotkeyEnabled: false
        )
        jotbooks.append(new)
        persistJotbooks()
    }

    private func updatePathIfAutoTracking(newName: String, binding: Binding<Jotbook>) {
        let nb = binding.wrappedValue
        guard !nb.isPathExplicit else { return }

        let oldExpanded = (nb.path as NSString).expandingTildeInPath
        let parent = URL(fileURLWithPath: oldExpanded).deletingLastPathComponent().path
        let newPath = jotbookPath(in: parent, filename: jotbookFilename(for: newName))

        guard oldExpanded != newPath else { return }

        let oldExists = FileManager.default.fileExists(atPath: oldExpanded)
        binding.wrappedValue.path = newPath

        // Record the orphaned file; the warning fires once the user clicks/tabs out
        // of the name field (see flushPendingOrphanWarningIfNeeded). If another
        // orphan is pending from earlier keystrokes in this edit, keep the oldest.
        if oldExists && pendingOrphanOldPath == nil {
            pendingOrphanOldPath = oldExpanded
        }
    }

    @ViewBuilder
    private func jotbookSections(for binding: Binding<Jotbook>) -> some View {
        let nb = binding.wrappedValue
        let nbID = nb.id
        let isActive = nbID.uuidString == activeJotbookID

        Section(nb.name.isEmpty ? "Jotbook" : nb.name) {
            HStack {
                TextField("Name", text: binding.name)
                    .focused($focusedNameJotbookID, equals: nbID)
                    .onChange(of: binding.wrappedValue.name) { newName in
                        updatePathIfAutoTracking(newName: newName, binding: binding)
                        persistJotbooks()
                    }
                if isActive {
                    Text("active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Button { deleteByID(nbID) } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
            }
        }
        Section {
            HStack {
                Text((nb.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…") { chooseJotbookPath(for: binding) }
                Button("Show") { showJotbookInFinder(binding.wrappedValue) }
            }
        }
        Section {
            HStack {
                ShortcutRecorderView(hotkey: binding.captureHotkey) { _ in
                    persistJotbooks()
                }
                .frame(width: 140, height: 22)
                if !binding.wrappedValue.captureHotkey.isEmpty {
                    Button("Clear") {
                        binding.wrappedValue.captureHotkey = .empty
                        persistJotbooks()
                    }
                    .font(.caption)
                }
                Text("Opens Jot with this Jotbook active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Section {
            HStack {
                ShortcutRecorderView(hotkey: binding.openFileHotkey) { _ in
                    persistJotbooks()
                }
                .frame(width: 140, height: 22)
                if !binding.wrappedValue.openFileHotkey.isEmpty {
                    Button("Clear") {
                        binding.wrappedValue.openFileHotkey = .empty
                        persistJotbooks()
                    }
                    .font(.caption)
                }
                Text("Opens this Jotbook's file in your default editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func deleteByID(_ id: UUID) {
        guard let nb = jotbooks.first(where: { $0.id == id }) else { return }
        let expandedPath = (nb.path as NSString).expandingTildeInPath
        let displayPath = (nb.path as NSString).abbreviatingWithTildeInPath
        let fileExists = FileManager.default.fileExists(atPath: expandedPath)
        let displayName = nb.name.trimmingCharacters(in: .whitespaces).isEmpty ? "this Jotbook" : "\"\(nb.name)\""

        let alert = NSAlert()
        alert.messageText = "Delete \(displayName)?"
        if fileExists {
            alert.informativeText = "The file at \(displayPath) can be kept on disk or deleted along with the Jotbook."
            alert.addButton(withTitle: "Keep File")
            alert.addButton(withTitle: "Delete File")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.informativeText = "No file exists at \(displayPath). The Jotbook will be removed from Jot."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
        }

        let response = alert.runModal()

        let shouldRemoveFile: Bool
        if fileExists {
            switch response {
            case .alertFirstButtonReturn:  shouldRemoveFile = false  // Keep File
            case .alertSecondButtonReturn: shouldRemoveFile = true   // Delete File
            default: return  // Cancel
            }
        } else {
            switch response {
            case .alertFirstButtonReturn:  shouldRemoveFile = false  // Delete
            default: return  // Cancel
            }
        }

        if shouldRemoveFile {
            try? FileManager.default.removeItem(atPath: expandedPath)
        }

        let wasActive = (activeJotbookID == id.uuidString)
        jotbooks.removeAll { $0.id == id }
        // Persist the new list first so any .onReceive listener that reads back
        // from UserDefaults sees the deleted jotbook gone.
        persistJotbooks()
        if jotbooks.isEmpty {
            // Auto-create the default "Notes" Jotbook so the user is never stranded.
            Jotbooks.ensureAtLeastOne()
            jotbooks = Jotbooks.all()
            if let active = Jotbooks.active() {
                activeJotbookID = active.id.uuidString
            }
        } else if wasActive, let first = jotbooks.first {
            activeJotbookID = first.id.uuidString
            Jotbooks.setActive(first.id)
        }
    }

    private func chooseJotbookPath(for jotbook: Binding<Jotbook>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Pick a folder to auto-name the file from the Jotbook name, or pick an existing .md file to use it directly."
        panel.prompt = "Select"
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType, .plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            // Folder picked — path follows the Jotbook name.
            let filename = jotbookFilename(for: jotbook.wrappedValue.name)
            jotbook.wrappedValue.path = jotbookPath(in: url.path, filename: filename)
            jotbook.wrappedValue.pathIsExplicit = false
        } else {
            // Specific file picked — pin the path.
            jotbook.wrappedValue.path = url.path
            jotbook.wrappedValue.pathIsExplicit = true
        }
        persistJotbooks()
    }

    private func showJotbookInFinder(_ jotbook: Jotbook) {
        let url = URL(fileURLWithPath: (jotbook.path as NSString).expandingTildeInPath)
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

        let text: String
        if isRecording {
            text = "Press shortcut…"
        } else if hotkey.isEmpty {
            text = "Not set"
        } else {
            text = hotkey.displayString
        }
        let color: NSColor = (isRecording || hotkey.isEmpty) ? .secondaryLabelColor : .labelColor
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
