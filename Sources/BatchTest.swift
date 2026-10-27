import SwiftUI
import AppKit

// Batch test: run the same check routine on a pile of chips, one after another.
// Insert a chip, press Return, read the verdict, swap, repeat.
//
// UV EPROM routine (nothing is written):
//   pin contact -> chip ID -> read twice and compare -> blank or has data
// EEPROM / flash routine:
//   pin contact -> chip ID -> erase + blank check -> test patterns -> finish
//   Quick = address pattern only, Full = 55/AA, AA/55 and the address pattern.

enum BatchRoutine: String, CaseIterable, Identifiable {
    case eprom, quick, full
    var id: String { rawValue }

    var title: String {
        switch self {
        case .eprom: return "UV EPROM (read only)"
        case .quick: return "EEPROM / Flash, Quick"
        case .full: return "EEPROM / Flash, Full"
        }
    }

    var detail: String {
        switch self {
        case .eprom:
            return "Pin contact, chip ID, then reads the chip twice and compares. Nothing is written. A chip with data on it is marked Caution: UV erase it before use."
        case .quick:
            return "Pin contact, chip ID, erase and blank check, then one pattern with a different value at every address (catches dead address lines)."
        case .full:
            return "Like Quick, plus 55/AA and AA/55 checkerboards first (every bit has to hold both 0 and 1). Takes about three times as long."
        }
    }

    var erasable: Bool { self != .eprom }

    // Old 27-series parts are UV EPROMs; everything else here is electrically erasable.
    static func guess(for device: String) -> BatchRoutine {
        let d = device.uppercased()
        let uv = ["27C", "2716", "2732", "2764", "27128", "27256", "27512", "M27", "TMS27", "AM27"]
        if uv.contains(where: { d.hasPrefix($0) }) && !d.contains("27SF") { return .eprom }
        return .quick
    }
}

enum BatchFinish: String, CaseIterable, Identifiable {
    case erase, file, leave
    var id: String { rawValue }

    var title: String {
        switch self {
        case .erase: return "Erase it (leave it blank)"
        case .file: return "Write a file"
        case .leave: return "Leave the last pattern on it"
        }
    }
}

struct BatchResult: Identifiable {
    enum Verdict { case pass, caution, fail }

    let id = UUID()
    let number: Int
    let time: Date
    let verdict: Verdict
    let chipID: String
    let crc: String
    let note: String
    let seconds: Int

    var verdictText: String {
        switch verdict {
        case .pass: return "PASS"
        case .caution: return "CAUTION"
        case .fail: return "FAIL"
        }
    }

    var color: Color {
        switch verdict {
        case .pass: return .green
        case .caution: return .orange
        case .fail: return .red
        }
    }
}

struct BatchTestView: View {
    let preset: Preset
    let chipSize: Int?

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var runner: MiniproRunner
    @Environment(\.dismiss) private var dismiss

    @State private var routine: BatchRoutine = .quick
    @State private var finish: BatchFinish = .erase
    @State private var finishFile: URL?
    @State private var results: [BatchResult] = []
    @State private var running = false
    @State private var stepText = ""
    @State private var last: BatchResult?
    @State private var started = Date()

    // Collected while a chip is being tested
    @State private var chipID = "—"
    @State private var crc = ""
    @State private var notes: [String] = []
    @State private var hasData = false

    private var nextNumber: Int { (results.map(\.number).max() ?? 0) + 1 }

