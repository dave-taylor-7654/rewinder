// Rewinder.app — menu-bar host for the whole system.
//
// One signed app owns everything macOS permissions care about:
//   - captures in-process (Screen Recording grant = this app, via a normal
//     system prompt): one-shot screenshot of the mouse's display (DRM-safe),
//     Vision OCR at full res, idle-frame dedup, frontmost-app tagging,
//     bundled-WebP encoding, spool-to-local when storage is unwritable
//   - embeds the timeline server (Server.swift) in-process
//   - self-installs its launchd agent on first launch; a manual launch just
//     ensures the agent copy is running and opens the UI

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision
import WebKit

let HOME = NSHomeDirectory()
let REWINDER_HOME = HOME + "/rewinder"
let UI_URL = "http://127.0.0.1:8787"
let AGENT_LABEL = "com.dtav.rewinder"
let AGENT_PLIST = HOME + "/Library/LaunchAgents/\(AGENT_LABEL).plist"
let CAPTURE_LOG = HOME + "/Library/Logs/rewinder-capture.log"
let SERVER_LOG = HOME + "/Library/Logs/rewinder-server.log"

func log(_ s: String) {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(fmt.string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: CAPTURE_LOG) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(toFile: CAPTURE_LOG, atomically: true, encoding: .utf8)
    }
}

@discardableResult
func sh(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - config

struct Config {
    var dataDir = REWINDER_HOME + "/data"
    var quality = 25
    var maxDim: CGFloat = 2560
    var ffmpeg = "/usr/local/bin/ffmpeg"
    var dedup = true
    var dedupThreshold = 0.008
    var dedupForceMinutes = 10.0
    var excludeApps: [String] = []
    var captureInterval = 60.0   // seconds between capture ticks (10–600)
    var launchAtLogin = true

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: REWINDER_HOME + "/config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return c }
        if let v = json["data_dir"] as? String, !v.isEmpty { c.dataDir = (v as NSString).expandingTildeInPath }
        if let v = json["quality"] as? Int { c.quality = max(5, min(100, v)) }
        if let v = json["max_dim"] as? Int { c.maxDim = CGFloat(v) }
        if let v = json["ffmpeg"] as? String, !v.isEmpty { c.ffmpeg = v }
        if let v = json["dedup"] as? Bool { c.dedup = v }
        if let v = json["dedup_threshold"] as? Double { c.dedupThreshold = v }
        if let v = json["dedup_force_minutes"] as? Double { c.dedupForceMinutes = v }
        if let v = json["exclude_apps"] as? [String] { c.excludeApps = v }
        if let v = json["capture_interval"] as? Double { c.captureInterval = min(600, max(10, v)) }
        if let v = json["launch_at_login"] as? Bool { c.launchAtLogin = v }
        return c
    }
}

// MARK: - capture pipeline (unchanged semantics from the CLI era)

let FP_W = 64, FP_H = 36
let FP_STATE = REWINDER_HOME + "/.last-frame"

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    return false
}

func mouseDisplayID() -> CGDirectDisplayID {
    let loc = CGEvent(source: nil)?.location ?? .zero
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    for id in ids where CGDisplayBounds(id).contains(loc) { return id }
    return CGMainDisplayID()
}

func fingerprint(_ image: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: FP_W * FP_H)
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: FP_W, height: FP_H,
                                  bitsPerComponent: 8, bytesPerRow: FP_W,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: FP_W, height: FP_H))
    }
    return buf
}

func isIdleDuplicate(_ fp: [UInt8], display: CGDirectDisplayID, cfg: Config) -> Bool {
    guard cfg.dedup,
          let data = try? Data(contentsOf: URL(fileURLWithPath: FP_STATE)),
          data.count == 12 + fp.count else { return false }
    let ts = data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
    let prevDisplay = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
    if prevDisplay != UInt32(display) { return false }
    if Date().timeIntervalSince1970 - ts > cfg.dedupForceMinutes * 60 { return false }
    let prev = [UInt8](data.suffix(fp.count))
    var changed = 0
    for i in 0..<fp.count where abs(Int(fp[i]) - Int(prev[i])) > 12 { changed += 1 }
    return Double(changed) / Double(fp.count) < cfg.dedupThreshold
}

func saveFingerprint(_ fp: [UInt8], display: CGDirectDisplayID) {
    var t = Date().timeIntervalSince1970
    var d = UInt32(display)
    var data = Data(bytes: &t, count: 8)
    data.append(Data(bytes: &d, count: 4))
    data.append(contentsOf: fp)
    try? data.write(to: URL(fileURLWithPath: FP_STATE))
}

func ocr(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil else { return "" }
    return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}

