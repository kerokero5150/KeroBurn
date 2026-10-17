import SwiftUI
import AppKit

// Holds two byte buffers (a file and what came back from the chip) and the comparison between them.
final class HexModel: ObservableObject {
    @Published private(set) var fileBytes: [UInt8]?
    @Published private(set) var fileName = ""
    @Published private(set) var chipBytes: [UInt8]?
    @Published private(set) var chipName = ""
    @Published private(set) var diffs: [Int] = []       // offsets that differ, capped
    @Published private(set) var diffCount = 0
    @Published private(set) var notes: [String] = []

    static let diffCap = 200_000

    var rowCount: Int {
        let n = max(fileBytes?.count ?? 0, chipBytes?.count ?? 0)
        return (n + 15) / 16
    }

    var comparing: Bool { fileBytes != nil && chipBytes != nil }

    private var rawFile: [UInt8]?
    private var rawName = ""
    private var placement: Placement?

    func loadFile(_ url: URL, placement: Placement? = nil) {
        guard let data = try? Data(contentsOf: url) else { return }
        rawFile = [UInt8](data)
        rawName = url.lastPathComponent
        self.placement = (placement?.isDefault ?? true) ? nil : placement
        rebuildFile()
        compare()
    }

    func loadChip(_ url: URL, label: String) {
        guard let data = try? Data(contentsOf: url) else { return }
        chipBytes = [UInt8](data)
        chipName = label
        rebuildFile()
        compare()
    }

    // With an offset set, show the file the way it will end up on the chip:
    // placed at its address, on top of the chip (keep) or on top of blank FF.
    private func rebuildFile() {
        guard let raw = rawFile else { return }
        guard let p = placement else {
            fileBytes = raw
            fileName = rawName
            return
        }
        let start = min(Int(p.fileOffset), raw.count)
        let len = p.length > 0 ? min(Int(p.length), raw.count - start) : raw.count - start
        let offset = Int(p.offset)
        guard offset + len <= 0x400_0000 else {   // nonsense offset, just show the file
            fileBytes = raw
            fileName = rawName
            return
        }
        var base: [UInt8]
        if let chip = chipBytes {
            base = p.keep ? chip : [UInt8](repeating: 0xFF, count: chip.count)
        } else {
            base = []
        }
        if base.count < offset + len {
            base += [UInt8](repeating: 0xFF, count: offset + len - base.count)
        }
        if len > 0 {
            base.replaceSubrange(offset..<(offset + len), with: raw[start..<(start + len)])
        }
        fileBytes = base
        fileName = rawName + " (" + p.summary + ")"
    }

    func clearChip() {
        chipBytes = nil
        chipName = ""
        compare()
    }

    // MARK: Comparison

    private func compare() {
        diffs = []
        diffCount = 0
        notes = []
        guard let a = fileBytes, let b = chipBytes else { return }

        let common = min(a.count, b.count)
        var list: [Int] = []
        var count = 0
        for i in 0..<common where a[i] != b[i] {
            count += 1
            if list.count < Self.diffCap { list.append(i) }
        }
        diffs = list
        diffCount = count

        var out: [String] = []
        if a.count != b.count {
            let parts: [String] = ["Sizes differ: file ", Self.sizeText(a.count), ", chip ", Self.sizeText(b.count),
                                   ". Only the first ", Self.sizeText(common), " are compared."]
            out.append(parts.joined())
        }
        if count == 0 && a.count == b.count {
            out.append("Chip matches the file byte for byte.")
        }
        if b.allSatisfy({ $0 == 0xFF }) {
            out.append("The chip reads as all FF, so it looks blank or wasn't written.")
        } else if count > 0, let first = list.first, let shift = Self.findShift(a: a, b: b, near: first) {
            let sign: String = shift > 0 ? "+" : "-"
            let parts: [String] = ["Data looks shifted: the file's bytes at ", Self.hex(first),
                                   " show up in the chip at ", Self.hex(first + shift),
                                   " (", sign, Self.hex(abs(shift)), ")."]
            out.append(parts.joined())
        }
        if count > 0, let first = list.first {
            let lastShown = list.last ?? first
            var parts: [String] = [String(count), " byte(s) differ. First at ", Self.hex(first),
                                   ", last at ", Self.hex(lastShown), "."]
            if count > list.count { parts += [" (Only the first ", String(list.count), " are listed.)"] }
            let msg: String = parts.joined()
            out.append(msg)
            if Self.looksLikeEveryOtherByte(list) {
                let side: String = list[0] % 2 == 0 ? "even" : "odd"
                out.append("Every difference is on " + side + " addresses. Check for a HI/LO mix-up or a 16-bit split problem.")
            }
        }
        notes = out
    }

