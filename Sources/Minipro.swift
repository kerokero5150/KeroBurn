import Foundation
import AppKit

// Finds the minipro binary and the database files it needs.
enum MiniproLocator {
    static let customPathKey = "miniproPath"

    static var bundledBinary: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/minipro")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var bundledDatabaseDir: URL? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("minipro", isDirectory: true) else { return nil }
        let info = res.appendingPathComponent("infoic.xml")
        return FileManager.default.fileExists(atPath: info.path) ? res : nil
    }

    // Order: user override in Settings, then the copy inside the app, then MacPorts / Homebrew.
    static func resolve() -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: customPathKey),
           !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if let bundled = bundledBinary { return bundled }
        for path in ["/opt/local/bin/minipro", "/opt/homebrew/bin/minipro", "/usr/local/bin/minipro"]
            where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // The bundled minipro would otherwise look for its XML files at the build machine's prefix,
    // so point it at the copies inside the app. Other binaries keep their own defaults.
    static func databaseArgs(for exe: URL) -> [String] {
        guard let bundled = bundledBinary, exe.standardizedFileURL == bundled.standardizedFileURL,
              let dir = bundledDatabaseDir else { return [] }
        var args = ["--infoic", dir.appendingPathComponent("infoic.xml").path]
        let logic = dir.appendingPathComponent("logicic.xml")
        if FileManager.default.fileExists(atPath: logic.path) {
            args += ["--logicic", logic.path]
        }
        return args
    }

    // infoic.xml for the minipro that is actually in use.
    static func infoicURL(for exe: URL) -> URL? {
        let fm = FileManager.default
        if !databaseArgs(for: exe).isEmpty, let dir = bundledDatabaseDir {
            return dir.appendingPathComponent("infoic.xml")
        }
        let prefix = exe.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            prefix.appendingPathComponent("share/minipro/infoic.xml").path,
            "/opt/local/share/minipro/infoic.xml",
            "/opt/homebrew/share/minipro/infoic.xml",
            "/usr/local/share/minipro/infoic.xml",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let dir = bundledDatabaseDir { return dir.appendingPathComponent("infoic.xml") }
        return nil
    }

    // Blocking run, used for quick queries off the main thread.
    static func runSync(exe: URL, args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct LogLine: Identifiable {
    enum Kind { case command, output, info, success, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

// Runs one minipro command at a time and streams its output.
final class MiniproRunner: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var liveLine = ""
    @Published private(set) var progress: Double?
    @Published private(set) var isRunning = false

    private var process: Process?
    private var pending = ""
    private let maxLines = 3000

    func append(_ kind: LogLine.Kind, _ text: String) {
        lines.append(LogLine(kind: kind, text: text))
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    func clear() { lines.removeAll() }

    var plainText: String { lines.map(\.text).joined(separator: "\n") }

    func run(_ args: [String], completion: @escaping (Int32, [String]) -> Void) {
        guard !isRunning else { return }
        guard let exe = MiniproLocator.resolve() else {
            append(.error, "minipro not found. Set its path in Settings, or rebuild the app with minipro installed.")
            completion(-1, [])
            return
        }

        let fullArgs = MiniproLocator.databaseArgs(for: exe) + args
        let p = Process()
        p.executableURL = exe
        p.arguments = fullArgs
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let startIndex = lines.count
        append(.command, "$ minipro " + args.map(Self.shellQuote).joined(separator: " "))
        pending = ""

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.ingest(text) }
        }

        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !rest.isEmpty { self.ingest(String(decoding: rest, as: UTF8.self)) }
                self.flushPending()
                self.isRunning = false
                self.process = nil
                self.progress = nil
                self.liveLine = ""
                let produced = self.lines.suffix(from: min(startIndex, self.lines.count))
                    .filter { $0.kind == .output }.map(\.text)
                completion(proc.terminationStatus, produced)
            }
        }

        do {
            try p.run()
            process = p
            isRunning = true
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            append(.error, "Could not start minipro: \(error.localizedDescription)")
            completion(-1, [])
        }
    }

    func cancel() {
        guard let p = process, p.isRunning else { return }
        append(.info, "Stopping…")
        p.terminate()
    }

    // minipro redraws progress with \r, so only the last segment of each line is kept.
    private func ingest(_ chunk: String) {
        pending += Self.stripANSI(chunk)
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending = String(pending[pending.index(after: nl)...])
            let last = Self.lastSegment(line)
            if !last.trimmingCharacters(in: .whitespaces).isEmpty {
                append(.output, last)
            }
        }
        let live = Self.lastSegment(pending)
        liveLine = live
        if let pct = Self.percent(in: live) { progress = pct }
    }

    private func flushPending() {
        let last = Self.lastSegment(pending)
        if !last.trimmingCharacters(in: .whitespaces).isEmpty { append(.output, last) }
        pending = ""
    }

    private static func lastSegment(_ s: String) -> String {
        s.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func percent(in s: String) -> Double? {
        guard let r = s.range(of: "[0-9]{1,3}%", options: [.regularExpression, .backwards]) else { return nil }
        let digits = s[r].dropLast()
        guard let v = Double(digits) else { return nil }
        return min(max(v / 100.0, 0), 1)
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// The full list of device names minipro knows about, loaded once in the background.
final class DeviceCatalog: ObservableObject {
    enum State { case idle, loading, loaded, failed(String) }

    @Published private(set) var names: [String] = []
    @Published private(set) var state: State = .idle
    private var nameSet: Set<String> = []

    var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    func load() {
        if case .loading = state { return }
        guard let exe = MiniproLocator.resolve() else {
            state = .failed("minipro not found")
            return
        }
        guard let xml = MiniproLocator.infoicURL(for: exe) else {
            state = .failed("infoic.xml not found")
            return
        }
        state = .loading
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.parseNames(xml)
            DispatchQueue.main.async {
                if list.count < 100 {
                    self.state = .failed("Could not read device names from \(xml.path)")
                } else {
                    self.names = list
                    self.nameSet = Set(list)
                    self.state = .loaded
                }
            }
        }
    }

    // Each <ic name="A,B@PKG,C"> entry holds one or more comma-separated device names.
    static func parseNames(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        // The file holds one section per programmer family. T48 and TL866II+ use INFOIC2PLUS,
        // where some names differ from the TL866A section (e.g. A29040L@PLCC32), so prefer it.
        if let start = text.range(of: "type=\"INFOIC2PLUS\"") {
            let rest = text[start.upperBound...]
            let end = rest.range(of: "</database")?.lowerBound ?? rest.endIndex
            text = String(rest[..<end])
        }
        guard let re = try? NSRegularExpression(pattern: "<ic\\s+name=\"([^\"]+)\"") else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        let ns = text as NSString
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges > 1 else { return }
            let field = ns.substring(with: m.range(at: 1))
            for part in field.split(separator: ",") {
                let name = part.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, seen.insert(name).inserted { out.append(name) }
            }
        }
        out.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return out
    }

    // nil means "can't tell yet".
    func knows(_ device: String) -> Bool? {
        guard isLoaded else { return nil }
        return nameSet.contains(device)
    }

    func search(_ query: String, limit: Int = 300) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [String] = []
        for n in names where n.range(of: q, options: .caseInsensitive) != nil {
            out.append(n)
            if out.count >= limit { break }
        }
        return out
    }
}

enum Sounds {
    static func success() { NSSound(named: "Glass")?.play() }
    static func failure() { NSSound(named: "Basso")?.play() }
    static func attention() { NSSound(named: "Tink")?.play() }
}
