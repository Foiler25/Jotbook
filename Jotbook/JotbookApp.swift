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

import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine
import ServiceManagement
import Sparkle

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
    /// Reads the active Jotbook's target file from disk and searches it.
    static func search(_ query: String) -> [SearchResult] {
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return search(query, in: contents)
    }

    /// Searches a provided string. Useful when the caller has a buffer
    /// (e.g. the preview's editable NSTextView) that may differ from disk.
    /// Matches both on line content and on the enclosing `### ` timestamp
    /// header — a query like "2026-04-24" surfaces every entry written under
    /// that date header.
    static func search(_ query: String, in contents: String) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let lowerQuery = trimmed.lowercased()
        var results: [SearchResult] = []
        var currentStamp = ""
        var stampMatchesQuery = false
        for line in contents.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                currentStamp = String(line.dropFirst(4))
                stampMatchesQuery = currentStamp.lowercased().contains(lowerQuery)
                continue
            }
            if stampMatchesQuery || line.lowercased().contains(lowerQuery) {
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

/// Shared markdown-editing operations against an explicit `NSTextView`. The
/// capture editor resolves the text view via first-responder lookup; the
/// preview editor passes its own text view directly.
enum MarkdownFormatter {
    static func wrapSelection(in tv: NSTextView, left: String, right: String) {
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

    static func insertLink(in tv: NSTextView) {
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

    static func insertLinePrefix(in tv: NSTextView, _ prefix: String) {
        let range = tv.selectedRange()
        let ns = tv.string as NSString
        var lineStart = range.location
        while lineStart > 0 && ns.character(at: lineStart - 1) != 0x0A {
            lineStart -= 1
        }
        let prefixLen = (prefix as NSString).length
        if ns.length - lineStart >= prefixLen {
            let existing = ns.substring(with: NSRange(location: lineStart, length: prefixLen))
            if existing == prefix {
                tv.window?.makeFirstResponder(tv)
                return
            }
        }
        tv.insertText(prefix, replacementRange: NSRange(location: lineStart, length: 0))
        tv.setSelectedRange(NSRange(location: range.location + prefixLen, length: range.length))
        tv.window?.makeFirstResponder(tv)
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
        if showFormattingBar { h += 60 }
        return h
    }

    private var formattingBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                formatButton(label: "B", bold: true) { wrapSelection(left: "**", right: "**") }
                formatButton(label: "I", italic: true) { wrapSelection(left: "*", right: "*") }
                formatButton(label: "S", strikethrough: true) { wrapSelection(left: "~~", right: "~~") }
                formatButton(label: "<>") { wrapSelection(left: "`", right: "`") }
                formatButton(systemImage: "link") { insertLink() }
                Spacer()
            }
            HStack(spacing: 6) {
                formatButton(label: "H1") { insertLinePrefix("# ") }
                formatButton(label: "H2") { insertLinePrefix("## ") }
                formatButton(label: "H3") { insertLinePrefix("### ") }
                formatButton(label: "•") { insertLinePrefix("- ") }
                formatButton(label: "1.") { insertLinePrefix("1. ") }
                formatButton(label: ">") { insertLinePrefix("> ") }
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 60)
    }

    @ViewBuilder
    private func formatButton(label: String = "",
                              systemImage: String? = nil,
                              bold: Bool = false,
                              italic: Bool = false,
                              strikethrough: Bool = false,
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
                        .strikethrough(strikethrough)
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
                Text("Search notes or dates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Typing a date (e.g. 2026-04-24) surfaces every entry under that header.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
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
        MarkdownFormatter.wrapSelection(in: tv, left: left, right: right)
    }

    private func insertLink() {
        guard let tv = activeTextView() else { return }
        MarkdownFormatter.insertLink(in: tv)
    }

    private func insertLinePrefix(_ prefix: String) {
        guard let tv = activeTextView() else { return }
        MarkdownFormatter.insertLinePrefix(in: tv, prefix)
    }
}

// We always anchor the capture panel under the notch (on notched MacBooks)
// or to the screen-top center (on other displays) rather than to the status
// item. This keeps the panel reachable when the menubar icon is hidden by
// Bartender or a similar manager — and sidesteps a macOS 26 / notched-display
// bug where NSPopover resolves its anchor to off-screen coordinates and drops
// the popover into a screen corner.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Resolves the on-screen rect that the capture panel should hang from:
// the real notch on notched MacBooks (via NSScreen.auxiliaryTop{Left,Right}Area),
// or a synthetic top-center anchor just below the menubar otherwise. The
// screen is chosen by mouse location so multi-monitor setups open the panel
// where the user is looking.
private enum NotchAnchor {
    struct Info {
        var screen: NSScreen
        var centerX: CGFloat
        var bottomY: CGFloat
        var hasNotch: Bool
        var notchWidth: CGFloat
        var notchHeight: CGFloat
        // Current menubar reservation on this screen. Equals
        // frame.maxY - visibleFrame.maxY, which is the notched-menubar
        // height in normal mode and 0 when the menubar is auto-hidden
        // (e.g., a full-screen app is on this screen).
        var menubarHeight: CGFloat
    }

    static func resolve() -> Info {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let frame = screen.frame
        let menubarHeight = max(0, frame.maxY - screen.visibleFrame.maxY)

        if #available(macOS 12.0, *),
           let topLeft = screen.auxiliaryTopLeftArea,
           let topRight = screen.auxiliaryTopRightArea,
           topLeft != .zero, topRight != .zero {
            let notchHeight = max(topLeft.height, topRight.height)
            let notchWidth = max(0, frame.width - topLeft.width - topRight.width)
            let notchCenterX = (topLeft.maxX + topRight.minX) / 2
            return Info(
                screen: screen,
                centerX: notchCenterX,
                bottomY: screen.visibleFrame.maxY,
                hasNotch: true,
                notchWidth: notchWidth,
                notchHeight: notchHeight,
                menubarHeight: menubarHeight
            )
        }

        return Info(
            screen: screen,
            centerX: frame.midX,
            bottomY: screen.visibleFrame.maxY,
            hasNotch: false,
            notchWidth: 0,
            notchHeight: 0,
            menubarHeight: menubarHeight
        )
    }
}

// Top edge is straight at the full rect width; immediately below the top edge,
// concave scoops at the top-left and top-right curl the shape inward by
// shoulderRadius, narrowing down to a body of width (rect.width - 2*shoulderRadius).
// Bottom corners are standard rounded-rectangle corners. When the shape
// animates from (notchWidth, 0) up to (fullWidth, fullHeight), it reads as
// something "dripping" out of the notch and spilling outward.
struct NotchBlendShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set { shoulderRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = max(0, min(rect.width / 2, shoulderRadius))
        let br = max(0, min(rect.width / 2, bottomRadius))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// Mutable state driving the open/close + resize springs of the blended shell.
final class BlendUIState: ObservableObject {
    @Published var visible: Bool
    @Published var opacity: Double
    @Published var editorSize: CGSize

    init(editorSize: CGSize, visible: Bool = false, opacity: Double = 1) {
        self.editorSize = editorSize
        self.visible = visible
        self.opacity = opacity
    }
}

// SwiftUI shell that hosts the existing NoteEditorView inside the notch-blend
// shape and drives the open/close spring. The NSPanel stays at a fixed canvas
// size; everything springy happens inside this view.
//
// Layout (SwiftUI top-left origin, canvas top aligned with `frame.maxY` so
// the top `menubarHeight` of the canvas sits inside the menubar region):
//   y = 0                      panel top = screen top
//   y in [0, menubarHeight]    shape extends into menubar area; the top
//                              edge sits in/behind the physical notch on
//                              notched MacBooks
//   y ≥ menubarHeight          editor content — the whole shell is solid
//                              black so there's no seam between the
//                              notch-black and the editor area, and no
//                              visible edge against dark full-screen apps.
struct CapturePanelShell: View {
    @ObservedObject var state: NoteEditorState
    @ObservedObject var ui: BlendUIState
    let onOpenFile: () -> Void

    let canvasSize: CGSize
    let notchWidth: CGFloat
    let menubarHeight: CGFloat
    let shoulderRadius: CGFloat
    let bottomRadius: CGFloat
    // Extra room around the shape for the SwiftUI-drawn shadow. The outer
    // frame expands by this much so the shadow doesn't get clipped at the
    // NSWindow edge. Panel-level AppKit shadow is disabled when this path
    // is in use (see presentNotchBlendedPanel).
    let shadowPadding: CGFloat

    private var editorTopInset: CGFloat { menubarHeight }

    var body: some View {
        let bodyHeight = editorTopInset + ui.editorSize.height
        let shapeWidth = ui.visible ? canvasSize.width : max(notchWidth, 1)
        let shapeHeight = ui.visible ? bodyHeight : 0

        ZStack(alignment: .top) {
            NotchBlendShape(shoulderRadius: shoulderRadius, bottomRadius: bottomRadius)
                .fill(Color.black)
                .frame(width: shapeWidth, height: shapeHeight)
                .shadow(color: Color.black.opacity(0.32), radius: 14, x: 0, y: 6)
                .animation(
                    ui.visible
                        ? .spring(response: 0.42, dampingFraction: 0.80)
                        : .spring(response: 0.50, dampingFraction: 0.85),
                    value: ui.visible
                )

            NoteEditorView(state: state, onOpenFile: onOpenFile)
                .frame(width: ui.editorSize.width, height: ui.editorSize.height)
                .padding(.top, editorTopInset)
                .opacity(ui.visible ? 1 : 0)
                .animation(
                    ui.visible
                        ? .easeOut(duration: 0.26).delay(0.14)
                        : .easeIn(duration: 0.14),
                    value: ui.visible
                )
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .top)
        .padding(.horizontal, shadowPadding)
        .padding(.bottom, shadowPadding)
        .opacity(ui.opacity)
        // Force dark appearance so the editor controls (prefix bar, text
        // cursor, formatting buttons) render with dark-mode styling on top
        // of the pure-black shell. Without this they'd use system colors,
        // which look washed out in light mode.
        .preferredColorScheme(.dark)
    }
}

// NSView used as the panel's contentView when we're in notch-blend mode.
// Lets clicks on transparent shoulders fall through to the underlying app
// so the global click-outside monitor can dismiss the capture panel.
final class NotchCanvasView: NSView {
    var visibleShapePath: CGPath?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let path = visibleShapePath, !path.contains(local) { return nil }
        return super.hitTest(point)
    }
}

private enum CaptureMode {
    case fadeSlide
    case notchBlend
}

private struct RegisteredHotkey {
    var ref: EventHotKeyRef
    var action: () -> Void
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var captureWindow: CapturePanel?
    private var clickOutsideMonitor: Any?
    private var rightClickMenu: NSMenu!
    private var carbonHotkeys: [UInt32: RegisteredHotkey] = [:]
    private var carbonHandlerRef: EventHandlerRef?
    private var nextHotkeyID: UInt32 = 1
    private var popoverKeyMonitor: Any?
    private var originalStatusImage: NSImage?
    private var saveFlashToken = 0
    private var explicitlyDismissed = false
    private var escPressed = false
    private var captureMode: CaptureMode = .fadeSlide
    private var blendUIState: BlendUIState?
    // Set while a close animation is running so re-entry via
    // windowDidResignKey / globalMouseMonitor doesn't restart the animation
    // and snap-reset alphaValue.
    private var isClosing = false
    private let editorState = NoteEditorState()
    private var settingsWindow: NSWindow?
    private var previewController: PreviewWindowController?
    private var lastSeenPreviewEditable: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.previewEditable)

    lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()
    lazy var updaterViewModel = UpdaterViewModel(updaterController)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerUserDefaults()
        migrateDailyRotationFormatIfNeeded()
        Jotbooks.ensureAtLeastOne()
        installMainMenu()
        installStatusItem()
        buildRightClickMenu()
        registerAllHotkeys()

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutRecordingStarted),
            name: .jotShortcutRecordingStarted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutRecordingEnded),
            name: .jotShortcutRecordingEnded,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        _ = updaterController
    }

    @objc private func userDefaultsChanged() {
        let current = UserDefaults.standard.bool(forKey: DefaultsKey.previewEditable)
        guard current != lastSeenPreviewEditable else { return }
        lastSeenPreviewEditable = current
        previewController?.rebuildContentView()
    }

    @objc private func jotbooksChanged() {
        registerAllHotkeys()
        buildRightClickMenu()
    }

    @objc private func appBecameActive() {
        // Carbon hotkeys survive activation changes; no re-registration needed.
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

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Jotbook")
        image?.isTemplate = true
        originalStatusImage = image
        if let button = statusItem.button {
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // .accessory apps have no main menu by default, so standard Edit-menu
    // key equivalents (⌘X/⌘C/⌘V/⌘A/⌘Z/⌘⇧Z) never reach NSTextView. Install a
    // hidden main menu with an Edit submenu whose items target nil so AppKit
    // dispatches them through the responder chain to the focused text view.
    private func installMainMenu() {
        let edit = NSMenu(title: "Edit")

        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(undo)

        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)

        edit.addItem(.separator())

        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))

        let pasteMatch = NSMenuItem(
            title: "Paste and Match Style",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "V"
        )
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(pasteMatch)

        edit.addItem(.separator())

        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit

        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildRightClickMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open Jotbook", action: #selector(openFromMenu), keyEquivalent: "")
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

        let checkUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = updaterController
        menu.addItem(checkUpdates)

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

        let quitItem = NSMenuItem(title: "Quit Jotbook", action: #selector(quit), keyEquivalent: "")
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
            window.title = "Jotbook Settings"
            // Force dark + black chrome to match the capture panel's
            // always-dark style.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .black
            window.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(self.updaterViewModel)
                    .preferredColorScheme(.dark)
            )
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // NSWindowDelegate — release the settings window and its SwiftUI hosting view
    // when the user closes it, so next open starts fresh (and per-Jotbook row state
    // doesn't accumulate across sessions).
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === settingsWindow {
            closing.contentView = nil
            settingsWindow = nil
        }
    }

    // If the capture panel loses key focus to a window in another app (e.g.
    // the user cmd-tabs), dismiss it the same way a click-outside would.
    func windowDidResignKey(_ notification: Notification) {
        guard let resigning = notification.object as? NSWindow,
              resigning === captureWindow,
              resigning.isVisible else { return }
        closeCapture(explicit: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func togglePopover() {
        if let win = captureWindow, win.isVisible {
            closeCapture(explicit: true)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        isClosing = false
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

        let panel = captureWindow ?? makeCapturePanel()
        captureWindow = panel

        let anchor = NotchAnchor.resolve()
        let useBlend = anchor.hasNotch && !shouldReduceMotion()

        NSApp.activate(ignoringOtherApps: true)
        if useBlend {
            captureMode = .notchBlend
            presentNotchBlendedPanel(panel: panel, anchor: anchor)
        } else {
            captureMode = .fadeSlide
            blendUIState = nil
            presentFadeSlidePanel(panel: panel)
        }
        installPopoverKeyMonitor()
        installClickOutsideMonitor()
    }

    private func presentFadeSlidePanel(panel: CapturePanel) {
        // Fade-slide doesn't resize the window during the animation, so
        // AppKit's cached shadow traces the correct outline. Re-enable it in
        // case the panel was last used in notch-blend mode where it's off.
        panel.hasShadow = true

        let size = basePopoverSize()
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let host = NSHostingView(
            rootView: NoteEditorView(
                state: editorState,
                onOpenFile: { [weak self] in self?.openTargetFile() }
            )
            .preferredColorScheme(.dark)
        )
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container

        let finalFrame = capturePanelFrame(size: size)
        animateCapturePanelIn(panel, finalFrame: finalFrame)
    }

    private func presentNotchBlendedPanel(panel: CapturePanel, anchor: NotchAnchor.Info) {
        let editorSize = basePopoverSize()
        let searchSize = searchPopoverSize()
        let maxEditorHeight = max(editorSize.height, searchSize.height)

        let shoulderRadius: CGFloat = 14
        let bottomRadius: CGFloat = 16
        let shadowPadding: CGFloat = 24
        // Use the *current* menubar reservation, not the design-time notched
        // menubar height. When the menubar is hidden (full-screen app on
        // this screen), menubarHeight drops to 0 so the shell's top sits
        // right at the screen top instead of leaving a black band.
        let menubarHeight = anchor.menubarHeight

        // Canvas extends from the screen top (overlapping the menubar area
        // when present) down past the editor. The whole shell is solid
        // black so there's no collar/fade gap between the notch-black and
        // the editor area — the editor sits directly under the menubar.
        let editorTopInset = menubarHeight
        let canvasSize = CGSize(
            width: editorSize.width + shoulderRadius * 2,
            height: editorTopInset + maxEditorHeight
        )
        // Window is larger than the visible canvas so the SwiftUI .shadow on
        // the shape has room to render without being clipped. Extra space on
        // sides and below; no extra space on top since the shape's top edge
        // must land at frame.maxY.
        let windowSize = CGSize(
            width: canvasSize.width + shadowPadding * 2,
            height: canvasSize.height + shadowPadding
        )

        let uiState = BlendUIState(editorSize: editorSize)
        blendUIState = uiState

        let shell = CapturePanelShell(
            state: editorState,
            ui: uiState,
            onOpenFile: { [weak self] in self?.openTargetFile() },
            canvasSize: canvasSize,
            notchWidth: anchor.notchWidth,
            menubarHeight: menubarHeight,
            shoulderRadius: shoulderRadius,
            bottomRadius: bottomRadius,
            shadowPadding: shadowPadding
        )

        let canvas = NotchCanvasView(frame: NSRect(origin: .zero, size: windowSize))
        let host = NSHostingView(rootView: shell)
        host.frame = canvas.bounds
        host.autoresizingMask = [.width, .height]
        if #available(macOS 13.3, *) {
            host.safeAreaRegions = []
        }
        canvas.addSubview(host)
        panel.contentView = canvas
        panel.hasShadow = false

        let x = anchor.centerX - windowSize.width / 2
        let screenTop = anchor.screen.frame.maxY
        let y = screenTop - windowSize.height
        panel.setFrame(NSRect(x: x, y: y, width: windowSize.width, height: windowSize.height), display: false)

        // Fade-in animation. This one works reliably — we never figured out
        // why the symmetric close-path alpha fade doesn't render, even after
        // exhaustive investigation, so the close is effectively instant.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.alphaValue = 0
        NSAnimationContext.endGrouping()

        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 1
        }

        // Wait one display frame so SwiftUI commits the initial render at
        // visible=false before we flip to true.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak uiState] in
            uiState?.visible = true
        }
    }

    private func animateCapturePanelIn(_ panel: CapturePanel, finalFrame: NSRect) {
        if shouldReduceMotion() {
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let startFrame = finalFrame.offsetBy(dx: 0, dy: 6)
        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    private func makeCapturePanel() -> CapturePanel {
        // Borderless so macOS doesn't reserve a titlebar strip at the top of
        // the panel. Rounded corners + background are drawn by the content
        // view (see showPopover); shadow is still rendered by the window.
        let panel = CapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // .statusBar, not .popUpMenu. Panels at the popUpMenu level are
        // auto-dismissed by AppKit on outside click / key resign — it's the
        // level used for native menu popups — which snap-closes the window
        // before any animation can play. 
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // No .transient here: .transient lets macOS auto-orderOut the panel
        // when the user switches apps, which would bypass our close
        // animation entirely.
        panel.collectionBehavior = [.ignoresCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    private func capturePanelFrame(size: NSSize) -> NSRect {
        let anchor = NotchAnchor.resolve()
        let visible = anchor.screen.visibleFrame
        var x = anchor.centerX - size.width / 2
        x = max(visible.minX + 4, min(x, visible.maxX - size.width - 4))
        let y = anchor.bottomY - size.height - 2
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func resizeCapturePanel(to size: NSSize) {
        guard let panel = captureWindow else { return }
        switch captureMode {
        case .notchBlend:
            blendUIState?.editorSize = size
        case .fadeSlide:
            let target = capturePanelFrame(size: size)
            if shouldReduceMotion() {
                panel.setFrame(target, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                }
            }
        }
    }

    private func shouldReduceMotion() -> Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let win = self.captureWindow, win.isVisible else { return }
            self.closeCapture(explicit: false)
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }

    private func closeCapture(explicit: Bool) {
        guard let panel = captureWindow, panel.isVisible, !isClosing else { return }
        isClosing = true
        if explicit { explicitlyDismissed = true }
        handleCaptureDidClose()

        switch captureMode {
        case .notchBlend:
            closeNotchBlendedPanel(panel: panel)
        case .fadeSlide:
            closeFadeSlidePanel(panel: panel)
        }
    }

    private func closeFadeSlidePanel(panel: CapturePanel) {
        if shouldReduceMotion() {
            panel.orderOut(nil)
            panel.alphaValue = 1
            isClosing = false
            return
        }

        let exitFrame = panel.frame.offsetBy(dx: 0, dy: 4)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(exitFrame, display: true)
        }, completionHandler: { [weak self, weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self?.isClosing = false
        })
    }

    private func closeNotchBlendedPanel(panel: CapturePanel) {
        guard let ui = blendUIState else {
            panel.orderOut(nil)
            isClosing = false
            return
        }
        withAnimation(.spring(response: 0.40, dampingFraction: 0.85)) {
            ui.visible = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel, weak ui] in
            guard let self else { return }
            self.isClosing = false
            guard let panel, panel.alphaValue < 0.01 else { return }
            if self.blendUIState === ui {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
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
        if showFormatting { height += 60 }
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
                self.escPressed = true
                self.closeCapture(explicit: true)
                return nil
            }
            return event
        }
    }

    private func enterSearchMode() {
        editorState.searchQuery = ""
        editorState.searchResults = []
        editorState.searching = true
        resizeCapturePanel(to: searchPopoverSize())
    }

    private func exitSearchMode() {
        editorState.searching = false
        editorState.searchQuery = ""
        editorState.searchResults = []
        resizeCapturePanel(to: basePopoverSize())
    }

    private func handleCaptureDidClose() {
        removeClickOutsideMonitor()
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

        // Release the SwiftUI view tree, JotTextEditor's NSTextView (and its
        // accumulated undo manager), and the NoteTextViewHolder. Next
        // showPopover() installs a fresh content view.
        captureWindow?.contentView = nil
    }

    private func save() {
        let trimmed = editorState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            closeCapture(explicit: true)
            return
        }
        do {
            try NoteAppender.append(trimmed)
            editorState.text = ""
            closeCapture(explicit: true)
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

    // System-wide hotkeys use Carbon's RegisterEventHotKey. Unlike
    // NSEvent.addGlobalMonitorForEvents, this consumes the key event (so ⌥N
    // no longer types `˜` into whichever text field is focused) and does not
    // require Accessibility permission.
    private func registerAllHotkeys() {
        unregisterAllHotkeys()
        installCarbonHandlerIfNeeded()
        for (hk, action) in currentBindings() {
            var ref: EventHotKeyRef?
            let id = nextHotkeyID
            let hotKeyID = EventHotKeyID(signature: OSType(0x4A4F5442), id: id) // 'JOTB'
            let status = RegisterEventHotKey(
                UInt32(hk.keyCode),
                nsModifiersToCarbon(hk.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                carbonHotkeys[id] = RegisteredHotkey(ref: ref, action: action)
                nextHotkeyID &+= 1
            } else {
                NSLog("Jotbook: RegisterEventHotKey failed (status=\(status)) for keyCode=\(hk.keyCode) modifiers=\(hk.modifiers) — likely already claimed by another app.")
            }
        }
    }

    private func unregisterAllHotkeys() {
        for (_, registered) in carbonHotkeys {
            UnregisterEventHotKey(registered.ref)
        }
        carbonHotkeys.removeAll()
    }

    private func installCarbonHandlerIfNeeded() {
        guard carbonHandlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handler: @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                delegate.carbonHotkeys[id]?.action()
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &spec,
            selfPtr,
            &carbonHandlerRef
        )
    }

    private func nsModifiersToCarbon(_ raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
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
        if let win = captureWindow, win.isVisible {
            closeCapture(explicit: true)
        }
        showPopover()
    }

    private func openJotbookFile(at path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? Data("# Jotbook Notes\n\n".utf8).write(to: url)
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
        if let ctl = previewController, ctl.isVisible {
            ctl.close()
            return
        }
        let ctl = previewController ?? makePreviewController()
        previewController = ctl
        ctl.show()
    }

    private func makePreviewController() -> PreviewWindowController {
        let ctl = PreviewWindowController()
        ctl.onClose = { [weak self] in
            // Release the controller so ARC can tear down the WKWebView
            // and the WebContent XPC process.
            self?.previewController = nil
        }
        return ctl
    }

    @objc private func openTargetFile() {
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? Data("# Jotbook Notes\n\n".utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func hotkeyChanged() {
        registerAllHotkeys()
        buildRightClickMenu()
    }

    // The ShortcutRecorder captures keys via the responder chain, but Carbon
    // eats registered hotkeys before they reach the responder chain. Pause
    // registration while a recorder is active so users can re-assign a
    // currently-registered combo.
    @objc private func shortcutRecordingStarted() {
        unregisterAllHotkeys()
    }

    @objc private func shortcutRecordingEnded() {
        registerAllHotkeys()
    }
}

final class UpdaterViewModel: ObservableObject {
    private let updater: SPUUpdater
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init(_ controller: SPUStandardUpdaterController) {
        self.updater = controller.updater
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() { updater.checkForUpdates() }
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
            try Data("# Jotbook Notes\n\n".utf8).write(to: url)
        }
        let entry = "\n### \(stamp())\n\(text)\n"

        if UserDefaults.standard.bool(forKey: DefaultsKey.newestFirst) {
            var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            // Accept both the new and legacy headers so existing users' files still
            // receive newest-first entries in the right place.
            let headerCandidates = ["# Jotbook Notes\n\n", "# Jot Notes\n\n"]
            var insertionPoint: String.Index?
            for pattern in headerCandidates {
                if let range = contents.range(of: pattern) {
                    insertionPoint = range.upperBound
                    break
                }
            }
            if let idx = insertionPoint {
                contents.insert(contentsOf: entry, at: idx)
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