    // Take a non-uniform 32-byte block from the file at the first difference and look for it in the chip nearby.
    static func findShift(a: [UInt8], b: [UInt8], near start: Int) -> Int? {
        let blockLen = 32
        var s = start
        while s + blockLen <= a.count {
            let block = a[s..<(s + blockLen)]
            if Set(block).count > 2 { break }
            s += 16
        }
        guard s + blockLen <= a.count else { return nil }
        let block = Array(a[s..<(s + blockLen)])
        let window = 0x10000
        let lo = max(0, s - window)
        let hi = min(b.count - blockLen, s + window)
        guard lo <= hi else { return nil }
        var best: Int?
        var p = lo
        while p <= hi {
            if b[p] == block[0] && p != s {
                var ok = true
                var k = 1
                while k < blockLen {
                    if b[p + k] != block[k] { ok = false; break }
                    k += 1
                }
                if ok {
                    let d = p - s
                    if best == nil || abs(d) < abs(best!) { best = d }
                }
            }
            p += 1
        }
        return best
    }

    static func looksLikeEveryOtherByte(_ list: [Int]) -> Bool {
        guard list.count >= 8, let first = list.first else { return false }
        let parity = first % 2
        return list.allSatisfy { $0 % 2 == parity }
    }

    // MARK: Checksums

    static func sum32(_ bytes: [UInt8]) -> UInt32 {
        var s: UInt32 = 0
        for v in bytes { s = s &+ UInt32(v) }
        return s
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for v in bytes { c = crcTable[Int((c ^ UInt32(v)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func hex(_ v: Int) -> String { "0x" + String(format: "%06X", v) }

    static func sizeText(_ n: Int) -> String {
        if n >= 1024 && n % 1024 == 0 { return String(n / 1024) + " KB" }
        return String(n) + " bytes"
    }
}

// MARK: - Window

struct HexViewer: View {
    let preset: Preset
    let initialFile: URL?
    var initialPlacement: Placement? = nil
    var readOnOpen = false

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var runner: MiniproRunner
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = HexModel()

    @State private var gotoText = ""
    @State private var target: Int?
    @State private var diffCursor = 0
    @State private var onlyDiffRows = false
    @State private var readError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            summary
            Divider()
            HexTable(model: model, target: $target, onlyDiffRows: onlyDiffRows)
        }
        .padding(14)
        .frame(minWidth: 1020, minHeight: 680)
        .onAppear {
            if let url = initialFile { model.loadFile(url, placement: initialPlacement) }
            if readOnOpen, !session.isBusy, !preset.device.isEmpty { readChip() }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Open File…", action: openFile)
            Button("Read Chip") { readChip() }
                .disabled(session.isBusy || preset.device.isEmpty)
                .help(Text(verbatim: "Read the chip in the socket with preset " + preset.name))
            Button("Save Chip…", action: saveChip)
                .disabled(model.chipBytes == nil)
                .help("Save what was read from the chip to a file")
            if runner.isRunning {
                ProgressView().controlSize(.small)
            }
            Divider().frame(height: 20)
            TextField("Address (hex)", text: $gotoText, onCommit: jump)
                .frame(width: 120)
                .font(.system(.body, design: .monospaced))
            Button("Go", action: jump)
            Divider().frame(height: 20)
            Button("◀ Diff") { stepDiff(-1) }
                .disabled(model.diffs.isEmpty)
            Button("Diff ▶") { stepDiff(1) }
                .disabled(model.diffs.isEmpty)
            Toggle("Only rows with differences", isOn: $onlyDiffRows)
                .toggleStyle(.checkbox)
                .disabled(!model.comparing || model.diffs.isEmpty)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 24) {
                bufferInfo(title: "File", name: model.fileName, bytes: model.fileBytes)
                bufferInfo(title: "Chip", name: model.chipName, bytes: model.chipBytes)
            }
            if let err = readError {
                Text(verbatim: err).foregroundColor(.red).font(.callout)
            }
            ForEach(model.notes, id: \.self) { note in
                Text(verbatim: note)
                    .font(.callout)
                    .foregroundColor(noteColor(note))
            }
        }
    }

    private func noteColor(_ note: String) -> Color {
        if note.hasPrefix("Chip matches") { return .green }
        return .orange
    }

    private func bufferInfo(title: String, name: String, bytes: [UInt8]?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.headline)
            if let b = bytes {
                Text(verbatim: name).lineLimit(1).truncationMode(.middle)
                Text(verbatim: Self.statsLine(b))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(verbatim: "Not loaded").foregroundColor(.secondary)
            }
        }
        .frame(width: 460, alignment: .leading)
    }

    private static func statsLine(_ b: [UInt8]) -> String {
        let parts: [String] = [HexModel.sizeText(b.count),
                               "   Sum ", String(format: "%08X", HexModel.sum32(b)),
                               "   CRC32 ", String(format: "%08X", HexModel.crc32(b))]
        return parts.joined()
    }