func downscale(_ image: CGImage, maxDim: CGFloat) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let scale = min(1.0, maxDim / max(w, h))
    if scale >= 1.0 { return image }
    let nw = Int(w * scale), nh = Int(h * scale)
    guard let ctx = CGContext(data: nil, width: nw, height: nh,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? image
}

func writeImage(_ image: CGImage, to url: URL, uti: CFString, quality: Double?) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
        throw NSError(domain: "rewinder", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGImageDestination failed"])
    }
    var props: [CFString: Any] = [:]
    if let q = quality { props[kCGImageDestinationLossyCompressionQuality] = q }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "rewinder", code: 2, userInfo: [NSLocalizedDescriptionKey: "image finalize failed"])
    }
}

func encodeWebP(_ image: CGImage, stem: String, dayDir: URL, cfg: Config) -> String? {
    // encoder preference: bundled cwebp (self-contained) → ffmpeg → caller's JPEG fallback
    let bundled = (Bundle.main.resourcePath ?? "") + "/cwebp"
    let fm = FileManager.default
    var args: [String]? = nil
    let tmp = dayDir.appendingPathComponent(".\(stem).tmp.png")
    let out = dayDir.appendingPathComponent(stem + ".webp")
    if fm.isExecutableFile(atPath: bundled) {
        args = [bundled, "-quiet", "-preset", "text", "-q", String(cfg.quality), tmp.path, "-o", out.path]
    } else if fm.isExecutableFile(atPath: cfg.ffmpeg) {
        args = [cfg.ffmpeg, "-y", "-loglevel", "error", "-i", tmp.path,
                "-c:v", "libwebp", "-preset", "text", "-quality", String(cfg.quality), out.path]
    }
    guard let cmd = args else { return nil }
    defer { try? fm.removeItem(at: tmp) }
    do { try writeImage(image, to: tmp, uti: "public.png" as CFString, quality: nil) }
    catch { return nil }
    let status = sh(cmd)
    guard status == 0, fm.fileExists(atPath: out.path) else {
        try? fm.removeItem(at: out)
        return nil
    }
    return stem + ".webp"
}

func store(_ image: CGImage, text: String, meta: [String: String],
           base: String, day: String, stem: String, cfg: Config) throws -> String {
    let dayDir = URL(fileURLWithPath: base).appendingPathComponent(day)
    try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
    var name = encodeWebP(image, stem: stem, dayDir: dayDir, cfg: cfg)
    if name == nil {
        try writeImage(image, to: dayDir.appendingPathComponent(stem + ".jpg"),
                       uti: "public.jpeg" as CFString, quality: 0.55)
        name = stem + ".jpg"
    }
    if let mdata = try? JSONSerialization.data(withJSONObject: meta) {
        try? mdata.write(to: dayDir.appendingPathComponent(stem + ".json"))
    }
    try text.write(to: dayDir.appendingPathComponent(stem + ".txt"), atomically: true, encoding: .utf8)
    return name!
}

enum CaptureResult {
    case ok(String)       // description for the menu
    case spooled(String)
    case skipped(String)  // idle / locked / asleep
    case denied
    case failed(String)
}

