// Rewinder's embedded timeline server — native Swift port of the former
// server.py, so the app has zero runtime dependencies. Serves the UI + JSON
// API on 127.0.0.1:8787 and indexes OCR sidecars into SQLite FTS5.
//
// Frame layout (written by the capture side in main.swift):
//   <data_dir>/YYYY-MM-DD/HHMMSS.webp|jpg   frame
//   <data_dir>/YYYY-MM-DD/HHMMSS.txt        OCR text (presence = frame complete)
//   <data_dir>/YYYY-MM-DD/HHMMSS.json       {app, bundle}

import Foundation
import SQLite3

let SERVER_PORT: UInt16 = 8787
let SCAN_INTERVAL: TimeInterval = 30
let CONFIG_PATH = REWINDER_HOME + "/config.json"
let SPOOL_DIR = REWINDER_HOME + "/spool"
let DB_PATH = REWINDER_HOME + "/index.db"
let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
let CTYPES: [String: String] = ["webp": "image/webp", "jpg": "image/jpeg",
                                "jpeg": "image/jpeg", "heic": "image/heic"]

func slog(_ s: String) {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(fmt.string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: SERVER_LOG) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(toFile: SERVER_LOG, atomically: true, encoding: .utf8)
    }
}

func isDayName(_ s: String) -> Bool {
    guard s.count == 10 else { return false }
    for (i, c) in s.enumerated() {
        if i == 4 || i == 7 { if c != "-" { return false } }
        else if !c.isNumber { return false }
    }
    return true
}

func shotStem(_ name: String) -> String? {
    let parts = name.split(separator: ".", maxSplits: 1)
    guard parts.count == 2, parts[0].count == 6, parts[0].allSatisfy({ $0.isNumber }),
          CTYPES[String(parts[1]).lowercased()] != nil else { return nil }
    return String(parts[0])
}

func epochOf(day: String, t: String) -> Int64 {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-ddHHmmss"
    return Int64(fmt.date(from: day + t)?.timeIntervalSince1970 ?? 0)
}

func todayString(offsetDays: Int = 0) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: Date().addingTimeInterval(Double(offsetDays) * 86400))
}

// MARK: - config (raw dict passthrough so unknown keys survive)

let configLock = NSLock()

func loadRawConfig() -> [String: Any] {
    var cfg: [String: Any] = [
        "data_dir": REWINDER_HOME + "/data", "quality": 25, "max_dim": 2560,
        "ffmpeg": "/usr/local/bin/ffmpeg", "legacy_dirs": [String](),
        "exclude_apps": [String](), "capture_interval": 60, "launch_at_login": true,
    ]
    if let d = try? Data(contentsOf: URL(fileURLWithPath: CONFIG_PATH)),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
        for (k, v) in j { cfg[k] = v }
    }
    return cfg
}

func saveRawConfig(_ cfg: [String: Any]) {
    configLock.lock(); defer { configLock.unlock() }
    guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) else { return }
    let tmp = CONFIG_PATH + ".tmp"
    try? data.write(to: URL(fileURLWithPath: tmp))
    try? FileManager.default.replaceItemAt(URL(fileURLWithPath: CONFIG_PATH), withItemAt: URL(fileURLWithPath: tmp))
}

func searchRoots() -> [String] {
    let cfg = loadRawConfig()
    var roots = [cfg["data_dir"] as? String ?? ""]
    roots += (cfg["legacy_dirs"] as? [String]) ?? []
    roots.append(SPOOL_DIR)
    var isDir = ObjCBool(false)
    return roots.filter { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
}

func writableError(_ path: String) -> String? {
    let fm = FileManager.default
    do { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
    catch { return error.localizedDescription }
    let probe = path + "/.rewinder-write-test"
    do {
        try "ok".write(toFile: probe, atomically: false, encoding: .utf8)
        try? fm.removeItem(atPath: probe)
        return nil
    } catch { return error.localizedDescription }
}

// MARK: - sqlite

final class DB {
    var db: OpaquePointer?

    init?() {
        guard sqlite3_open(DB_PATH, &db) == SQLITE_OK else { return nil }
        exec("PRAGMA busy_timeout=5000")
        exec("CREATE TABLE IF NOT EXISTS shots (path TEXT PRIMARY KEY, day TEXT, t TEXT, ts INTEGER, app TEXT)")
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS ocr USING fts5(text, path UNINDEXED)")
        exec("CREATE INDEX IF NOT EXISTS idx_shots_day ON shots(day)")
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    private func bindAll(_ stmt: OpaquePointer?, _ binds: [Any]) {
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_PTR)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    func rows(_ sql: String, _ binds: [Any] = []) -> [[Any?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            slog("sql error: \(String(cString: sqlite3_errmsg(db))) in \(sql)")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for i in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    if let p = sqlite3_column_text(stmt, i) { row.append(String(cString: p)) }
                    else { row.append(nil) }
                default: row.append(nil)
                }
            }
            out.append(row)
        }
        return out
    }

    @discardableResult
    func run(_ sql: String, _ binds: [Any] = []) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)
        return sqlite3_step(stmt) == SQLITE_DONE
    }
}

