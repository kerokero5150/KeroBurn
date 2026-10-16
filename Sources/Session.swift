import Foundation
import AppKit
import CryptoKit

struct QueuedFile: Identifiable, Equatable {
    enum Status: Equatable { case pending, running, ok, failed, skipped }

    let id = UUID()
    let url: URL
    let size: Int64
    var status: Status = .pending

    var name: String { url.lastPathComponent }
}

enum JobKind: String {
    case write = "WRITE"
    case verify = "VERIFY"
    case read = "READ"
    case blank = "BLANK"
    case erase = "ERASE"
    case chipID = "ID"
    case pinCheck = "PINS"
    case programmer = "PROGRAMMER"
}

enum Outcome: Equatable {
    case success(String)
    case failure(String)
}

// Holds the file queue and drives multi-chip runs (HI/LO pairs, 4-way SIMM sets, and so on).
final class Session: ObservableObject {
    let runner = MiniproRunner()

    @Published var files: [QueuedFile] = []
    @Published var selectedFileID: UUID?
    @Published private(set) var activeIndex: Int?
    @Published private(set) var waitingIndex: Int?   // next file, waiting for a chip swap
    @Published private(set) var batchKind: JobKind?
    @Published var outcome: Outcome?

    private var batchPreset: Preset?

    var isBusy: Bool { runner.isRunning || waitingIndex != nil }

    // MARK: Queue

    func addFiles(_ urls: [URL]) {
        let known = Set(files.map { $0.url.standardizedFileURL })
        for url in urls {
            let u = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue,
                  !known.contains(u) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0
            files.append(QueuedFile(url: u, size: size))
        }
        sortByName()
        resetStatuses()
    }

    func sortByName() {
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        files.removeAll { $0.id == id }
    }

    func move(_ id: UUID, by delta: Int) {
        guard !isBusy, let i = files.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard files.indices.contains(j) else { return }
        files.swapAt(i, j)
    }

    func clearFiles() {
        guard !isBusy else { return }
        files.removeAll()
        outcome = nil
    }

    private func resetStatuses() {
        guard !isBusy else { return }
        for i in files.indices { files[i].status = .pending }
    }

    // MARK: Batch write / verify

    func startBatch(_ kind: JobKind, preset: Preset) {
        guard !isBusy, !files.isEmpty, kind == .write || kind == .verify else { return }
        resetStatuses()
        outcome = nil
        batchKind = kind
        batchPreset = preset
        process(index: 0)
    }

    func continueBatch() {
        guard let next = waitingIndex else { return }
        waitingIndex = nil
        process(index: next)
    }

    func skipNext() {
        guard let next = waitingIndex else { return }
        files[next].status = .skipped
        runner.append(.info, "Skipped \(files[next].name)")
        if next + 1 < files.count {
            waitingIndex = next + 1
        } else {
            waitingIndex = nil
            finishBatch(success: true)
        }
    }

    func stopBatch() {
        if runner.isRunning { runner.cancel() }
        if waitingIndex != nil {
            waitingIndex = nil
            finishBatch(success: false, message: "Stopped")
        }
    }

    private func process(index: Int) {
        guard let preset = batchPreset, let kind = batchKind, files.indices.contains(index) else { return }
        activeIndex = index
        files[index].status = .running
        let file = files[index]

        var args = ["-p", preset.device]
        if kind == .write {
            args += ["-w", file.url.path]
            if preset.noVerify { args.append("-v") }
            if preset.unprotect { args.append("-u") }
            if preset.protectAfter { args.append("-P") }
            if !preset.skipPinCheck { args.append("-z") }
        } else {
            args += ["-m", file.url.path]
        }
        if preset.skipSizeCheck { args.append("-s") }
        if preset.ignoreIDError { args.append("-y") }

        runner.append(.info, "[\(index + 1)/\(files.count)] \(kind.rawValue.capitalized) \(file.name) → \(preset.device)")

        runner.run(args) { [weak self] status, output in
            guard let self = self else { return }
            let ok = status == 0
            if self.files.indices.contains(index) {
                self.files[index].status = ok ? .ok : .failed
            }
            ActivityLog.record(kind: kind, ok: ok, preset: preset, file: file.url, size: file.size,
                               tail: ok ? [] : Array(output.suffix(8)))
            self.activeIndex = nil
            if !ok {
                self.finishBatch(success: false, message: Session.failureText(file.name, status: status, output: output))
            } else if index + 1 < self.files.count {
                self.waitingIndex = index + 1
                self.runner.append(.info, "Insert the chip for \(self.files[index + 1].name), then press Continue.")
                Sounds.attention()
            } else {
                self.finishBatch(success: true)
            }
        }
    }