func captureOnce(frontApp: NSRunningApplication?) async -> CaptureResult {
    if isScreenLocked() { return .skipped("screen locked") }
    let displayID = mouseDisplayID()
    if CGDisplayIsAsleep(displayID) != 0 { return .skipped("display asleep") }
    let cfg = Config.load()

    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        return .denied
    }
    guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
        return .failed("no displays")
    }

    // privacy: erase ignored apps' windows from the frame itself — capture
    // continues, but their content never lands on disk, focused or not.
    // Rewinder's own windows are always excluded (no timeline-of-the-timeline).
    let selfBundle = (Bundle.main.bundleIdentifier ?? "com.dtav.rewinder").lowercased()
    let excluded = content.windows.filter { w in
        guard let owner = w.owningApplication else { return false }
        let name = owner.applicationName.lowercased()
        let bundle = owner.bundleIdentifier.lowercased()
        if bundle == selfBundle { return true }
        return cfg.excludeApps.contains { ex in
            let e = ex.lowercased()
            return !e.isEmpty && (e == name || e == bundle)
        }
    }

    let filter = SCContentFilter(display: display, excludingWindows: excluded)
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    config.width = Int(filter.contentRect.width * scale)
    config.height = Int(filter.contentRect.height * scale)
    config.showsCursor = true
    let image: CGImage
    do {
        image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    } catch {
        return .denied
    }

    let fp = fingerprint(image)
    if isIdleDuplicate(fp, display: display.displayID, cfg: cfg) {
        return .skipped("idle duplicate")
    }

    let meta = ["app": frontApp?.localizedName ?? "",
                "bundle": frontApp?.bundleIdentifier ?? ""]
    let text = ocr(image)
    let stored = downscale(image, maxDim: cfg.maxDim)

    let now = Date()
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
    let timeFmt = DateFormatter(); timeFmt.dateFormat = "HHmmss"
    let day = dayFmt.string(from: now)
    let stem = timeFmt.string(from: now)
    let timeStr = "\(stem.prefix(2)):\(stem.dropFirst(2).prefix(2)):\(stem.suffix(2))"
    let appName = meta["app"] ?? ""

    do {
        let name = try store(stored, text: text, meta: meta, base: cfg.dataDir, day: day, stem: stem, cfg: cfg)
        saveFingerprint(fp, display: display.displayID)
        log("captured \(day)/\(name) display=\(display.displayID) ocr_chars=\(text.count) app=\(appName)")
        return .ok("\(timeStr) · \(appName)")
    } catch {
        do {
            let name = try store(stored, text: text, meta: meta, base: REWINDER_HOME + "/spool",
                                 day: day, stem: stem, cfg: cfg)
            saveFingerprint(fp, display: display.displayID)
            log("captured (SPOOLED, \(cfg.dataDir) unwritable) \(day)/\(name) app=\(appName)")
            return .spooled("\(timeStr) · \(appName)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - native timeline window (chromeless WebView onto the local UI)

final class TimelineWindow: NSObject, WKNavigationDelegate {
    static let shared = TimelineWindow()
    var window: NSWindow?
    var webView: WKWebView?
    var retries = 0

    func show(settings: Bool = false) {
        if window == nil { build() }
        if settings {
            webView?.load(URLRequest(url: URL(string: UI_URL + "/?settings=1")!))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Rewinder"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(calibratedWhite: 0.066, alpha: 1)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 480)
        w.center()
        w.setFrameAutosaveName("RewinderTimeline")
        let wv = WKWebView(frame: rect)
        wv.navigationDelegate = self
        wv.autoresizingMask = [.width, .height]
        w.contentView = wv
        wv.load(URLRequest(url: URL(string: UI_URL)!))
        window = w
        webView = wv
    }

    // server may still be coming up when the window opens — retry quietly
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard retries < 30 else { return }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { webView.reload() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { retries = 0 }
}

// MARK: - app delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var capturing = false
    var pausedUntil: Date?
    var lastCapture = "—"
    var health = "STARTING"        // shown in the menu
    var hadAccessAtLaunch = CGPreflightScreenCaptureAccess()

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(atPath: REWINDER_HOME, withIntermediateDirectories: true)
        installAgentIfNeeded()
        setupStatusItem()
        RewinderServer.shared.start()

        if !hadAccessAtLaunch { _ = CGRequestScreenCaptureAccess() }

        // a manual launch (Finder/Dock/open -a) asks the running instance to
        // show the timeline window
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.dtav.rewinder.open"),
            object: nil, queue: .main) { _ in TimelineWindow.shared.show() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.tick() }
        scheduleCapture()

        // screen-recording grants only take effect on relaunch; exit(1) makes
        // launchd (KeepAlive on non-zero exit) bring us back with the grant live
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, !self.hadAccessAtLaunch else { return }
            if CGPreflightScreenCaptureAccess() {
                log("screen recording granted — relaunching to activate")
                exit(1)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        TimelineWindow.shared.show()
        return false
    }

    // MARK: status item + menu

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setState(recording: false, health: "STARTING")
    }

    // fast-reverse ◀◀ = recording, hollow ◁◁ = not; monochrome, follows menu bar theme
    func setState(recording: Bool, health: String) {
        self.health = health
        statusItem.button?.attributedTitle = NSAttributedString(
            string: recording ? "\u{25C0}\u{FE0E}\u{25C0}\u{FE0E}" : "\u{25C1}\u{FE0E}\u{25C1}\u{FE0E}",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .kern: -1.0])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.target = self
            return it
        }
        let status = item("REWINDER — \(health)", nil)
        status.isEnabled = false
        menu.addItem(status)
        let last = item("Last: \(lastCapture)", nil)
        last.isEnabled = false
        menu.addItem(last)
        menu.addItem(.separator())
        menu.addItem(item("Open Timeline", #selector(openUI), "o"))
        menu.addItem(item("Open in Browser", #selector(openBrowser)))
        menu.addItem(item("Settings…", #selector(openSettings), ","))
        menu.addItem(item("Capture Now", #selector(captureNow)))
        if let pu = pausedUntil, pu > Date() {
            let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
            menu.addItem(item("Resume Capture (paused until \(fmt.string(from: pu)))", #selector(resumeCapture)))
        } else {
            menu.addItem(item("Pause for 1 Hour", #selector(pauseHour)))
        }
        menu.addItem(.separator())
        let cfg = Config.load()
        let stor = item("Storage: \(cfg.dataDir)", nil)
        stor.isEnabled = false
        menu.addItem(stor)
        menu.addItem(item("Open Data Folder", #selector(openData)))
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(.separator())
            menu.addItem(item("Fix Screen Recording Permission…", #selector(fixPermission)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit (stops capture until next login)", #selector(quit), "q"))
    }

    @objc func openUI() { TimelineWindow.shared.show() }
    @objc func openBrowser() { NSWorkspace.shared.open(URL(string: UI_URL)!) }
    @objc func openSettings() { TimelineWindow.shared.show(settings: true) }
    @objc func openData() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.load().dataDir))
    }
    @objc func captureNow() { tick(force: true) }
    @objc func pauseHour() {
        pausedUntil = Date().addingTimeInterval(3600)
        setState(recording: false, health: "PAUSED")
        log("paused for 1 hour")
    }
    @objc func resumeCapture() {
        pausedUntil = nil
        log("resumed")
        tick(force: true)
    }
    @objc func fixPermission() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc func quit() {
        sh(["/bin/launchctl", "bootout", "gui/\(getuid())/\(AGENT_LABEL)"])
        NSApp.terminate(nil)   // reached only if bootout didn't already kill us
    }

    // MARK: capture loop

    var captureTimer: Timer?

    // one-shot chain instead of a repeating timer, so config.json interval
    // changes take effect on the next tick without a restart
    func scheduleCapture() {
        captureTimer = Timer.scheduledTimer(withTimeInterval: Config.load().captureInterval,
                                            repeats: false) { [weak self] _ in
            self?.tick()
            self?.scheduleCapture()
        }
    }

    func tick(force: Bool = false) {
        installAgentIfNeeded()   // cheap no-op unless config changed (e.g. launch-at-login toggle)
        guard !capturing else { return }
        if !force, let pu = pausedUntil {
            if Date() < pu { return }
            pausedUntil = nil
        }
        if force { pausedUntil = nil }
        capturing = true
        let front = NSWorkspace.shared.frontmostApplication
        Task.detached { [weak self] in
            let result = await captureOnce(frontApp: front)
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                switch result {
                case .ok(let d):
                    self.lastCapture = d
                    self.setState(recording: true, health: "ACTIVE")
                case .spooled(let d):
                    self.lastCapture = d + " (spooled)"
                    self.setState(recording: true, health: "ACTIVE (SPOOLING LOCALLY)")
                case .skipped:
                    if self.pausedUntil == nil, self.health != "STARTING" { return }
                    self.setState(recording: true, health: "ACTIVE")
                case .denied:
                    self.setState(recording: false, health: "NEEDS SCREEN RECORDING PERMISSION")
                case .failed(let e):
                    self.lastCapture = "error: \(e)"
                    self.setState(recording: false, health: "ERROR")
                    log("capture error: \(e)")
                }
            }
        }
    }

    // MARK: install

    func installAgentIfNeeded() {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": AGENT_LABEL,
            "ProgramArguments": [exe],
            "RunAtLoad": Config.load().launchAtLogin,
            "KeepAlive": ["SuccessfulExit": false],
            "EnvironmentVariables": ["REWINDER_AGENT": "1"],
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let existing = try? Data(contentsOf: URL(fileURLWithPath: AGENT_PLIST))
        if existing != data {
            try? data.write(to: URL(fileURLWithPath: AGENT_PLIST))
            log("installed launchd agent")
        }
    }
}

// MARK: - main

let isAgentInstance = ProcessInfo.processInfo.environment["REWINDER_AGENT"] == "1"

if !isAgentInstance {
    // Manual launch (Finder / open -a): make sure the managed instance exists,
    // then just open the UI and get out of the way.
    if let exe = Bundle.main.executablePath {
        let plist: [String: Any] = [
            "Label": AGENT_LABEL,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "EnvironmentVariables": ["REWINDER_AGENT": "1"],
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? FileManager.default.createDirectory(atPath: HOME + "/Library/LaunchAgents",
                                                 withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: AGENT_PLIST))
    }
    sh(["/bin/launchctl", "bootstrap", "gui/\(getuid())", AGENT_PLIST])
    sh(["/bin/launchctl", "kickstart", "gui/\(getuid())/\(AGENT_LABEL)"])
    Thread.sleep(forTimeInterval: 2.5)
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.dtav.rewinder.open"),
        object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