// MARK: - scanner / migration

func drain(from srcRoot: String, to dstRoot: String) -> Int {
    let fm = FileManager.default
    var moved = 0
    guard let days = try? fm.contentsOfDirectory(atPath: srcRoot) else { return 0 }
    for day in days.sorted() where isDayName(day) {
        let sdir = srcRoot + "/" + day
        let ddir = dstRoot + "/" + day
        try? fm.createDirectory(atPath: ddir, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: sdir) else { continue }
        for name in names.sorted() where !name.hasPrefix(".") {
            let src = sdir + "/" + name, dst = ddir + "/" + name
            if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: src) }
            else { try? fm.moveItem(atPath: src, toPath: dst) }
            moved += 1
        }
        try? fm.removeItem(atPath: sdir + "/.DS_Store")
        if let left = try? fm.contentsOfDirectory(atPath: sdir), left.isEmpty {
            try? fm.removeItem(atPath: sdir)
        }
    }
    return moved
}

func migrateLegacy() {
    var cfg = loadRawConfig()
    guard let dataDir = cfg["data_dir"] as? String, writableError(dataDir) == nil else { return }
    let n = drain(from: SPOOL_DIR, to: dataDir)
    if n > 0 { slog("drained \(n) spooled files into \(dataDir)") }
    for legacy in (cfg["legacy_dirs"] as? [String]) ?? [] {
        var moved = 0
        if URL(fileURLWithPath: legacy).standardizedFileURL != URL(fileURLWithPath: dataDir).standardizedFileURL {
            moved = drain(from: legacy, to: dataDir)
        }
        if moved > 0 { slog("migrated \(moved) files from \(legacy)") }
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: legacy))?.filter { isDayName($0) } ?? []
        if remaining.isEmpty {
            cfg = loadRawConfig()
            var l = (cfg["legacy_dirs"] as? [String]) ?? []
            l.removeAll { $0 == legacy }
            cfg["legacy_dirs"] = l
            saveRawConfig(cfg)
        }
    }
}

func scanOnce(_ db: DB) -> Int {
    let fm = FileManager.default
    var known = Set<String>()
    for r in db.rows("SELECT path FROM shots") { if let p = r[0] as? String { known.insert(p) } }
    var added = 0
    for root in searchRoots() {
        guard let days = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for day in days.sorted() where isDayName(day) {
            let ddir = root + "/" + day
            guard let names = try? fm.contentsOfDirectory(atPath: ddir) else { continue }
            for name in names.sorted() {
                guard let stem = shotStem(name) else { continue }
                let rel = day + "/" + name
                if known.contains(rel) { continue }
                guard let text = try? String(contentsOfFile: ddir + "/" + stem + ".txt", encoding: .utf8) else {
                    continue  // sidecar not written yet; next scan
                }
                var app: Any = NSNull()
                if let jd = try? Data(contentsOf: URL(fileURLWithPath: ddir + "/" + stem + ".json")),
                   let j = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
                   let a = j["app"] as? String, !a.isEmpty {
                    app = a
                }
                db.run("INSERT OR IGNORE INTO shots VALUES (?,?,?,?,?)",
                       [rel, day, stem, epochOf(day: day, t: stem), app])
                db.run("INSERT INTO ocr (text, path) VALUES (?,?)", [text, rel])
                known.insert(rel)
                added += 1
            }
        }
    }
    return added
}

// MARK: - delete / purge

func deletePaths(_ db: DB, _ paths: [String]) -> Int {
    let fm = FileManager.default
    let roots = searchRoots()
    var n = 0
    for rel in paths {
        let parts = rel.split(separator: "/")
        guard parts.count == 2 else { continue }
        let day = String(parts[0]), name = String(parts[1])
        let stem = String(name.prefix(6))
        for root in roots {
            for f in [name, stem + ".txt", stem + ".json"] {
                let p = root + "/" + day + "/" + f
                if fm.fileExists(atPath: p) {
                    try? fm.removeItem(atPath: p)
                    if f == name { n += 1 }
                }
            }
            let dayDir = root + "/" + day
            if let left = try? fm.contentsOfDirectory(atPath: dayDir), left.isEmpty {
                try? fm.removeItem(atPath: dayDir)
            }
        }
        db.run("DELETE FROM shots WHERE path=?", [rel])
        db.run("DELETE FROM ocr WHERE path=?", [rel])
    }
    return n
}

