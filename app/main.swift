// WWB Overlay: a thin native shell around player.html and render.py.
//
// - Hosts the player in a WKWebView loaded from the app bundle.
// - Files dropped on the window (or picked via File > Open) are handed to the page by path:
//   the video as a file:// URL (the web view has read access), the .tline and .shw through a
//   custom "wwb://file/..." scheme served by this app with byte-range support.
// - File > Render Overlay renders natively (Panel.swift + Render.swift) with the page's current
//   sync anchor and options. "WWB Overlay" --render ... does the same from the command line.
//
// Built by app/build.sh with swiftc; no Xcode project needed.

import Cocoa
import WebKit
import UniformTypeIdentifiers

let appName = "WWB Overlay"
let schemeName = "wwb"

// MARK: - custom scheme: wwb://app/<bundle resource>  and  wwb://file/<absolute path>

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    private var stopped = Set<ObjectIdentifier>()

    private func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "xml", "shw": return "application/xml"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path: String
        if url.host == "file" {
            path = url.path
        } else if url.host == "app", let res = Bundle.main.resourceURL {
            path = res.appendingPathComponent(String(url.path.dropFirst())).path
        } else {
            task.didFailWithError(NSError(domain: "wwb", code: 404)); return
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let fh = FileHandle(forReadingAtPath: path) else {
            task.didFailWithError(NSError(domain: "wwb", code: 404, userInfo: [NSLocalizedDescriptionKey: "not found: \(path)"]))
            return
        }
        var start: Int64 = 0, end: Int64 = size - 1, status = 200
        if let r = task.request.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
            let spec = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map { Int64($0) }
            if spec.count == 2 {
                if let a = spec[0] { start = a; end = spec[1] ?? (size - 1) }
                else if let b = spec[1] { start = max(0, size - b) }
                status = 206
            }
        }
        end = min(end, size - 1)
        if start > end || start >= size {
            let resp = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": "bytes */\(size)"])!
            task.didReceive(resp); task.didFinish(); return
        }
        var headers = ["Content-Type": mime(path), "Content-Length": "\(end - start + 1)",
                       "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)

        let id = ObjectIdentifier(task)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? fh.close() }
            try? fh.seek(toOffset: UInt64(start))
            var remaining = end - start + 1
            while remaining > 0 {
                let chunk = fh.readData(ofLength: Int(min(remaining, 1 << 20)))
                if chunk.isEmpty { break }
                remaining -= Int64(chunk.count)
                let done = remaining <= 0
                var cancelled = false
                DispatchQueue.main.sync {
                    guard let self = self else { cancelled = true; return }
                    if self.stopped.contains(id) { self.stopped.remove(id); cancelled = true; return }
                    task.didReceive(chunk)
                    if done { task.didFinish() }
                }
                if cancelled { return }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

// MARK: - web view that accepts Finder drops natively

final class DropWebView: WKWebView {
    var onFiles: (([URL]) -> Void)?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        if urls.isEmpty { return super.performDragOperation(sender) }
        onFiles?(urls)
        return true
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: DropWebView!
    var files: [String: URL] = [:]           // "video", "tline", "shw"
    var renderer: Renderer?
    var progressPanel: NSPanel?
    var progressLabel: NSTextField?
    var progressBar: NSProgressIndicator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        makeWindow()
        loadPlayer()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) { open(urls: urls) }

    // --- window / web view
    func makeWindow() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(), forURLScheme: schemeName)
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let flag = WKUserScript(source: "window.__wwbApp = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(flag)

        webView = DropWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820), configuration: config)
        webView.navigationDelegate = self
        webView.onFiles = { [weak self] urls in self?.open(urls: urls) }

        window = NSWindow(contentRect: webView.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = appName
        window.contentView = webView
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("main")
        if window.frame.width < 720 { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func loadPlayer() {
        guard let html = Bundle.main.url(forResource: "player", withExtension: "html") else {
            alert("player.html is missing from the app bundle."); return
        }
        // read access to "/" so <video src="file:///..."> works for any dropped file
        webView.loadFileURL(html, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { push() }

    // --- files
    func open(urls: [URL]) {
        for u in urls {
            switch u.pathExtension.lowercased() {
            case "tline": files["tline"] = u
            case "shw", "xml": files["shw"] = u
            default: files["video"] = u
            }
        }
        push()
    }

    func wwbURL(_ u: URL) -> String {
        let p = u.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? u.path
        return "\(schemeName)://file\(p)"
    }

    func push() {
        // open-file events can arrive before applicationDidFinishLaunching; the page load pushes later
        guard !files.isEmpty, let webView = webView, let window = window else { return }
        var spec: [String: String] = [:]
        if let v = files["video"] { spec["video"] = v.absoluteString; spec["videoName"] = v.lastPathComponent }
        if let t = files["tline"] { spec["tline"] = wwbURL(t); spec["tlineName"] = t.lastPathComponent }
        if let s = files["shw"] { spec["shw"] = wwbURL(s) }
        guard let data = try? JSONSerialization.data(withJSONObject: spec),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.wwbLoad && wwbLoad(\(json))") { _, err in
            if let err = err { NSLog("wwbLoad: \(err)") }
        }
        var parts: [String] = []
        if let v = files["video"] { parts.append(v.lastPathComponent) }
        if let t = files["tline"] { parts.append(t.lastPathComponent) }
        window.title = parts.isEmpty ? appName : "\(appName): " + parts.joined(separator: " + ")
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose a video, a .tline recording and optionally a .shw show file"
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .xml]
        if let t = UTType(filenameExtension: "tline") { types.append(t) }
        if let s = UTType(filenameExtension: "shw") { types.append(s) }
        panel.allowedContentTypes = types
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK { self?.open(urls: panel.urls) }
        }
    }

    @objc func reloadPlayer(_ sender: Any?) { loadPlayer() }

    @objc func goToTime(_ sender: Any?) {
        let videoField = NSTextField(string: "")
        videoField.placeholderString = "m:ss.s or h:mm:ss"
        let wallField = NSTextField(string: "")
        wallField.placeholderString = "HH:MM:SS as WWB shows it"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Video time"), videoField],
                                      [NSTextField(labelWithString: "or wall clock"), wallField]])
        grid.rowSpacing = 8; grid.columnSpacing = 10; grid.column(at: 0).xPlacement = .trailing
        for f in [videoField, wallField] { f.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        let a = NSAlert()
        a.messageText = "Go to Time"
        a.informativeText = "Jump the video to a time, or to a WWB wall-clock time through the sync anchor."
        a.accessoryView = grid
        a.addButton(withTitle: "Go"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = videoField
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let v = videoField.stringValue.trimmingCharacters(in: .whitespaces)
        let w = wallField.stringValue.trimmingCharacters(in: .whitespaces)
        var js = ""
        if !v.isEmpty, let t = WallClock.parseVideoTime(v) { js = "wwbSeek({video: \(t)})" }
        else if !w.isEmpty, let d = try? JSONSerialization.data(withJSONObject: ["wall": w]), let j = String(data: d, encoding: .utf8) { js = "wwbSeek(\(j))" }
        guard !js.isEmpty else { return }
        webView.evaluateJavaScript(js) { result, _ in
            if (result as? Bool) == false { self.alert("Could not jump there. Load a .tline and set the anchor first for wall-clock times.") }
        }
    }

    // --- render
    @objc func renderOverlay(_ sender: Any?) {
        guard let tline = files["tline"] else { alert("Load a .tline recording first."); return }
        let js = "JSON.stringify(Object.assign({}, opts, {t: document.getElementById('v').currentTime || 0}))"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            var opts: [String: Any] = [:]
            if let s = result as? String, let d = s.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { opts = o }
            self.showRenderSheet(tline: tline, opts: opts)
        }
    }

    func showRenderSheet(tline: URL, opts: [String: Any]) {
        let t = (opts["t"] as? Double) ?? 0
        let startField = NSTextField(string: Self.fmtTime(t))
        let durField = NSTextField(string: "60")
        let sizeField = NSTextField(string: "1920x1080")
        let fpsField = NSTextField(string: "29.97")
        let codec = NSPopUpButton(frame: .zero, pullsDown: false)
        codec.addItems(withTitles: ["ProRes 4444 (alpha)", "HEVC (alpha, smaller files)", "PNG sequence (alpha)"])
        let burn = NSButton(checkboxWithTitle: "Also make a burned-in preview MP4", target: nil, action: nil)
        burn.state = files["video"] != nil ? .on : .off
        burn.isEnabled = files["video"] != nil

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Start (video time)"), startField],
            [NSTextField(labelWithString: "Duration (s)"), durField],
            [NSTextField(labelWithString: "Size"), sizeField],
            [NSTextField(labelWithString: "Frame rate"), fpsField],
            [NSTextField(labelWithString: "Codec"), codec],
            [NSGridCell.emptyContentView, burn],
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for f in [startField, durField, sizeField, fpsField] { f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: 210)

        let a = NSAlert()
        a.messageText = "Render Overlay"
        let anchor = "\(opts["anchorVideo"] ?? "?") = \(opts["anchorWall"] ?? "?"), trim \(opts["trim"] ?? 0) s"
        a.informativeText = "Uses the player's sync anchor (\(anchor)) and display options."
        a.accessoryView = grid
        a.addButton(withTitle: "Render…"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = startField
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let codecArg: OverlayCodec = [.prores, .hevc, .png][codec.indexOfSelectedItem]
        let wantBurn = burn.state == .on && files["video"] != nil
        let base = tline.deletingPathExtension().lastPathComponent + "_overlay"
        if codecArg == .png {
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "Render Here"; p.message = "Choose a folder for the PNG sequence"
            guard p.runModal() == .OK, let dir = p.url else { return }
            run(tline: tline, opts: opts, start: startField.stringValue, dur: durField.stringValue, size: sizeField.stringValue,
                fps: fpsField.stringValue, codec: codecArg, out: dir, burn: false)
        } else {
            let p = NSSavePanel(); p.nameFieldStringValue = base + ".mov"
            p.allowedContentTypes = [.quickTimeMovie]
            guard p.runModal() == .OK, let out = p.url else { return }
            run(tline: tline, opts: opts, start: startField.stringValue, dur: durField.stringValue, size: sizeField.stringValue,
                fps: fpsField.stringValue, codec: codecArg, out: out, burn: wantBurn)
        }
    }

    func run(tline: URL, opts: [String: Any], start: String, dur: String, size: String, fps: String, codec: OverlayCodec, out: URL, burn: Bool) {
        var job = RenderJob(tlineURL: tline, start: WallClock.parseVideoTime(start) ?? 0, duration: Double(dur) ?? 60, out: out)
        job.shwURL = files["shw"]
        if let v = opts["anchorVideo"] as? String { job.anchorVideo = WallClock.parseVideoTime(v) ?? job.anchorVideo }
        if let w = opts["anchorWall"] as? String { job.anchorWall = w }
        if let t = opts["trim"] as? NSNumber { job.trim = t.doubleValue }
        let dims = size.lowercased().split(separator: "x")
        if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) { job.width = w; job.height = h }
        (job.fpsNum, job.fpsDen) = RenderCLI.fps(fps)
        job.codec = codec
        if let sc = opts["scale"] as? NSNumber { job.options.scale = sc.doubleValue }
        if let op = opts["opacity"] as? NSNumber { job.options.opacity = op.doubleValue }
        if let side = opts["side"] as? String { job.options.side = side }
        job.options.showIdle = (opts["showIdle"] as? Bool) == true
        job.options.history = (opts["showSpark"] as? Bool) != false
        if burn, let v = files["video"] {
            job.burnIn = v
            job.burnOut = out.deletingPathExtension().appendingPathExtension("preview.mp4")
        }
        let renderer = Renderer()
        self.renderer = renderer
        showProgress(title: "Rendering " + out.lastPathComponent)
        renderer.onFraction = { [weak self] f in DispatchQueue.main.async { self?.progressBar?.doubleValue = f * 100 } }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do {
                try renderer.run(job) { msg in DispatchQueue.main.async { self?.progressLabel?.stringValue = msg } }
            } catch { failure = error }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progressPanel?.close(); self.progressPanel = nil; self.renderer = nil
                if let f = failure {
                    if case RenderError.cancelled = f { return }
                    self.alert("Render failed: \(f.localizedDescription)")
                } else {
                    let a = NSAlert(); a.messageText = "Render finished"
                    a.informativeText = out.path
                    a.addButton(withTitle: "Reveal in Finder"); a.addButton(withTitle: "OK")
                    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                }
            }
        }
    }

    func showProgress(title: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
                            styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        let label = NSTextField(labelWithString: "Starting…")
        label.frame = NSRect(x: 20, y: 70, width: 420, height: 20)
        label.lineBreakMode = .byTruncatingMiddle
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 44, width: 420, height: 16))
        bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 100; bar.doubleValue = 0
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRender(_:)))
        cancel.frame = NSRect(x: 360, y: 8, width: 80, height: 28)
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(bar); panel.contentView?.addSubview(cancel)
        panel.center(); panel.makeKeyAndOrderFront(nil)
        progressPanel = panel; progressLabel = label; progressBar = bar
    }

    @objc func cancelRender(_ sender: Any?) { renderer?.cancelled = true }

    // --- helpers

    static func fmtTime(_ t: Double) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = t - Double(h * 3600 + m * 60)
        return h > 0 ? String(format: "%d:%02d:%04.1f", h, m, s) : String(format: "%d:%04.1f", m, s)
    }

    func alert(_ text: String) {
        let a = NSAlert(); a.messageText = appName; a.informativeText = text; a.runModal()
    }

    // --- menu
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File"); fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Go to Time…", action: #selector(goToTime(_:)), keyEquivalent: "g")
        fileMenu.addItem(withTitle: "Render Overlay…", action: #selector(renderOverlay(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        let reload = fileMenu.addItem(withTitle: "Reload Player", action: #selector(reloadPlayer(_:)), keyEquivalent: "r")
        reload.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

if CommandLine.arguments.contains("--render") {
    exit(RenderCLI.main(CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
