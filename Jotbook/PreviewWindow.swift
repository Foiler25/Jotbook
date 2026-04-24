// Jotbook — a lightweight macOS menubar note-taker.
// Copyright (C) 2026 Brandon Villar
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import AppKit
import Combine
import SwiftUI
import WebKit

final class PreviewWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow

    // Read-only mode state
    private var webView: WKWebView?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1

    // Editable mode state
    private var textView: NSTextView?
    private var snippetBar: NSStackView?
    private var tagPrefixObserver: NSObjectProtocol?
    private var isDirty = false
    private var lastSavedModification: Date?
    /// Set while we're replacing the text view's contents programmatically so
    /// the NSTextDidChange handler doesn't flag the buffer as dirty.
    private var isLoadingFromDisk = false

    // Title-bar edit-mode toggle (persists across content-view rebuilds).
    private var editModeButton: NSButton?

    // ⌘F search overlay state.
    private let searchState = PreviewSearchState()
    private var searchHost: NSHostingView<PreviewSearchOverlay>?
    private var searchKeyMonitor: Any?
    private var searchClickMonitor: Any?

    var onClose: (() -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jotbook Preview"
        window.center()
        window.isReleasedWhenClosed = false
        // Force dark appearance + black chrome so the preview matches the
        // always-dark capture panel.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        super.init()
        window.delegate = self
        installEditModeToggle()
        buildContentView()
        installSearchKeyMonitor()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reload()
        if textView == nil {
            setupWatcherIfEnabled()
        }
    }

    func close() {
        flushIfDirty()
        window.orderOut(nil)
        stopWatcher()
    }

    var isVisible: Bool { window.isVisible }

    /// Called by AppDelegate when the `previewEditable` default toggles while
    /// the window is open. Persists any pending edit, then swaps the content
    /// view to match the new mode.
    func rebuildContentView() {
        // Tear down the search overlay first so it doesn't hold refs to the
        // content view we're about to replace.
        dismissSearchOverlay()
        flushIfDirty()
        stopWatcher()
        teardownWebView()
        teardownEditor()
        buildContentView()
        syncEditModeToggle()
        if window.isVisible {
            reload()
            if textView == nil {
                setupWatcherIfEnabled()
            }
        }
    }

    func reload() {
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let exists = FileManager.default.fileExists(atPath: url.path)

        if let tv = textView {
            let markdown: String
            if exists {
                markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            } else {
                markdown = ""
            }
            loadIntoEditor(tv, markdown: markdown, fileURL: url, exists: exists)
        } else if let web = webView {
            let markdown: String
            if exists {
                markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? "_Could not read the file._"
            } else {
                markdown = "# No notes yet\n\nThe target file does not exist. Save a note to create it."
            }
            web.loadHTMLString(PreviewHTML.render(markdown), baseURL: nil)
        }
    }

    func refreshWatcher() {
        // Editable mode manages its own save/reload lifecycle — no watcher.
        guard textView == nil else { return }
        setupWatcherIfEnabled()
    }

    // MARK: - Title-bar edit-mode toggle

    private func installEditModeToggle() {
        let button = NSButton(title: "Edit", target: self, action: #selector(toggleEditModeFromTitlebar(_:)))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11)
        button.toolTip = "Toggle editable preview"
        button.state = UserDefaults.standard.bool(forKey: DefaultsKey.previewEditable) ? .on : .off
        button.sizeToFit()

        // NSTitlebarAccessoryViewController with .trailing lays the view out
        // flush against the window's trailing edge. Reserve extra width on the
        // right of the button so it doesn't butt against the window edge.
        let trailingMargin: CGFloat = 10
        let containerHeight: CGFloat = 28
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: button.frame.width + trailingMargin,
            height: containerHeight
        ))
        button.frame = NSRect(
            x: 0,
            y: (containerHeight - button.frame.height) / 2,
            width: button.frame.width,
            height: button.frame.height
        )
        container.addSubview(button)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        editModeButton = button
    }

    private func syncEditModeToggle() {
        let on = UserDefaults.standard.bool(forKey: DefaultsKey.previewEditable)
        editModeButton?.state = on ? .on : .off
    }

    @objc private func toggleEditModeFromTitlebar(_ sender: NSButton) {
        // Writing the default fires UserDefaults.didChangeNotification, which
        // AppDelegate observes and uses to call rebuildContentView(). That
        // path also resyncs the button state, so we don't need to do anything
        // else here.
        UserDefaults.standard.set(sender.state == .on, forKey: DefaultsKey.previewEditable)
    }

    // MARK: - Content view construction

    private func buildContentView() {
        if UserDefaults.standard.bool(forKey: DefaultsKey.previewEditable) {
            buildEditor()
        } else {
            buildWebPreview()
        }
    }

    private func buildWebPreview() {
        let web = WKWebView(frame: .zero)
        // Paint transparent so the black window background shows through
        // during loads and in any areas the rendered HTML doesn't cover.
        web.setValue(false, forKey: "drawsBackground")
        window.contentView = web
        webView = web
    }

    private func buildEditor() {
        // Text view + scroll view (body center)
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else { return }
        tv.delegate = self
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true
        tv.isRichText = false
        tv.isEditable = true
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.drawsBackground = true
        tv.backgroundColor = .black
        tv.textColor = .white
        tv.insertionPointColor = .white
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView = tv

        // Left vertical formatting toolbar
        let formatBar = makeFormattingBar()
        formatBar.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [formatBar, scrollView])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 0
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false

        // Top horizontal snippet bar
        let snippets = makeSnippetBar()
        snippetBar = snippets
        snippets.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [snippets, body])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.distribution = .fill
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            snippets.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            snippets.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            snippets.heightAnchor.constraint(equalToConstant: 34),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            formatBar.widthAnchor.constraint(equalToConstant: 44),
            formatBar.topAnchor.constraint(equalTo: body.topAnchor),
            formatBar.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])

        window.contentView = container

        tagPrefixObserver = NotificationCenter.default.addObserver(
            forName: .jotTagPrefixesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildSnippetBar()
        }
    }

    private func makeFormattingBar() -> NSView {
        let buttons: [NSView] = [
            makeToolbarButton(title: "B", accessibility: "Bold", action: #selector(fmtBold)),
            makeToolbarButton(title: "I", accessibility: "Italic", action: #selector(fmtItalic)),
            makeToolbarButton(title: "S", accessibility: "Strikethrough", action: #selector(fmtStrike)),
            makeToolbarButton(title: "<>", accessibility: "Code", action: #selector(fmtCode)),
            makeToolbarButton(systemImage: "link", accessibility: "Link", action: #selector(fmtLink)),
            makeToolbarButton(title: "H1", accessibility: "Heading 1", action: #selector(fmtH1)),
            makeToolbarButton(title: "H2", accessibility: "Heading 2", action: #selector(fmtH2)),
            makeToolbarButton(title: "H3", accessibility: "Heading 3", action: #selector(fmtH3)),
            makeToolbarButton(title: "•", accessibility: "Bullet list", action: #selector(fmtBullet)),
            makeToolbarButton(title: "1.", accessibility: "Numbered list", action: #selector(fmtNumbered)),
            makeToolbarButton(title: ">", accessibility: "Blockquote", action: #selector(fmtQuote))
        ]
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return stack
    }

    private func makeSnippetBar() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.distribution = .gravityAreas
        populateSnippetBar(stack)
        return stack
    }

    private func rebuildSnippetBar() {
        guard let stack = snippetBar else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        populateSnippetBar(stack)
    }

    private func populateSnippetBar(_ stack: NSStackView) {
        for snippet in TagPrefixDefaults.load() {
            let label = snippet.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            let button = makeSnippetButton(label: label, payload: snippet)
            stack.addArrangedSubview(button)
        }
    }

    private func makeSnippetButton(label: String, payload: String) -> NSButton {
        let button = SnippetButton(title: label, target: self, action: #selector(insertSnippet(_:)))
        button.bezelStyle = .inline
        button.payload = payload
        button.setButtonType(.momentaryPushIn)
        button.isBordered = true
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        return button
    }

    private func makeToolbarButton(title: String = "",
                                   systemImage: String? = nil,
                                   accessibility: String,
                                   action: Selector) -> NSButton {
        let button: NSButton
        if let systemImage, let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: accessibility) {
            button = NSButton(image: image, target: self, action: action)
        } else {
            button = NSButton(title: title, target: self, action: action)
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        }
        button.bezelStyle = .inline
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityLabel(accessibility)
        button.toolTip = accessibility
        return button
    }

    // MARK: - Formatting actions

    @objc private func fmtBold()     { guard let tv = textView else { return }; MarkdownFormatter.wrapSelection(in: tv, left: "**", right: "**") }
    @objc private func fmtItalic()   { guard let tv = textView else { return }; MarkdownFormatter.wrapSelection(in: tv, left: "*", right: "*") }
    @objc private func fmtStrike()   { guard let tv = textView else { return }; MarkdownFormatter.wrapSelection(in: tv, left: "~~", right: "~~") }
    @objc private func fmtCode()     { guard let tv = textView else { return }; MarkdownFormatter.wrapSelection(in: tv, left: "`", right: "`") }
    @objc private func fmtLink()     { guard let tv = textView else { return }; MarkdownFormatter.insertLink(in: tv) }
    @objc private func fmtH1()       { guard let tv = textView else { return }; MarkdownFormatter.insertLinePrefix(in: tv, "# ") }
    @objc private func fmtH2()       { guard let tv = textView else { return }; MarkdownFormatter.insertLinePrefix(in: tv, "## ") }
    @objc private func fmtH3()       { guard let tv = textView else { return }; MarkdownFormatter.insertLinePrefix(in: tv, "### ") }
    @objc private func fmtBullet()   { guard let tv = textView else { return }; MarkdownFormatter.insertLinePrefix(in: tv, "- ") }
    @objc private func fmtNumbered() { guard let tv = textView else { return }; MarkdownFormatter.insertLinePrefix(in: tv, "1. ") }
    @objc private func fmtQuote()    { guard let tv = textView else { return }; MarkdownFormatter.insertLinePrefix(in: tv, "> ") }

    @objc private func insertSnippet(_ sender: Any?) {
        guard let tv = textView, let button = sender as? SnippetButton else { return }
        MarkdownFormatter.insertLinePrefix(in: tv, button.payload)
    }

    // MARK: - Editor load/save

    private func loadIntoEditor(_ tv: NSTextView, markdown: String, fileURL: URL, exists: Bool) {
        isLoadingFromDisk = true
        let previousSelection = tv.selectedRange()
        tv.string = markdown
        // Restore caret if it still fits; otherwise park it at the end.
        if previousSelection.location + previousSelection.length <= (markdown as NSString).length {
            tv.setSelectedRange(previousSelection)
        } else {
            tv.setSelectedRange(NSRange(location: (markdown as NSString).length, length: 0))
        }
        isLoadingFromDisk = false
        isDirty = false
        lastSavedModification = exists ? modificationDate(for: fileURL) : nil
    }

    private func flushIfDirty() {
        guard isDirty, let tv = textView else { return }
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try tv.string.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            lastSavedModification = modificationDate(for: url)
        } catch {
            NSLog("Jotbook: failed to save preview edits: \(error.localizedDescription)")
        }
    }

    private func reloadIfFileChangedExternally() {
        guard let tv = textView else { return }
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let current = modificationDate(for: url) else { return }
        // If the buffer has unsaved edits, prefer them over an external refresh.
        if isDirty { return }
        if let last = lastSavedModification, current <= last { return }
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        loadIntoEditor(tv, markdown: markdown, fileURL: url, exists: true)
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    // MARK: - File watcher (read-only mode only)

    private func setupWatcherIfEnabled() {
        stopWatcher()
        let auto = UserDefaults.standard.bool(forKey: DefaultsKey.previewAutoRefresh)
        guard auto else { return }
        let path = resolvedTargetPath()
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        let fd = open(expanded, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reload()
            let mask = source.data
            if mask.contains(.rename) || mask.contains(.delete) {
                self.setupWatcherIfEnabled()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.watchedFD >= 0 {
                Darwin.close(self.watchedFD)
                self.watchedFD = -1
            }
        }
        source.resume()
        watcher = source
    }

    private func stopWatcher() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        dismissSearchOverlay()
        removeSearchKeyMonitor()
        flushIfDirty()
        stopWatcher()
        teardownWebView()
        teardownEditor()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        flushIfDirty()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reloadIfFileChangedExternally()
    }

    // MARK: - Teardown

    private func teardownWebView() {
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        // Replace the rendered document with an empty blank page so the
        // WebContent process has nothing left to hold on to.
        web.loadHTMLString("", baseURL: nil)
        window.contentView = nil
        webView = nil
    }

    private func teardownEditor() {
        if let observer = tagPrefixObserver {
            NotificationCenter.default.removeObserver(observer)
            tagPrefixObserver = nil
        }
        if let tv = textView {
            tv.delegate = nil
        }
        textView = nil
        snippetBar = nil
        window.contentView = nil
    }

    // MARK: - ⌘F search overlay

    /// Local key monitor scoped to this window. ⌘F presents / focuses the
    /// search overlay; Esc dismisses it. Both events are consumed so they
    /// don't bubble to the text view / web view underneath.
    private func installSearchKeyMonitor() {
        if let existing = searchKeyMonitor {
            NSEvent.removeMonitor(existing)
            searchKeyMonitor = nil
        }
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // ⌘F — show / focus the search overlay.
            if event.keyCode == 3, event.modifierFlags.contains(.command) {
                self.presentSearchOverlay()
                return nil
            }
            // Esc — dismiss the overlay if it's active. If not, let the
            // event through so the window's default handling (which ignores
            // it for preview) still applies without closing the window.
            if event.keyCode == 53, self.searchState.active {
                self.dismissSearchOverlay()
                return nil
            }
            return event
        }
    }

    private func removeSearchKeyMonitor() {
        if let m = searchKeyMonitor {
            NSEvent.removeMonitor(m)
            searchKeyMonitor = nil
        }
    }

    /// Fires for every mouse-down inside the preview window while the overlay
    /// is up. If the click lands outside the overlay's bounds, dismiss it —
    /// but pass the event through so the underlying content still gets the
    /// click (e.g. placing the cursor in the text view).
    private func installSearchClickMonitor() {
        removeSearchClickMonitor()
        searchClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  let host = self.searchHost else { return event }
            let pointInHost = host.convert(event.locationInWindow, from: nil)
            if !host.bounds.contains(pointInHost) {
                self.dismissSearchOverlay()
            }
            return event
        }
    }

    private func removeSearchClickMonitor() {
        if let m = searchClickMonitor {
            NSEvent.removeMonitor(m)
            searchClickMonitor = nil
        }
    }

    private func presentSearchOverlay() {
        guard let contentView = window.contentView else { return }
        // Already showing — just refocus by re-mounting the hosting view's
        // onAppear. Cheapest way: dismiss and re-present.
        if searchState.active, searchHost != nil {
            // Re-make key + refocus the field without rebuilding.
            window.makeFirstResponder(searchHost)
            return
        }

        // Wire the mode-specific search + select callbacks.
        if textView != nil {
            searchState.performSearch = { [weak self] query in
                SearchTarget.search(query, in: self?.textView?.string ?? "")
            }
            searchState.onSelect = { [weak self] result in
                self?.scrollTextViewTo(result.line)
            }
        } else {
            // Read-only markdown mode — search the disk file.
            searchState.performSearch = { query in
                SearchTarget.search(query)
            }
            searchState.onSelect = { [weak self] result in
                self?.scrollWebViewTo(result.line)
            }
        }

        searchState.query = ""
        searchState.results = []

        let host = searchHost ?? NSHostingView(rootView: PreviewSearchOverlay(state: searchState))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.alphaValue = 0

        if host.superview == nil {
            contentView.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
                host.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                host.widthAnchor.constraint(equalToConstant: 320)
            ])
        }

        searchHost = host
        searchState.active = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            host.animator().alphaValue = 1
        }

        // Click outside the overlay should dismiss it.
        installSearchClickMonitor()

        // Give the field first-responder so typing lands in the search field.
        DispatchQueue.main.async { [weak self, weak host] in
            guard let host else { return }
            self?.window.makeFirstResponder(host)
        }
    }

    private func dismissSearchOverlay() {
        removeSearchClickMonitor()
        guard let host = searchHost else {
            searchState.active = false
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            host.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak host] in
            host?.removeFromSuperview()
            self?.searchHost = nil
            self?.searchState.active = false
            self?.searchState.query = ""
            self?.searchState.results = []
            // Return focus to the underlying preview (text view if editable,
            // otherwise let the window decide).
            if let tv = self?.textView {
                self?.window.makeFirstResponder(tv)
            }
        })
    }

    /// Scroll + highlight a line in the WKWebView preview.
    private func scrollWebViewTo(_ line: String) {
        guard let web = webView else { return }
        // Escape for embedding in a JS string literal.
        let encoded = (try? JSONEncoder().encode(line))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        // WebKit's undocumented but long-lived find API — scrolls the match
        // into view and applies the browser's selection highlight.
        let js = "window.find(\(encoded), false, false, true, false, false, false);"
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Scroll + highlight a line in the editable NSTextView preview.
    private func scrollTextViewTo(_ line: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let range = ns.range(of: line)
        guard range.location != NSNotFound else { return }
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        tv.showFindIndicator(for: range)
    }
}

extension PreviewWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !isLoadingFromDisk else { return }
        isDirty = true
    }
}

/// Carries the full snippet payload (including its trailing space) so the
/// button's visible title can be trimmed for display without losing the
/// literal prefix the user wants inserted.
private final class SnippetButton: NSButton {
    var payload: String = ""
}

// MARK: - ⌘F search overlay

/// Drives the preview window's ⌘F search overlay. Kept separate from the
/// capture panel's `NoteEditorState` so the two features can't accidentally
/// couple; the shape is otherwise identical.
final class PreviewSearchState: ObservableObject {
    @Published var active: Bool = false
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    /// Supplied by the controller so the overlay doesn't need to know whether
    /// we're currently showing the WKWebView (read disk) or NSTextView (read
    /// buffer) preview.
    var performSearch: ((String) -> [SearchResult])? = nil
    /// Invoked when the user clicks a result row — scrolls the preview content
    /// to that line and highlights it. Overlay stays open.
    var onSelect: ((SearchResult) -> Void)? = nil
}

/// Dark floating search overlay for the preview window. Mirrors the capture
/// panel's search view one-for-one (see `NoteEditorView.searchView` in
/// JotbookApp.swift) so the two read as the same feature.
struct PreviewSearchOverlay: View {
    @ObservedObject var state: PreviewSearchState
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes", text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onChange(of: state.query) { query in
                        state.results = state.performSearch?(query) ?? []
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            resultsList
        }
        .frame(width: 320)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        .preferredColorScheme(.dark)
        .onAppear {
            // Slight delay: SwiftUI needs a render pass before the TextField
            // is ready to accept focus from FocusState. Without this, the
            // first-responder chain and the focus assignment can race and
            // the field ends up unfocused.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                fieldFocused = true
            }
        }
    }

    @ViewBuilder private var resultsList: some View {
        if state.query.isEmpty {
            VStack(spacing: 4) {
                Text("Search notes or dates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Typing a date (e.g. 2026-04-24) surfaces every entry under that header.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Text("Esc to close search.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if state.results.isEmpty {
            Text("No matches.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.results) { result in
                        Button(action: { state.onSelect?(result) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                if !result.stamp.isEmpty {
                                    Text(result.stamp)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
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
            .frame(maxHeight: 260)
        }
    }
}

enum PreviewHTML {
    static func render(_ markdown: String) -> String {
        let body = MarkdownToHTML.convert(markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.5;
            padding: 24px;
            max-width: 760px;
            margin: 0 auto;
            color: #222;
            background: #fff;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #e4e4e4; background: #000; }
            code, pre { background: #1a1a1a; }
            h1 { border-bottom-color: #333; }
            a { color: #4ea1f4; }
        }
        h1 { font-size: 22px; border-bottom: 1px solid #ddd; padding-bottom: 6px; margin: 12px 0 16px; }
        h2 { font-size: 18px; margin: 18px 0 8px; }
        h3 {
            font-size: 12px;
            color: #888;
            font-weight: 600;
            margin: 20px 0 4px;
            font-family: -apple-system-monospaced, "SF Mono", monospace;
        }
        h4, h5, h6 { margin: 12px 0 4px; }
        p { margin: 6px 0; }
        code {
            background: #f0f0f0;
            padding: 1px 5px;
            border-radius: 3px;
            font-family: "SF Mono", Menlo, monospace;
            font-size: 12.5px;
        }
        a { color: #0066cc; text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 600; }
        em { font-style: italic; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

enum MarkdownToHTML {
    static func convert(_ markdown: String) -> String {
        var html = ""
        let lines = markdown.components(separatedBy: "\n")
        var inParagraph = false

        func closeParagraph() {
            if inParagraph {
                html += "</p>\n"
                inParagraph = false
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                closeParagraph()
                continue
            }

            if let (level, text) = headerMatch(trimmed) {
                closeParagraph()
                html += "<h\(level)>\(inlineMarkdown(text))</h\(level)>\n"
                continue
            }

            if inParagraph {
                html += "<br>\n"
            } else {
                html += "<p>"
                inParagraph = true
            }
            html += inlineMarkdown(line)
        }
        closeParagraph()
        return html
    }

    private static func headerMatch(_ line: String) -> (Int, String)? {
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func inlineMarkdown(_ s: String) -> String {
        var r = escape(s)
        r = regex(r, #"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
        r = regex(r, #"\*([^*]+)\*"#, "<em>$1</em>")
        r = regex(r, "`([^`]+)`", "<code>$1</code>")
        r = regex(r, #"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>")
        return r
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func regex(_ s: String, _ pattern: String, _ replacement: String) -> String {
        guard let r = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(location: 0, length: s.utf16.count)
        return r.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
    }
}