    private func finishBatch(success: Bool, message: String? = nil) {
        let kind = batchKind ?? .write
        let done = files.filter { $0.status == .ok }.count
        if success {
            let plural: String = files.count == 1 ? "" : "s"
            let label: String = kind.rawValue.capitalized
            let fallback: String = label + " OK — " + String(done) + " of " + String(files.count) + " chip" + plural
            let msg: String = message ?? fallback
            outcome = .success(msg)
            runner.append(.success, msg)
            Sounds.success()
        } else {
            let fallback: String = kind.rawValue.capitalized + " failed"
            let msg: String = message ?? fallback
            outcome = .failure(msg)
            runner.append(.error, msg)
            Sounds.failure()
        }
        batchKind = nil
        batchPreset = nil
        activeIndex = nil
    }

    // Turn the common minipro failures into something a person can act on.
    static func failureText(_ name: String, status: Int32, output: [String]) -> String {
        let joined: String = output.joined(separator: "\n")
        if joined.contains("Bad contact on pin") {
            return name + ": bad pin contact, reseat the chip (see the socket map in the log)"
        }
        if joined.contains("Overcurrent") {
            return name + ": overcurrent, check the chip type and that it's in the right way round"
        }
        if joined.contains("Chip ID mismatch") || joined.contains("Invalid Chip ID") {
            return name + ": chip ID doesn't match the preset"
        }
        if joined.contains("Verification failed") {
            return name + ": verify failed"
        }
        return name + " failed (exit " + String(status) + ")"
    }

    // MARK: Single-shot commands

    func runSingle(_ kind: JobKind, preset: Preset?, extra: [String] = [], file: URL? = nil) {
        guard !isBusy else { return }
        outcome = nil
        var args: [String] = []
        if let p = preset, kind != .programmer {
            args += ["-p", p.device]
            if p.ignoreIDError, kind != .chipID { args.append("-y") }
            if p.unprotect, kind == .erase { args.append("-u") }
        }
        args += extra
        runner.run(args) { [weak self] status, output in
            guard let self = self else { return }
            let ok = status == 0
            let label = kind.rawValue.capitalized
            if let p = preset, kind != .programmer {
                ActivityLog.record(kind: kind, ok: ok, preset: p, file: file, size: nil,
                                   tail: ok ? [] : Array(output.suffix(8)))
            }
            // PLDs (GAL, ATF, ...) have no ID; minipro exits 1 but nothing is wrong with the chip.
            if !ok, kind == .chipID, output.contains(where: { $0.contains("doesn't have a chip ID") }) {
                let msg: String = "This chip has no ID to read. That's normal for GAL, ATF and other PLDs."
                self.outcome = .success(msg)
                self.runner.append(.info, msg)
                return
            }
            if ok {
                self.outcome = .success("\(label) OK")
                self.runner.append(.success, "\(label) OK")
                Sounds.success()
            } else {
                self.outcome = .failure("\(label) failed (exit \(status))")
                self.runner.append(.error, "\(label) failed (exit \(status))")
                Sounds.failure()
            }
        }
    }

    func read(preset: Preset) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        let stamp = Self.fileStamp.string(from: Date())
        let safeDevice = preset.device.replacingOccurrences(of: "@", with: "_")
        panel.nameFieldStringValue = "\(safeDevice)_\(stamp).\(preset.fileExtension)"
        panel.canCreateDirectories = true
        panel.title = "Save chip contents"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runSingle(.read, preset: preset, extra: ["-r", url.path], file: url)
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

// One line per job in ~/Library/Logs/KeroBurn/KeroBurn-YYYY-MM.log, handy as a shipping record.
enum ActivityLog {
    static var directory: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/\(AppInfo.name)", isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func record(kind: JobKind, ok: Bool, preset: Preset, file: URL?, size: Int64?, tail: [String]) {
        let now = Date()
        let okText: String = ok ? "OK" : "FAIL"
        var line: String = "[" + stampFormatter.string(from: now) + "] " + kind.rawValue + " " + okText
        line += "  preset=\"\(preset.name)\" device=\(preset.device)"
        if let file = file {
            line += " file=\"\(file.lastPathComponent)\""
            if let size = size { line += " size=\(size)" }
            if kind == .write || kind == .verify, let hash = sha256Prefix(of: file) {
                line += " sha256=\(hash)"
            }
        }
        for t in tail { line += "\n    | \(t)" }
        line += "\n"

        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(AppInfo.name)-\(monthFormatter.string(from: now)).log")
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func sha256Prefix(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let digest = SHA256.hash(data: data)
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}