    private var cantStart: String? {
        if preset.device.isEmpty { return "This preset has no device set." }
        if preset.isLogicDevice { return "Batch test is for memory chips, not PLDs." }
        if routine.erasable && (chipSize ?? 0) <= 0 { return "The chip size isn't known, so test patterns can't be made." }
        if routine.erasable && finish == .file && finishFile == nil { return "Choose the file to write at the end." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Batch Test").font(.title3).bold()
                Text(verbatim: preset.name + " · " + preset.device)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
            }
            Divider()
            settings
            verdictPanel
            counters
            resultTable
            HStack {
                Button("Save Results…", action: saveCSV)
                    .disabled(results.isEmpty)
                Button("Clear") { results = []; last = nil }
                    .disabled(results.isEmpty || running)
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 820, height: 700)
        .interactiveDismissDisabled(running)
        .onAppear { routine = BatchRoutine.guess(for: preset.device) }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Picker("Routine:", selection: $routine) {
                    ForEach(BatchRoutine.allCases) { r in Text(r.title).tag(r) }
                }
                .frame(width: 330)
                if routine.erasable {
                    Picker("When done:", selection: $finish) {
                        ForEach(BatchFinish.allCases) { f in Text(f.title).tag(f) }
                    }
                    .frame(width: 330)
                }
            }
            .disabled(running)
            Text(routine.detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if routine.erasable && finish == .file {
                HStack {
                    Button("Choose File…", action: chooseFinishFile)
                        .disabled(running)
                    Text(verbatim: finishFile?.lastPathComponent ?? "No file chosen")
                        .foregroundColor(finishFile == nil ? .secondary : .primary)
                }
            }
        }
    }

    // MARK: Big verdict and the Return button

    private var verdictPanel: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if running {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: "Chip #" + String(nextNumber) + ": " + stepText)
                    }
                    .font(.title3)
                    if let p = runner.progress {
                        ProgressView(value: p).frame(maxWidth: 360)
                    }
                } else if let r = last {
                    Text(verbatim: "#" + String(r.number) + "  " + r.verdictText)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(r.color)
                    Text(verbatim: r.note)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Put the first chip in and press Return.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                if let why = cantStart {
                    Text(verbatim: why).font(.callout).foregroundColor(.orange)
                }
            }
            Spacer()
            Button {
                startChip()
            } label: {
                Text(verbatim: "Test Chip #" + String(nextNumber))
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(running || session.isBusy || cantStart != nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 10).fill(panelColor))
    }

    private var panelColor: Color {
        guard !running, let r = last else { return Color(NSColor.controlBackgroundColor) }
        return r.color.opacity(0.15)
    }

    private var counters: some View {
        let pass = results.filter { $0.verdict == .pass }.count
        let caution = results.filter { $0.verdict == .caution }.count
        let fail = results.filter { $0.verdict == .fail }.count
        return HStack(spacing: 18) {
            Text(verbatim: "Tested " + String(results.count))
            Text(verbatim: "Pass " + String(pass)).foregroundColor(.green)
            if routine == .eprom || caution > 0 {
                Text(verbatim: "Caution " + String(caution)).foregroundColor(.orange)
            }
            Text(verbatim: "Fail " + String(fail)).foregroundColor(.red)
        }
        .font(.callout.monospacedDigit())
    }

    private var resultTable: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(results.reversed()) { r in
                    HStack(spacing: 12) {
                        Text(verbatim: "#" + String(r.number))
                            .frame(width: 44, alignment: .leading)
                        Text(verbatim: r.verdictText)
                            .bold()
                            .foregroundColor(r.color)
                            .frame(width: 70, alignment: .leading)
                        Text(verbatim: r.chipID)
                            .frame(width: 80, alignment: .leading)
                        Text(verbatim: r.crc)
                            .frame(width: 80, alignment: .leading)
                        Text(verbatim: r.note)
                            .lineLimit(2)
                        Spacer()
                        Text(verbatim: String(r.seconds) + "s")
                            .foregroundColor(.secondary)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    Divider()
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
    }

    // MARK: Running one chip

    private enum Step {
        case pins, chipID, readTwice, erase, blank
        case pattern(String, [UInt8])
        case writeFile(URL)
    }

    private func steps() -> [Step] {
        var list: [Step] = [.pins, .chipID]
        if routine == .eprom {
            list.append(.readTwice)
            return list
        }
        list += [.erase, .blank]
        let size = chipSize ?? 0
        if routine == .full {
            list.append(.pattern("55/AA checkerboard", BatchPatterns.checker(size, first: 0x55)))
            list.append(.pattern("AA/55 checkerboard", BatchPatterns.checker(size, first: 0xAA)))
        }
        list.append(.pattern("address pattern", BatchPatterns.address(size)))
        switch finish {
        case .erase: list += [.erase, .blank]
        case .file: if let f = finishFile { list.append(.writeFile(f)) }
        case .leave: break
        }
        return list
    }

    private func startChip() {
        guard !running, cantStart == nil else { return }
        running = true
        started = Date()
        chipID = "—"
        crc = ""
        notes = []
        hasData = false
        runner.append(.info, "Batch test: chip #" + String(nextNumber) + ", " + routine.title)
        run(steps(), at: 0)
    }

    private func run(_ list: [Step], at i: Int) {
        guard i < list.count else {
            finishChip(fail: nil)
            return
        }
        perform(list[i]) { failure in
            if let f = failure {
                finishChip(fail: f)
            } else {
                run(list, at: i + 1)
            }
        }
    }

    private var idArgs: [String] { preset.ignoreIDError ? ["-y"] : [] }

    // Calls done(nil) on success, done(reason) on failure.
    private func perform(_ step: Step, done: @escaping (String?) -> Void) {
        let dev = preset.device
        switch step {
        case .pins:
            stepText = "pin contact"
            runner.run(["-p", dev, "-z"] + idArgs) { status, out in
                let all = out.joined(separator: "\n")
                if all.contains("not supported") { notes.append("pin test skipped"); done(nil); return }
                if status == 0 { done(nil); return }
                let pins = out.compactMap { line -> String? in
                    guard let r = line.range(of: "Bad contact on pin:") else { return nil }
                    return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                }
                done(pins.isEmpty ? "Pin test failed" : "Bad contact on pin " + pins.joined(separator: ", "))
            }

        case .chipID:
            stepText = "chip ID"
            runner.run(["-p", dev, "-D"]) { status, out in
                let all = out.joined(separator: "\n")
                if let line = out.first(where: { $0.contains("Chip ID") && $0.contains("OK") }),
                   let r = line.range(of: "0x") {
                    chipID = String(line[r.lowerBound...].prefix { !$0.isWhitespace })
                }
                if status == 0 { done(nil); return }
                if all.contains("doesn't have a chip ID") { notes.append("no chip ID in minipro"); done(nil); return }
                if let m = Session.parseMismatch(out) {
                    chipID = m.got
                    let what = m.name.map { "reads as " + $0 } ?? "unknown ID"
                    if preset.ignoreIDError {
                        notes.append("ID " + m.got + " (" + what + ")")
                        done(nil)
                    } else {
                        done("Wrong chip ID " + m.got + ", " + what)
                    }
                    return
                }
                done("Chip ID failed (exit " + String(status) + ")")
            }

        case .readTwice:
            stepText = "reading (1 of 2)"
            let a = BatchPatterns.tempFile("read-a")
            let b = BatchPatterns.tempFile("read-b")
            runner.run(["-p", dev, "-r", a.path] + idArgs) { s1, _ in
                guard s1 == 0, let first = try? Data(contentsOf: a) else {
                    cleanup(a, b); done("Read failed"); return
                }
                stepText = "reading (2 of 2)"
                runner.run(["-p", dev, "-r", b.path] + idArgs) { s2, _ in
                    defer { cleanup(a, b) }
                    guard s2 == 0, let second = try? Data(contentsOf: b) else { done("Second read failed"); return }
                    let x = [UInt8](first), y = [UInt8](second)
                    if x != y {
                        let diffs = zip(x, y).enumerated().filter { $0.element.0 != $0.element.1 }
                        let at = diffs.first.map { String(format: "0x%06X", $0.offset) } ?? "?"
                        done("Unstable: " + String(diffs.count) + " bytes differ between two reads, first at " + at)
                        return
                    }
                    crc = String(format: "%08X", HexModel.crc32(x))
                    hasData = x.contains { $0 != 0xFF }
                    done(nil)
                }
            }

        case .erase:
            stepText = "erasing"
            runner.run(["-p", dev, "-E"] + (preset.unprotect ? ["-u"] : []) + idArgs) { status, _ in
                done(status == 0 ? nil : "Erase failed")
            }

        case .blank:
            stepText = "blank check"
            runner.run(["-p", dev, "-b"] + idArgs) { status, out in
                if status == 0 { done(nil); return }
                done("Not blank after erase" + Self.address(in: out))
            }

        case .pattern(let name, let bytes):
            stepText = "writing " + name
            let f = BatchPatterns.tempFile("pattern")
            do { try Data(bytes).write(to: f) } catch { done("Couldn't make the test pattern"); return }
            runner.run(["-p", dev, "-w", f.path] + writeArgs + idArgs) { status, out in
                cleanup(f)
                done(status == 0 ? nil : name + " failed" + Self.address(in: out))
            }

        case .writeFile(let url):
            stepText = "writing " + url.lastPathComponent
            runner.run(["-p", dev, "-w", url.path] + writeArgs + (preset.skipSizeCheck ? ["-s"] : []) + idArgs) { status, out in
                done(status == 0 ? nil : "Writing " + url.lastPathComponent + " failed" + Self.address(in: out))
            }
        }
    }

    private var writeArgs: [String] {
        var a: [String] = []
        if preset.unprotect { a.append("-u") }
        if preset.protectAfter { a.append("-P") }
        return a + preset.voltageArgs
    }

    // " at 0x001234" from minipro's "...failed at address 0x1234: ..."
    private static func address(in out: [String]) -> String {
        guard let line = out.last(where: { $0.contains("at address 0x") }),
              let r = line.range(of: "at address ") else { return "" }
        let addr = line[r.upperBound...].prefix { $0 != ":" && !$0.isWhitespace }
        return " at " + addr
    }

    private func cleanup(_ urls: URL...) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    private func finishChip(fail: String?) {
        let secs = Int(Date().timeIntervalSince(started).rounded())
        let verdict: BatchResult.Verdict
        var note: String
        if let f = fail {
            verdict = .fail
            note = f
        } else if routine == .eprom && hasData {
            verdict = .caution
            note = "Has data on it (CRC " + crc + "). UV erase it before use."
        } else {
            verdict = .pass
            note = routine == .eprom ? "Blank, reads the same twice" : "All tests passed"
            if routine.erasable {
                switch finish {
                case .erase: note += ", left blank"
                case .file: note += ", " + (finishFile?.lastPathComponent ?? "file") + " written"
                case .leave: note += ", test pattern left on it"
                }
            }
        }
        if !notes.isEmpty { note += " (" + notes.joined(separator: "; ") + ")" }

        let r = BatchResult(number: nextNumber, time: Date(), verdict: verdict,
                            chipID: chipID, crc: crc, note: note, seconds: secs)
        results.append(r)
        last = r
        running = false
        stepText = ""

        switch verdict {
        case .pass: Sounds.success()
        case .caution: Sounds.attention()
        case .fail: Sounds.failure()
        }
        let kind: LogLine.Kind = verdict == .fail ? .error : .success
        runner.append(kind, "Chip #" + String(r.number) + " " + r.verdictText + ": " + note)
    }

    // MARK: Files

    private func chooseFinishFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "File to write after the test"
        if panel.runModal() == .OK { finishFile = panel.url }
    }

    private func saveCSV() {
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let safe = preset.device.replacingOccurrences(of: "@", with: "_")
        panel.nameFieldStringValue = "batch-" + safe + "-" + f.string(from: Date()) + ".csv"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let t = DateFormatter()
        t.locale = Locale(identifier: "en_US_POSIX")
        t.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["number,time,device,routine,result,chip_id,crc32,seconds,note"]
        for r in results {
            let fields: [String] = [String(r.number), t.string(from: r.time), preset.device, routine.title,
                                    r.verdictText, r.chipID, r.crc, String(r.seconds), r.note]
            lines.append(fields.map(Self.csv).joined(separator: ","))
        }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            runner.append(.success, "Saved " + url.lastPathComponent)
        } catch {
            runner.append(.error, "Couldn't save: " + error.localizedDescription)
        }
    }

    private static func csv(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// Test data for erasable chips.
enum BatchPatterns {
    // 55 AA 55 AA ... (or AA 55 ...): neighbouring bits and bytes always differ.
    static func checker(_ size: Int, first: UInt8) -> [UInt8] {
        let second: UInt8 = first ^ 0xFF
        var out = [UInt8](repeating: first, count: size)
        var i = 1
        while i < size {
            out[i] = second
            i += 2
        }
        return out
    }

    // Every address line flips a different data bit: A0-A7 flip bits 0-7,
    // A8 up are folded in rotated, so a dead or stuck address line makes
    // two locations read the same and verify fails.
    static func address(_ size: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            let b0 = UInt8(i & 0xFF)
            let b1 = rotl(UInt8((i >> 8) & 0xFF), 1)
            let b2 = rotl(UInt8((i >> 16) & 0xFF), 2)
            let b3 = rotl(UInt8((i >> 24) & 0xFF), 3)
            out[i] = b0 ^ b1 ^ b2 ^ b3
        }
        return out
    }

    private static func rotl(_ v: UInt8, _ n: Int) -> UInt8 {
        (v << UInt8(n)) | (v >> UInt8(8 - n))
    }

    static func tempFile(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keroburn-batch-" + tag + "-" + UUID().uuidString + ".bin")
    }
}
