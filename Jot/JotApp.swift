import SwiftUI
import AppKit
import ApplicationServices
import Combine
import ServiceManagement

final class NoteEditorState: ObservableObject {
    @Published var text = ""
    @Published var recent: [RecentEntry] = []
    @Published var editableRecentText: String = ""
    var originalEditableRecentText: String = ""
    @Published var searching = false
    @Published var searchQuery = ""
    @Published var searchResults: [SearchResult] = []
}

struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    var stamp: String
    var line: String
}

enum SearchTarget {
    static func search(_ query: String) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lowerQuery = trimmed.lowercased()
        var results: [SearchResult] = []
        var currentStamp = ""
        for line in contents.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                currentStamp = String(line.dropFirst(4))
                continue
            }
            if line.lowercased().contains(lowerQuery) {
                let clean = line.trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty {
                    results.append(SearchResult(stamp: currentStamp, line: clean))
                }
            }
        }
        return results.reversed()
    }
}

final class NoteTextViewHolder: ObservableObject {
    weak var textView: NSTextView?
}

struct JotTextEditor: NSViewRepresentable {
    @Binding var text: String
    var holder: NoteTextViewHolder

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        textView.string = text
        DispatchQueue.main.async { [weak textView] in
            self.holder.textView = textView
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JotTextEditor
        init(_ parent: JotTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

struct NoteEditorView: View {
    @ObservedObject var state: NoteEditorState
    var onOpenFile: () -> Void
    @StateObject private var holder = NoteTextViewHolder()
    @AppStorage(DefaultsKey.showPrefixBar) private var showSnippetBar: Bool = true
    @AppStorage(DefaultsKey.showRecentInPopover) private var showRecent: Bool = false
    @AppStorage(DefaultsKey.popoverRecentEditable) private var recentEditable: Bool = false
    @AppStorage(DefaultsKey.showFormattingBar) private var showFormattingBar: Bool = true
    @State private var snippets: [String] = TagPrefixDefaults.load()
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        Group {
            if state.searching {
                searchView
            } else {
                captureView
            }
        }
        .onAppear {
            snippets = TagPrefixDefaults.load()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusEditor()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jotTagPrefixesChanged)) { _ in
            snippets = TagPrefixDefaults.load()
        }
        .onChange(of: state.searching) { newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    searchFieldFocused = true
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusEditor()
                }
            }
        }
    }

    private var captureView: some View {
        VStack(spacing: 0) {
            if showRecent && !state.recent.isEmpty {
                recentArea
                Divider()
            }
            if showSnippetBar && !snippets.isEmpty {
                snippetBar
                Divider()
            }
            JotTextEditor(text: $state.text, holder: holder)
            if showFormattingBar {
                Divider()
                formattingBar
            }
        }
        .frame(width: 320, height: editorHeight)
    }

    private var editorHeight: CGFloat {
        var h: CGFloat = 140
        if showSnippetBar && !snippets.isEmpty { h += 35 }
        if showRecent && !state.recent.isEmpty { h += 120 }
        if showFormattingBar { h += 30 }
        return h
    }

    private var formattingBar: some View {
        HStack(spacing: 6) {
            formatButton(label: "B", bold: true) { wrapSelection(left: "**", right: "**") }
            formatButton(label: "I", italic: true) { wrapSelection(left: "*", right: "*") }
            formatButton(label: "<>") { wrapSelection(left: "`", right: "`") }
            formatButton(systemImage: "link") { insertLink() }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 30)
    }

    @ViewBuilder
    private func formatButton(label: String = "",
                              systemImage: String? = nil,
                              bold: Bool = false,
                              italic: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                } else {
                    Text(label)
                        .font(.system(size: 11, weight: bold ? .bold : .medium))
                        .italic(italic)
                }
            }
            .frame(minWidth: 14)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var searchView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes", text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onChange(of: state.searchQuery) { query in
                        state.searchResults = SearchTarget.search(query)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            searchResultsList
        }
        .frame(width: 320, height: 320)
    }

    @ViewBuilder private var searchResultsList: some View {
        if state.searchQuery.isEmpty {
            VStack {
                Spacer()
                Text("Type to search the target file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Esc to exit search.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if state.searchResults.isEmpty {
            VStack {
                Spacer()
                Text("No matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.searchResults) { result in
                        Button(action: { onOpenFile() }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.stamp)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(result.line)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder private var recentArea: some View {
        if recentEditable {
            TextEditor(text: $state.editableRecentText)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 120)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.recent) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.stamp)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.body)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }

    private var snippetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(snippets, id: \.self) { snippet in
                    Button(action: { insert(snippet) }) {
                        Text(snippet.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .frame(height: 30)
    }

    private func focusEditor() {
        guard let tv = holder.textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    private func insert(_ snippet: String) {
        guard let tv = holder.textView else {
            state.text.append(snippet)
            return
        }
        // Make sure the text view is the first responder before inserting so
        // the caret behaves correctly.
        if tv.window?.firstResponder !== tv {
            tv.window?.makeFirstResponder(tv)
        }
        tv.insertText(snippet, replacementRange: tv.selectedRange())
        // Keep focus for continued typing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            tv.window?.makeFirstResponder(tv)
        }
    }

    private func activeTextView() -> NSTextView? {
        for window in NSApp.windows {
            if let tv = window.firstResponder as? NSTextView {
                return tv
            }
        }
        return holder.textView
    }

    private func wrapSelection(left: String, right: String) {
        guard let tv = activeTextView() else { return }
        let range = tv.selectedRange()
        let ns = tv.string as NSString
        let selection = range.length > 0 ? ns.substring(with: range) : ""
        let replacement = left + selection + right
        tv.insertText(replacement, replacementRange: range)
        if range.length == 0 {
            let caret = range.location + (left as NSString).length
            tv.setSelectedRange(NSRange(location: caret, length: 0))
        }
        tv.window?.makeFirstResponder(tv)
    }

    private func insertLink() {
        guard let tv = activeTextView() else { return }
        let range = tv.selectedRange()
        let ns = tv.string as NSString
        let selection = range.length > 0 ? ns.substring(with: range) : ""
        let replacement = "[\(selection)](url)"
        tv.insertText(replacement, replacementRange: range)
        let selectionLen = (selection as NSString).length
        let urlStart = range.location + 1 + selectionLen + 2  // after "]("
        let urlLen = 3  // "url"
        tv.setSelectedRange(NSRange(location: urlStart, length: urlLen))
        tv.window?.makeFirstResponder(tv)
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
    private var explicitlyDismissed = false
    private var escPressed = false
    private let editorState = NoteEditorState()
    private var settingsWindow: NSWindow?
    private lazy var previewController = PreviewWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerUserDefaults()
        migrateDailyRotationFormatIfNeeded()
        Jotbooks.ensureAtLeastOne()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(jotbooksChanged),
            name: .jotJotbooksChanged,
            object: nil
        )
    }

    @objc private func jotbooksChanged() {
        registerHotkeyMonitors()
        buildRightClickMenu()
    }

    @objc private func appBecameActive() {
        registerHotkeyMonitors()
    }

    /// The rotation format used to embed `'JotNotes-'` literally in the pattern; now it's the
    /// date portion only (the jotbook's base filename is prepended). Strip the old prefix if present.
    private func migrateDailyRotationFormatIfNeeded() {
        let key = DefaultsKey.dailyRotationFormat
        guard let stored = UserDefaults.standard.string(forKey: key) else { return }
        if stored == "'JotNotes-'yyyy-MM-dd" {
            UserDefaults.standard.set("yyyy-MM-dd", forKey: key)
        }
    }

    private func registerUserDefaults() {
        var defaults: [String: Any] = [
            DefaultsKey.showPrefixBar: true,
            DefaultsKey.popoverRecentCount: 3,
            DefaultsKey.previewAutoRefresh: true,
            DefaultsKey.showFormattingBar: true
        ]
        if let data = try? JSONEncoder().encode(TagPrefixDefaults.list) {
            defaults[DefaultsKey.tagPrefixes] = data
        }
        UserDefaults.standard.register(defaults: defaults)
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
            rootView: NoteEditorView(
                state: editorState,
                onOpenFile: { [weak self] in self?.openTargetFile() }
            )
        )
    }

    private func buildRightClickMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open Jot", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let openFile = NSMenuItem(title: "Open Note File", action: #selector(openTargetFile), keyEquivalent: "")
        openFile.target = self
        menu.addItem(openFile)

        let preview = NSMenuItem(title: "Show Preview", action: #selector(togglePreviewWindow), keyEquivalent: "")
        preview.target = self
        if UserDefaults.standard.bool(forKey: DefaultsKey.previewHotkeyEnabled) {
            applyHotkeyToMenuItem(Hotkey.load(.preview), item: preview)
        }
        menu.addItem(preview)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showJotConfig), keyEquivalent: "")
        settings.target = self
        settings.image = nil
        menu.addItem(settings)

        let jotbooks = Jotbooks.all()
        if jotbooks.count > 1 {
            menu.addItem(.separator())
            let switchItem = NSMenuItem(title: "Switch Jotbook", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let activeID = Jotbooks.active()?.id
            for nb in jotbooks {
                let item = NSMenuItem(
                    title: nb.name,
                    action: #selector(switchJotbookFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = nb.id.uuidString
                if nb.id == activeID { item.state = .on }
                submenu.addItem(item)
            }
            switchItem.submenu = submenu
            menu.addItem(switchItem)
        }

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

    @objc private func showJotConfig() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
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
        editorState.searching = false
        editorState.searchQuery = ""
        editorState.searchResults = []

        let defaults = UserDefaults.standard
        let showRecent = defaults.bool(forKey: DefaultsKey.showRecentInPopover)
        var recentCount = defaults.integer(forKey: DefaultsKey.popoverRecentCount)
        if recentCount <= 0 { recentCount = 3 }
        let recents = showRecent ? RecentEntries.load(limit: recentCount) : []
        editorState.recent = recents
        let editableText = RecentEntries.serialize(recents)
        editorState.editableRecentText = editableText
        editorState.originalEditableRecentText = editableText

        popover.contentSize = basePopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        installPopoverKeyMonitor()
    }

    private func basePopoverSize() -> NSSize {
        let defaults = UserDefaults.standard
        let showBar = defaults.bool(forKey: DefaultsKey.showPrefixBar)
        let prefixes = TagPrefixDefaults.load()
        let hasBar = showBar && !prefixes.isEmpty

        let showRecent = defaults.bool(forKey: DefaultsKey.showRecentInPopover)
        let hasRecent = showRecent && !editorState.recent.isEmpty

        let showFormatting = defaults.bool(forKey: DefaultsKey.showFormattingBar)

        var height: CGFloat = 140
        if hasBar { height += 35 }
        if hasRecent { height += 120 }
        if showFormatting { height += 30 }
        return NSSize(width: 320, height: height)
    }

    private func searchPopoverSize() -> NSSize {
        NSSize(width: 320, height: 320)
    }

    private func installPopoverKeyMonitor() {
        if let existing = popoverKeyMonitor {
            NSEvent.removeMonitor(existing)
            popoverKeyMonitor = nil
        }
        popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // ⌘F — enter search
            if event.keyCode == 3, event.modifierFlags.contains(.command) {
                self.enterSearchMode()
                return nil
            }
            // ⌘↩ — save
            if event.keyCode == 36, event.modifierFlags.contains(.command) {
                if self.editorState.searching {
                    // In search mode, ⌘↩ is a no-op (nothing to save in the search field)
                    return nil
                }
                self.save()
                return nil
            }
            // Esc — exit search if active, otherwise dismiss the popover
            if event.keyCode == 53 {
                if self.editorState.searching {
                    self.exitSearchMode()
                    return nil
                }
                self.explicitlyDismissed = true
                self.escPressed = true
                self.popover.performClose(nil)
                return nil
            }
            return event
        }
    }

    private func enterSearchMode() {
        editorState.searchQuery = ""
        editorState.searchResults = []
        editorState.searching = true
        popover.contentSize = searchPopoverSize()
    }

    private func exitSearchMode() {
        editorState.searching = false
        editorState.searchQuery = ""
        editorState.searchResults = []
        popover.contentSize = basePopoverSize()
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = popoverKeyMonitor {
            NSEvent.removeMonitor(m)
            popoverKeyMonitor = nil
        }
        let defaults = UserDefaults.standard

        // Persist edits to recent entries, if enabled and modified.
        // Esc always discards recent edits; ⌘↩ and click-outside keep them.
        let showRecent = defaults.bool(forKey: DefaultsKey.showRecentInPopover)
        let editable = defaults.bool(forKey: DefaultsKey.popoverRecentEditable)
        if showRecent && editable,
           !escPressed,
           !editorState.recent.isEmpty,
           editorState.editableRecentText != editorState.originalEditableRecentText {
            do {
                try RecentEntries.replaceLastEntries(
                    count: editorState.recent.count,
                    with: editorState.editableRecentText
                )
                flashSaveCheckmark()
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn't save edits to recent entries"
                alert.runModal()
            }
        }

        let autoSave = defaults.bool(forKey: DefaultsKey.autoSaveOnClose)
        let trimmed = editorState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if autoSave && !explicitlyDismissed && !trimmed.isEmpty {
            do {
                try NoteAppender.append(trimmed)
                editorState.text = ""
                flashSaveCheckmark()
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn't auto-save note"
                alert.runModal()
            }
        }
        explicitlyDismissed = false
        escPressed = false
    }

    private func save() {
        let trimmed = editorState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            explicitlyDismissed = true
            popover.performClose(nil)
            return
        }
        do {
            try NoteAppender.append(trimmed)
            editorState.text = ""
            explicitlyDismissed = true
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
        if UserDefaults.standard.bool(forKey: DefaultsKey.previewHotkeyEnabled) {
            bindings.append((Hotkey.load(.preview), { [weak self] in self?.togglePreviewWindow() }))
        }
        if UserDefaults.standard.bool(forKey: DefaultsKey.quitHotkeyEnabled) {
            bindings.append((Hotkey.load(.quit), { NSApp.terminate(nil) }))
        }
        // Per-jotbook dedicated shortcuts — any set shortcut is active.
        for jotbook in Jotbooks.all() {
            if !jotbook.captureHotkey.isEmpty {
                let id = jotbook.id
                bindings.append((jotbook.captureHotkey, { [weak self] in
                    self?.captureIntoJotbook(withID: id)
                }))
            }
            if !jotbook.openFileHotkey.isEmpty {
                let path = jotbook.path
                bindings.append((jotbook.openFileHotkey, { [weak self] in
                    self?.openJotbookFile(at: path)
                }))
            }
        }
        return bindings
    }

    private func captureIntoJotbook(withID id: UUID) {
        Jotbooks.setActive(id)
        if popover.isShown {
            popover.performClose(nil)
        }
        showPopover()
    }

    private func openJotbookFile(at path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? Data("# Jot Notes\n\n".utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func switchJotbookFromMenu(_ sender: NSMenuItem) {
        guard let uuidString = sender.representedObject as? String,
              let uuid = UUID(uuidString: uuidString) else { return }
        Jotbooks.setActive(uuid)
        buildRightClickMenu()
    }

    @objc private func togglePreviewWindow() {
        if previewController.isVisible {
            previewController.close()
        } else {
            previewController.show()
        }
    }

    @objc private func openTargetFile() {
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? Data("# Jot Notes\n\n".utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    private func matchedAction(for event: NSEvent, in bindings: [(Hotkey, () -> Void)]) -> (() -> Void)? {
        // Don't intercept hotkeys while a ShortcutRecorder is recording — let keys through.
        if NSApp.keyWindow?.firstResponder is RecorderNSView {
            return nil
        }
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
    static func stamp(for date: Date = Date()) -> String {
        let pattern = UserDefaults.standard.string(forKey: DefaultsKey.dateFormat) ?? "yyyy-MM-dd HH:mm"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    static func append(_ text: String) throws {
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data("# Jot Notes\n\n".utf8).write(to: url)
        }
        let entry = "\n### \(stamp())\n\(text)\n"

        if UserDefaults.standard.bool(forKey: DefaultsKey.newestFirst) {
            var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let headerPattern = "# Jot Notes\n\n"
            if let range = contents.range(of: headerPattern) {
                contents.insert(contentsOf: entry, at: range.upperBound)
            } else {
                contents = entry + contents
            }
            try Data(contents.utf8).write(to: url)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        }
    }
}

func defaultTargetFilePath() -> String {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    return docs.appendingPathComponent("JotBook.md").path
}

func defaultJotbookDirectory() -> String {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    return docs.path
}

/// Build a filename from a jotbook name: empty → "JotBook.md", otherwise "JotBook-{name}.md".
func jotbookFilename(for name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "JotBook.md" : "JotBook-\(trimmed).md"
}

/// Join a directory path and a filename, expanding `~` if present in the directory.
func jotbookPath(in directory: String, filename: String) -> String {
    let expanded = (directory as NSString).expandingTildeInPath
    return (expanded as NSString).appendingPathComponent(filename)
}

func resolvedTargetPath(for date: Date = Date()) -> String {
    let defaults = UserDefaults.standard
    let staticPath = Jotbooks.active()?.path
        ?? defaults.string(forKey: DefaultsKey.targetFilePath)
        ?? defaultTargetFilePath()
    guard defaults.bool(forKey: DefaultsKey.dailyRotation) else {
        return staticPath
    }
    let pattern = defaults.string(forKey: DefaultsKey.dailyRotationFormat) ?? "yyyy-MM-dd"
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = pattern
    let dateStr = f.string(from: date)

    let staticURL = URL(fileURLWithPath: (staticPath as NSString).expandingTildeInPath)
    let baseName = staticURL.deletingPathExtension().lastPathComponent
    let filename = "\(baseName)-\(dateStr).md"
    let directory = staticURL.deletingLastPathComponent().path
    return (directory as NSString).appendingPathComponent(filename)
}

extension Notification.Name {
    static let jotHotkeyChanged = Notification.Name("JotHotkeyChanged")
}

struct RecentEntry: Identifiable, Equatable {
    let id = UUID()
    var stamp: String
    var body: String
}

enum RecentEntries {
    static func load(limit: Int) -> [RecentEntry] {
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = contents.components(separatedBy: "\n")

        var results: [RecentEntry] = []
        var currentStamp: String?
        var currentBody: [String] = []
        for line in lines {
            if line.hasPrefix("### ") {
                if let stamp = currentStamp {
                    let body = currentBody.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    results.append(RecentEntry(stamp: stamp, body: body))
                }
                currentStamp = String(line.dropFirst(4))
                currentBody = []
            } else if currentStamp != nil {
                currentBody.append(line)
            }
        }
        if let stamp = currentStamp {
            let body = currentBody.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(RecentEntry(stamp: stamp, body: body))
        }
        return Array(results.suffix(limit).reversed())
    }

    /// Replace the last `count` entries in the file with the given edited text.
    /// The edited text should contain `### stamp` headers in the same reverse-chronological order
    /// that `load(limit:)` returned. Any text before the Nth-from-last `### ` header is preserved.
    static func replaceLastEntries(count: Int, with editedReverseChronological: String) throws {
        guard count > 0 else { return }
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        // Find the index of the Nth-from-last `### ` header
        let lines = contents.components(separatedBy: "\n")
        var headerIndices: [Int] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("### ") {
            headerIndices.append(i)
        }
        guard !headerIndices.isEmpty else { return }
        let takeCount = min(count, headerIndices.count)
        let startIndex = headerIndices[headerIndices.count - takeCount]
        let preserved = lines.prefix(startIndex).joined(separator: "\n")

        // Re-order edited text back to chronological order (oldest first)
        let editedEntries = splitEntries(editedReverseChronological).reversed()
        let chronologicalTail = editedEntries.joined(separator: "\n")

        var newContents = preserved
        if !newContents.isEmpty && !newContents.hasSuffix("\n") {
            newContents += "\n"
        }
        if !chronologicalTail.isEmpty {
            newContents += chronologicalTail
            if !newContents.hasSuffix("\n") { newContents += "\n" }
        }
        try Data(newContents.utf8).write(to: url)
    }

    /// Split a text blob at each `### ` header boundary, keeping the header with its entry.
    private static func splitEntries(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var result: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.hasPrefix("### ") {
                if !current.isEmpty { result.append(current) }
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Serialize entries to the same format used in the popover when editable mode is on:
    /// `### stamp\nbody` blocks separated by a blank line, reverse-chronological (newest first).
    static func serialize(_ entries: [RecentEntry]) -> String {
        entries.map { "### \($0.stamp)\n\($0.body)" }.joined(separator: "\n\n")
    }
}