func purgePaths(_ db: DB, mode: String, day: String, t: String) -> Int? {
    let rows: [[Any?]]
    switch mode {
    case "frame":
        rows = db.rows("SELECT path FROM shots WHERE day=? AND t=?", [day, t])
    case "hour":
        rows = db.rows("SELECT path FROM shots WHERE ts >= ?", [Int64(Date().timeIntervalSince1970) - 3600])
    case "today":
        rows = db.rows("SELECT path FROM shots WHERE day = ?", [todayString()])
    case "today_yesterday":
        rows = db.rows("SELECT path FROM shots WHERE day IN (?,?)", [todayString(), todayString(offsetDays: -1)])
    case "all":
        rows = db.rows("SELECT path FROM shots")
    default:
        return nil
    }
    return deletePaths(db, rows.compactMap { $0[0] as? String })
}

// MARK: - misc helpers

func du(_ path: String) -> Int64 {
    let fm = FileManager.default
    guard let e = fm.enumerator(atPath: path) else { return 0 }
    var total: Int64 = 0
    while let f = e.nextObject() as? String {
        if let attrs = try? fm.attributesOfItem(atPath: path + "/" + f),
           let size = attrs[.size] as? Int64 { total += size }
    }
    return total
}

func freeBytes(_ path: String) -> Int64? {
    (try? FileManager.default.attributesOfFileSystem(forPath: path))?[.systemFreeSize] as? Int64
}

func ftsQuery(_ q: String) -> String? {
    let tokens = q.split(separator: " ").map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
    guard !tokens.isEmpty else { return nil }
    var quoted = tokens.dropLast().map { "\"\($0)\"" }
    quoted.append("\"\(tokens.last!)\"*")
    return quoted.joined(separator: " ")
}

// MARK: - HTTP plumbing

struct HTTPRequest {
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var body = Data()
}

func httpResponse(_ status: Int, _ ctype: String, _ body: Data) -> Data {
    let texts = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"]
    var head = "HTTP/1.1 \(status) \(texts[status] ?? "OK")\r\n"
    head += "Content-Type: \(ctype)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return head.data(using: .utf8)! + body
}

func jsonResponse(_ obj: Any, status: Int = 200) -> Data {
    let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    return httpResponse(status, "application/json", body)
}

func errorResponse(_ msg: String, status: Int = 400) -> Data {
    jsonResponse(["error": msg], status: status)
}

final class RewinderServer {
    static let shared = RewinderServer()

    func start() {
        Thread { self.listenLoop() }.start()
        Thread { self.scanLoop() }.start()
    }

    private func scanLoop() {
        guard let db = DB() else { slog("scanner: cannot open db"); return }
        while true {
            migrateLegacy()
            let n = scanOnce(db)
            if n > 0 { slog("indexed \(n) new shots") }
            Thread.sleep(forTimeInterval: SCAN_INTERVAL)
        }
    }