    // MARK: Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.loadFile(url) }
    }

    private func readChip() {
        readError = nil
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keroburn-read-" + UUID().uuidString + ".bin")
        var args = ["-p", preset.device, "-r", tmp.path]
        if preset.ignoreIDError { args.append("-y") }
        runner.run(args) { status, output in
            if status == 0 {
                let label: String = [preset.device, " (read ", Self.timeText(), ")"].joined()
                model.loadChip(tmp, label: label)
            } else {
                let tail: String = output.last ?? ""
                readError = ["Read failed (exit ", String(status), "). ", tail].joined()
            }
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func saveChip() {
        guard let bytes = model.chipBytes else { return }
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safeDevice = preset.device.replacingOccurrences(of: "@", with: "_")
        panel.nameFieldStringValue = safeDevice + "_" + f.string(from: Date()) + ".bin"
        panel.canCreateDirectories = true
        panel.title = "Save chip contents"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(bytes).write(to: url, options: .atomic)
            runner.append(.success, "Saved " + url.lastPathComponent)
        } catch {
            readError = "Couldn't save: " + error.localizedDescription
        }
    }

    private func jump() {
        let cleaned = gotoText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard let addr = Int(cleaned, radix: 16) else { return }
        onlyDiffRows = false
        target = addr / 16
    }

    private func stepDiff(_ delta: Int) {
        guard !model.diffs.isEmpty else { return }
        // Move to the next difference that sits on a different row.
        let currentRow = model.diffs[min(diffCursor, model.diffs.count - 1)] / 16
        var i = diffCursor
        repeat {
            i = (i + delta + model.diffs.count) % model.diffs.count
        } while model.diffs[i] / 16 == currentRow && i != diffCursor
        diffCursor = i
        gotoText = String(format: "%06X", model.diffs[i])
        target = model.diffs[i] / 16
    }

    private static func timeText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - Table

struct HexTable: View {
    @ObservedObject var model: HexModel
    @Binding var target: Int?
    let onlyDiffRows: Bool

    private var rows: [Int] {
        if onlyDiffRows {
            var seen = Set<Int>()
            var out: [Int] = []
            for d in model.diffs where seen.insert(d / 16).inserted { out.append(d / 16) }
            return out
        }
        return Array(0..<model.rowCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.self) { r in
                            HexRowView(row: r, file: model.fileBytes, chip: model.chipBytes,
                                       highlighted: target == r)
                                .id(r)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: target) { newValue in
                    if let r = newValue { proxy.scrollTo(r, anchor: .center) }
                }
            }
        }
    }

    private var firstColumnTitle: String {
        if model.fileBytes == nil && model.chipBytes != nil { return "Chip" }
        return "File"
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(verbatim: "Address ").frame(width: 70, alignment: .leading)
            // With only a chip read (no file), the first column shows the chip.
            Text(verbatim: firstColumnTitle).frame(width: 400, alignment: .leading)
            if model.comparing {
                Text(verbatim: "Chip").frame(width: 400, alignment: .leading)
            }
            Text(verbatim: "ASCII")
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }
}

struct HexRowView: View {
    let row: Int
    let file: [UInt8]?
    let chip: [UInt8]?
    let highlighted: Bool

    var body: some View {
        let start = row * 16
        HStack(spacing: 0) {
            Text(verbatim: String(format: "%06X", start))
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            if file != nil {
                Self.hexText(file, other: chip, start: start)
                    .frame(width: 400, alignment: .leading)
            } else {
                Self.hexText(chip, other: nil, start: start)
                    .frame(width: 400, alignment: .leading)
            }
            if file != nil && chip != nil {
                Self.hexText(chip, other: file, start: start)
                    .frame(width: 400, alignment: .leading)
            }
            // Past the end of a short file, show the chip's text instead of nothing.
            Text(verbatim: Self.ascii((file?.count ?? 0) > start ? file : chip, start: start))
                .foregroundColor(.secondary)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    // Bytes that differ from the other buffer are drawn in bold red.
    static func hexText(_ bytes: [UInt8]?, other: [UInt8]?, start: Int) -> Text {
        var t = Text(verbatim: "")
        guard let b = bytes else { return t }
        for i in 0..<16 {
            let idx = start + i
            if i == 8 { t = t + Text(verbatim: " ") }
            if idx < b.count {
                let v = b[idx]
                var piece = Text(verbatim: String(format: "%02X ", v))
                if let o = other, idx >= o.count || o[idx] != v {
                    piece = piece.foregroundColor(.red).bold()
                }
                t = t + piece
            } else {
                t = t + Text(verbatim: "   ")
            }
        }
        return t
    }

    static func ascii(_ bytes: [UInt8]?, start: Int) -> String {
        guard let b = bytes, start < b.count else { return "" }
        var s = ""
        for idx in start..<min(start + 16, b.count) {
            let v = b[idx]
            s.append(v >= 0x20 && v < 0x7F ? Character(UnicodeScalar(v)) : ".")
        }
        return s
    }
}
