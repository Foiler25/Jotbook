import AppKit
import WebKit

final class PreviewWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let webView: WKWebView
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1

    override init() {
        webView = WKWebView(frame: .zero)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jot Preview"
        window.contentView = webView
        window.center()
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        reload()
        setupWatcherIfEnabled()
    }

    func close() {
        window.orderOut(nil)
        stopWatcher()
    }

    var isVisible: Bool { window.isVisible }

    func reload() {
        let path = resolvedTargetPath()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let markdown: String
        if FileManager.default.fileExists(atPath: url.path) {
            markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? "_Could not read the file._"
        } else {
            markdown = "# No notes yet\n\nThe target file does not exist. Save a note to create it."
        }
        webView.loadHTMLString(PreviewHTML.render(markdown), baseURL: nil)
    }

    func refreshWatcher() {
        setupWatcherIfEnabled()
    }

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

    // NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        stopWatcher()
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
            body { color: #e4e4e4; background: #1e1e1e; }
            code, pre { background: #2b2b2b; }
            h1 { border-bottom-color: #444; }
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