    private func listenLoop() {
        while true {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { Thread.sleep(forTimeInterval: 3); continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = SERVER_PORT.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 32) == 0 else {
                close(fd)
                Thread.sleep(forTimeInterval: 3)  // e.g. an old server still exiting
                continue
            }
            slog("rewinder server on http://127.0.0.1:\(SERVER_PORT)")
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global(qos: .userInitiated).async { self.handleClient(client) }
            }
        }
    }

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        let headerEnd = Data("\r\n\r\n".utf8)
        var headerRange: Range<Data.Index>?
        while headerRange == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            headerRange = buf.range(of: headerEnd)
            if buf.count > 1_000_000 { return nil }
        }
        guard let hr = headerRange,
              let headText = String(data: buf[..<hr.lowerBound], encoding: .utf8) else { return nil }
        let lines = headText.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var req = HTTPRequest()
        req.method = String(first[0])
        let rawTarget = String(first[1])
        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        var body = Data(buf[hr.upperBound...])
        while body.count < contentLength {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            body.append(contentsOf: chunk[0..<n])
        }
        req.body = body
        if let comps = URLComponents(string: "http://x" + rawTarget) {
            req.path = comps.path
            for item in comps.queryItems ?? [] { req.query[item.name] = item.value ?? "" }
        } else {
            req.path = rawTarget
        }
        return req
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        guard let req = readRequest(fd) else { return }
        let resp = route(req)
        resp.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    // MARK: routes

    private func route(_ req: HTTPRequest) -> Data {
        if req.method == "GET" { return routeGET(req) }
        if req.method == "POST" { return routePOST(req) }
        return errorResponse("method not allowed", status: 404)
    }

    private func routeGET(_ req: HTTPRequest) -> Data {
        guard let db = DB() else { return errorResponse("db unavailable", status: 500) }
        switch req.path {
        case "/":
            let ui = (Bundle.main.resourcePath ?? "") + "/ui/index.html"
            guard let data = FileManager.default.contents(atPath: ui) else { return errorResponse("ui missing", status: 500) }
            return httpResponse(200, "text/html", data)

        case "/api/days":
            let days = db.rows("SELECT DISTINCT day FROM shots ORDER BY day").compactMap { $0[0] as? String }
            return jsonResponse(days)

        case "/api/shots":
            var rows: [[Any?]]
            if let since = req.query["since"], !since.isEmpty {
                let lo = Int64(Double(since) ?? 0)
                let hi = Int64(Double(req.query["until"] ?? "") ?? 9_007_199_254_740_992)
                rows = db.rows("SELECT day, t, ts, path, app FROM shots WHERE ts >= ? AND ts <= ? ORDER BY ts", [lo, hi])
            } else {
                rows = db.rows("SELECT day, t, ts, path, app FROM shots WHERE day=? ORDER BY t", [req.query["day"] ?? ""])
            }
            var out: [[String: Any]] = []
            for r in rows {
                var d: [String: Any] = [:]
                d["day"] = r[0] as? String ?? ""
                d["t"] = r[1] as? String ?? ""
                d["ts"] = r[2] as? Int64 ?? 0
                let path = r[3] as? String ?? ""
                d["f"] = path.split(separator: "/").last.map(String.init) ?? ""
                d["app"] = r[4] as? String ?? NSNull() as Any
                out.append(d)
            }
            return jsonResponse(out)

        case "/api/apps":
            let rows = db.rows("SELECT app, COUNT(*) FROM shots WHERE app IS NOT NULL AND app != '' GROUP BY app ORDER BY COUNT(*) DESC")
            let out: [[String: Any]] = rows.map { ["app": $0[0] as? String ?? "", "n": $0[1] as? Int64 ?? 0] }
            return jsonResponse(out)

        case "/api/search":
            let app = req.query["app"] ?? ""
            var rows: [[Any?]] = []
            if let q = ftsQuery(req.query["q"] ?? "") {
                rows = db.rows("""
                    SELECT o.path, snippet(ocr, 0, '[', ']', '…', 12), s.app
                    FROM ocr o JOIN shots s ON s.path = o.path
                    WHERE ocr MATCH ? AND (? = '' OR s.app = ?)
                    ORDER BY o.path DESC LIMIT 300
                    """, [q, app, app])
            } else if !app.isEmpty {
                rows = db.rows("SELECT path, '', app FROM shots WHERE app = ? ORDER BY path DESC LIMIT 300", [app])
            } else {
                return jsonResponse([])
            }
            let out: [[String: Any]] = rows.compactMap { r in
                guard let path = r[0] as? String else { return nil }
                let parts = path.split(separator: "/")
                guard parts.count == 2 else { return nil }
                return ["day": String(parts[0]), "t": String(parts[1].prefix(6)), "f": String(parts[1]),
                        "snippet": r[1] as? String ?? "", "app": r[2] as? String ?? NSNull() as Any]
            }
            return jsonResponse(out)

        case "/api/config":
            let cfg = loadRawConfig()
            let dd = cfg["data_dir"] as? String ?? ""
            let nshots = db.rows("SELECT COUNT(*) FROM shots").first?.first as? Int64 ?? 0
            let spoolBytes = du(SPOOL_DIR)
            var out: [String: Any] = [:]
            out["data_dir"] = dd
            out["quality"] = cfg["quality"] ?? 25
            out["max_dim"] = cfg["max_dim"] ?? 2560
            out["exclude_apps"] = cfg["exclude_apps"] ?? [String]()
            out["capture_interval"] = cfg["capture_interval"] ?? 60
            out["launch_at_login"] = cfg["launch_at_login"] ?? true
            out["legacy_dirs"] = cfg["legacy_dirs"] ?? [String]()
            out["writable"] = writableError(dd) == nil
            out["usage_bytes"] = du(dd) + spoolBytes
            out["today_bytes"] = du(dd + "/" + todayString())
            let freePath = FileManager.default.fileExists(atPath: dd) ? dd : REWINDER_HOME
            out["free_bytes"] = freeBytes(freePath) ?? NSNull() as Any
            out["shots_total"] = nshots
            out["spooled"] = spoolBytes > 0
            return jsonResponse(out)

        case "/api/volumes":
            var vols: [[String: Any]] = [["path": REWINDER_HOME + "/data", "label": "INTERNAL (default)",
                                          "free_bytes": freeBytes(REWINDER_HOME) ?? NSNull() as Any]]
            let fm = FileManager.default
            for v in (try? fm.contentsOfDirectory(atPath: "/Volumes"))?.sorted() ?? [] {
                let p = "/Volumes/" + v
                var isDir = ObjCBool(false)
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
                      fm.isWritableFile(atPath: p) else { continue }
                vols.append(["path": p + "/rewinder-data", "label": v,
                             "free_bytes": freeBytes(p) ?? NSNull() as Any])
            }
            return jsonResponse(vols)

        default:
            if req.path.hasPrefix("/img/") {
                let rel = String(req.path.dropFirst(5))
                let parts = rel.split(separator: "/")
                guard parts.count == 2, isDayName(String(parts[0])),
                      let _ = shotStem(String(parts[1])) else { return errorResponse("forbidden", status: 403) }
                let ext = String(parts[1].split(separator: ".").last ?? "").lowercased()
                guard let ctype = CTYPES[ext] else { return errorResponse("forbidden", status: 403) }
                for root in searchRoots() {
                    let full = root + "/" + rel
                    if let data = FileManager.default.contents(atPath: full) {
                        return httpResponse(200, ctype, data)
                    }
                }
                return errorResponse("not found", status: 404)
            }
            return errorResponse("not found", status: 404)
        }
    }

    private func routePOST(_ req: HTTPRequest) -> Data {
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return errorResponse("bad json")
        }
        switch req.path {
        case "/api/delete":
            let mode = body["mode"] as? String ?? ""
            let day = body["day"] as? String ?? ""
            let t = body["t"] as? String ?? ""
            if mode == "frame" && !(isDayName(day) && t.count == 6 && t.allSatisfy { $0.isNumber }) {
                return errorResponse("bad frame ref")
            }
            guard let db = DB() else { return errorResponse("db unavailable", status: 500) }
            guard let n = purgePaths(db, mode: mode, day: day, t: t) else { return errorResponse("bad mode") }
            slog("deleted \(n) frames (mode=\(mode))")
            return jsonResponse(["ok": true, "deleted": n])

        case "/api/config":
            var cfg = loadRawConfig()
            var migrating = false
            if let apps = body["exclude_apps"] {
                guard let list = apps as? [String] else { return errorResponse("exclude_apps must be a list of strings") }
                cfg["exclude_apps"] = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            if let v = body["launch_at_login"] { cfg["launch_at_login"] = (v as? Bool) ?? true }
            if let v = body["capture_interval"] {
                guard let n = v as? Int else { return errorResponse("capture_interval must be a number") }
                cfg["capture_interval"] = min(600, max(10, n))
            }
            if let nd = body["data_dir"] as? String {
                let newDir = (nd.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                guard newDir.hasPrefix("/") else { return errorResponse("path must be absolute") }
                if let werr = writableError(newDir) { return errorResponse("not writable: \(werr)") }
                let oldDir = cfg["data_dir"] as? String ?? ""
                if URL(fileURLWithPath: oldDir).standardizedFileURL != URL(fileURLWithPath: newDir).standardizedFileURL {
                    var legacy = Set((cfg["legacy_dirs"] as? [String]) ?? [])
                    var isDir = ObjCBool(false)
                    if FileManager.default.fileExists(atPath: oldDir, isDirectory: &isDir), isDir.boolValue {
                        legacy.insert(oldDir)
                    }
                    legacy.remove(newDir)
                    cfg["legacy_dirs"] = legacy.sorted()
                    migrating = !legacy.isEmpty
                }
                cfg["data_dir"] = newDir
            }
            saveRawConfig(cfg)
            Thread { migrateLegacy() }.start()
            return jsonResponse(["ok": true, "data_dir": cfg["data_dir"] as? String ?? "", "migrating": migrating])

        default:
            return errorResponse("not found", status: 404)
        }
    }
}
