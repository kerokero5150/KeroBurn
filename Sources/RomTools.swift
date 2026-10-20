import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Split one ROM image into byte lanes for 16-bit / 32-bit boards, and join
// lanes back into one image. Each part can be repeated to fill a bigger chip
// (x2, x4, x8 ...), so the unused high address lines don't matter.

// MARK: - Layout

struct RomLane: Hashable {
    let name: String    // HI, LO, LL ...
    let index: Int      // byte lane: offset % ways
    let bus: String     // which data lines it drives
}

enum RomLayout: Int, CaseIterable, Identifiable {
    case single = 1
    case pair = 2
    case quad = 4

    var id: Int { rawValue }
    var ways: Int { rawValue }

    var title: String {
        switch self {
        case .single: return "1 chip"
        case .pair: return "2 chips (16-bit)"
        case .quad: return "4 chips (32-bit)"
        }
    }

    // Display order, with the byte lane each chip takes (big-endian, as on 68K Macs).
    var lanes: [RomLane] {
        switch self {
        case .single:
            return [RomLane(name: "ROM", index: 0, bus: "D0-D7")]
        case .pair:
            return [RomLane(name: "HI", index: 0, bus: "D8-D15, even bytes"),
                    RomLane(name: "LO", index: 1, bus: "D0-D7, odd bytes")]
        case .quad:
            return [RomLane(name: "LL", index: 3, bus: "D0-D7, byte 3 of 4"),
                    RomLane(name: "ML", index: 2, bus: "D8-D15, byte 2 of 4"),
                    RomLane(name: "MH", index: 1, bus: "D16-D23, byte 1 of 4"),
                    RomLane(name: "HH", index: 0, bus: "D24-D31, byte 0 of 4")]
        }
    }

    // File name suffix. Numbered for 4 chips so the file list sorts LL, ML, MH, HH.
    func suffix(for lane: RomLane) -> String {
        switch self {
        case .single: return "fill"
        case .pair: return lane.name
        case .quad:
            let pos = (lanes.firstIndex(of: lane) ?? 0) + 1
            return String(pos) + "-" + lane.name
        }
    }
}

// MARK: - Byte math

enum RomMath {
    // Every `ways`-th byte starting at `index`.
    static func lane(_ data: [UInt8], ways: Int, index: Int) -> [UInt8] {
        if ways <= 1 { return data }
        var out: [UInt8] = []
        out.reserveCapacity(data.count / ways + 1)
        var i = index
        while i < data.count {
            out.append(data[i])
            i += ways
        }
        return out
    }

    // `parts` in lane order (index 0 first). All parts must be the same size.
    static func interleave(_ parts: [[UInt8]]) -> [UInt8] {
        let ways = parts.count
        let n = parts.first?.count ?? 0
        var out = [UInt8](repeating: 0xFF, count: n * ways)
        for k in 0..<ways {
            let part = parts[k]
            for i in 0..<min(n, part.count) {
                out[i * ways + k] = part[i]
            }
        }
        return out
    }

    // Repeat `part` until it is `size` bytes. Whatever doesn't fit a whole copy is FF.
    static func fill(_ part: [UInt8], to size: Int) -> [UInt8] {
        guard !part.isEmpty, size > part.count else { return part }
        var out: [UInt8] = []
        out.reserveCapacity(size)
        while out.count + part.count <= size { out.append(contentsOf: part) }
        if out.count < size {
            out.append(contentsOf: [UInt8](repeating: 0xFF, count: size - out.count))
        }
        return out
    }

    // Shortest length (halving each time) that the data is a repeat of.
    static func repeatUnit(_ b: [UInt8]) -> Int {
        var n = b.count
        while n >= 2 && n % 2 == 0 {
            let h = n / 2
            if b[0..<h].elementsEqual(b[h..<n]) { n = h } else { break }
        }
        return n
    }

    // 68K Mac ROM checksum: the first long word holds the sum of all 16-bit words after it.
    // Bigger images (ROM disks) only cover the original ROM, so try each power-of-two prefix.
    static func macChecksumSize(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        let stored = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        if stored == 0 || stored == 0xFFFF_FFFF { return nil }
        var sum: UInt32 = 0
        var i = 4
        var check = 0x10000
        while check <= b.count {
            while i + 1 < check {
                let word = UInt32(b[i]) << 8 | UInt32(b[i + 1])
                sum = sum &+ word
                i += 2
            }
            if sum == stored { return check }
            check *= 2
        }
        return nil
    }

    static func sizeText(_ n: Int) -> String {
        let mb = 1024 * 1024
        if n >= mb && n % mb == 0 { return String(n / mb) + " MB" }
        if n >= 1024 && n % 1024 == 0 { return String(n / 1024) + " KB" }
        return String(n) + " bytes"
    }

    static func info(_ b: [UInt8]) -> String {
        let parts: [String] = [sizeText(b.count),
                               "   CRC32 ", String(format: "%08X", HexModel.crc32(b))]
        return parts.joined()
    }

    static func checksumNote(_ b: [UInt8]) -> String? {
        guard let n = macChecksumSize(b) else { return nil }
        if n == b.count { return "Mac ROM checksum OK" }
        return "Mac ROM checksum OK (first " + sizeText(n) + ")"
    }

    static func readBytes(_ url: URL) -> [UInt8]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return [UInt8](d)
    }
}

// MARK: - Split model

final class SplitModel: ObservableObject {
    struct Part: Identifiable {
        let lane: RomLane
        let bytes: [UInt8]
        let info: String
        var id: Int { lane.index }
    }

    @Published private(set) var source: URL?
    @Published private(set) var data: [UInt8] = []
    @Published var layout: RomLayout = .pair { didSet { rebuild() } }
    @Published var chipSize = 0 { didSet { rebuild() } }    // 0 = same as each part
    @Published private(set) var parts: [Part] = []
    @Published private(set) var sourceInfo = ""
    @Published private(set) var sourceChecksum: String?
    @Published var error: String?

    var partSize: Int {
        guard !data.isEmpty else { return 0 }
        return (data.count + layout.ways - 1) / layout.ways
    }

    var targetSize: Int { max(chipSize, partSize) }

    var copies: Int {
        guard partSize > 0 else { return 1 }
        return targetSize / partSize
    }

    var unevenFill: Bool { partSize > 0 && targetSize % partSize != 0 }

    // Choices for the chip size popup: each part's own size, then bigger powers of two.
    func sizeChoices(presetSize: Int?) -> [Int] {
        guard partSize > 0 else { return [0] }
        var list: [Int] = [0]
        var s = 1024
        while s <= partSize { s *= 2 }
        while s <= 16 * 1024 * 1024 && list.count < 5 {
            list.append(s)
            s *= 2
        }
        if let p = presetSize, p > partSize, !list.contains(p) {
            list.append(p)
            list.sort()
        }
        return list
    }

    func load(_ url: URL, presetSize: Int?) {
        guard let b = RomMath.readBytes(url) else {
            error = "Couldn't read " + url.lastPathComponent
            return
        }
        error = nil
        source = url
        data = b
        sourceInfo = RomMath.info(b)
        sourceChecksum = RomMath.checksumNote(b)
        pickChipSize(presetSize)
        rebuild()
    }

    // Start with the preset's chip when it's bigger than one part.
    func pickChipSize(_ presetSize: Int?) {
        if let p = presetSize, p > partSize { chipSize = p } else { chipSize = 0 }
    }

    func clear() {
        source = nil
        data = []
        parts = []
        error = nil
    }

    private func rebuild() {
        guard !data.isEmpty else { parts = []; return }
        let size = partSize
        let target = targetSize
        parts = layout.lanes.map { (lane: RomLane) -> Part in
            var p = RomMath.lane(data, ways: layout.ways, index: lane.index)
            if p.count < size {
                p.append(contentsOf: [UInt8](repeating: 0xFF, count: size - p.count))
            }
            let filled = RomMath.fill(p, to: target)
            return Part(lane: lane, bytes: filled, info: RomMath.info(filled))
        }
    }

    func fileName(for part: Part) -> String {
        let base = source?.deletingPathExtension().lastPathComponent ?? "rom"
        let ext = source?.pathExtension ?? ""
        let suffix = layout.suffix(for: part.lane)
        return base + "_" + suffix + "." + (ext.isEmpty ? "bin" : ext)
    }
}

// MARK: - Join model

final class JoinModel: ObservableObject {
    struct Slot {
        var name: String
        var bytes: [UInt8]
        var info: String
    }

    @Published var layout: RomLayout = .pair {
        didSet { if oldValue != layout { slots = [:] } }
    }
    @Published var slots: [Int: Slot] = [:] { didSet { rebuild() } }
    @Published var dropCopies = true { didSet { rebuild() } }
    @Published private(set) var result: [UInt8]?
    @Published private(set) var resultInfo = ""
    @Published private(set) var resultChecksum: String?
    @Published private(set) var note: String?
    @Published private(set) var problem: String?

    func set(_ lane: RomLane, name: String, bytes: [UInt8]) {
        slots[lane.index] = Slot(name: name, bytes: bytes, info: RomMath.info(bytes))
    }

    func load(_ url: URL, into lane: RomLane) {
        guard let b = RomMath.readBytes(url) else {
            problem = "Couldn't read " + url.lastPathComponent
            return
        }
        set(lane, name: url.lastPathComponent, bytes: b)
    }

    // Undo a split in one go: 2 or 4 files dropped together. Files are matched to
    // chips by a HI / LO / LL / ML / MH / HH word in the name, or else by name order.
    func loadAll(_ urls: [URL]) {
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let newLayout: RomLayout
        switch sorted.count {
        case 2: newLayout = .pair
        case 4: newLayout = .quad
        default:
            problem = "Drop 2 files (HI and LO) or 4 files (LL, ML, MH, HH) together."
            return
        }
        layout = newLayout
        let lanes = newLayout.lanes
        let order = Self.matchByName(sorted, lanes: lanes) ?? sorted
        var newSlots: [Int: Slot] = [:]
        for (lane, url) in zip(lanes, order) {
            guard let b = RomMath.readBytes(url) else {
                problem = "Couldn't read " + url.lastPathComponent
                return
            }
            newSlots[lane.index] = Slot(name: url.lastPathComponent, bytes: b, info: RomMath.info(b))
        }
        slots = newSlots
    }

    static func matchByName(_ urls: [URL], lanes: [RomLane]) -> [URL]? {
        var out: [URL] = []
        for lane in lanes {
            let hits = urls.filter { nameWords($0).contains(lane.name) }
            guard hits.count == 1 else { return nil }
            out.append(hits[0])
        }
        return Set(out).count == out.count ? out : nil
    }

    // "ROM_U1-LL.bin" -> ["ROM", "U1", "LL"]
    static func nameWords(_ url: URL) -> Set<String> {
        let base = url.deletingPathExtension().lastPathComponent.uppercased()
        let words = base.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Set(words)
    }

    private func rebuild() {
        result = nil
        resultInfo = ""
        resultChecksum = nil
        note = nil
        problem = nil
        let ways = layout.ways
        var parts: [[UInt8]] = []
        for k in 0..<ways {
            guard let s = slots[k] else { return }
            parts.append(s.bytes)
        }
        let sizes = Set(parts.map(\.count))
        if sizes.count > 1 {
            problem = "The parts aren't the same size. Every chip must be the same size."
            return
        }
        let size = parts.first?.count ?? 0
        guard size > 0 else { return }

        if dropCopies {
            // Use the largest repeat unit so a blank chip can't shrink the others.
            let unit = parts.map(RomMath.repeatUnit).max() ?? size
            if unit < size && unit >= 1024 && size % unit == 0 {
                parts = parts.map { Array($0[0..<unit]) }
                let n = size / unit
                note = ["Each chip holds ", String(n), " copies of ", RomMath.sizeText(unit),
                        ", so one copy was used."].joined()
            }
        }
        let joined = RomMath.interleave(parts)
        result = joined
        resultInfo = RomMath.info(joined)
        resultChecksum = RomMath.checksumNote(joined)
    }
}

// MARK: - Join model (stack files one after another, like Crucible's Join)

final class ConcatModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: [UInt8]
        let info: String
    }

    @Published var items: [Item] = [] { didSet { rebuild() } }
    @Published var padTo = 0 { didSet { rebuild() } }     // 0 = no padding
    @Published private(set) var result: [UInt8]?
    @Published private(set) var resultInfo = ""
    @Published private(set) var resultChecksum: String?
    @Published var problem: String?

    var total: Int { items.reduce(0) { $0 + $1.bytes.count } }

    func add(_ urls: [URL]) {
        problem = nil
        let sorted = urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        var list = items
        for url in sorted {
            guard let b = RomMath.readBytes(url) else {
                problem = "Couldn't read " + url.lastPathComponent
                continue
            }
            list.append(Item(url: url, bytes: b, info: RomMath.info(b)))
        }
        items = list
        if padTo != 0 && padTo < total { padTo = 0 }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if padTo != 0 && padTo < total { padTo = 0 }
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
    }

    // Chip address where each file starts.
    func start(of id: UUID) -> Int {
        var addr = 0
        for item in items {
            if item.id == id { return addr }
            addr += item.bytes.count
        }
        return addr
    }

    // "No padding", then powers of two that hold everything.
    var padChoices: [Int] {
        var list: [Int] = [0]
        guard total > 0 else { return list }
        var s = 1024
        while s < total { s *= 2 }
        while list.count < 7 && s <= 64 * 1024 * 1024 {
            list.append(s)
            s *= 2
        }
        return list
    }

    private func rebuild() {
        result = nil
        resultInfo = ""
        resultChecksum = nil
        guard !items.isEmpty else { return }
        var out: [UInt8] = []
        out.reserveCapacity(max(total, padTo))
        for item in items { out.append(contentsOf: item.bytes) }
        if padTo > out.count {
            out.append(contentsOf: [UInt8](repeating: 0xFF, count: padTo - out.count))
        }
        result = out
        resultInfo = RomMath.info(out)
        resultChecksum = RomMath.checksumNote(out)
    }
}

// MARK: - Window

struct RomTools: View {
    let preset: Preset
    let presetSize: Int?

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var runner: MiniproRunner
    @Environment(\.dismiss) private var dismiss

    @StateObject private var split = SplitModel()
    @StateObject private var join = JoinModel()
    @StateObject private var concat = ConcatModel()

    @State private var tab = 0
    @State private var addToList = true
    @State private var saved: String?
    @State private var readingLane: Int?
    @State private var sourceTargeted = false
    @State private var laneTargeted: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Split").tag(0)
                    Text("Undo Split").tag(1)
                    Text("Join").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            if tab == 0 {
                splitPane
            } else if tab == 1 {
                joinPane
            } else {
                concatPane
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: split.layout) { _ in split.pickChipSize(presetSize) }
        .onChange(of: tab) { _ in saved = nil }
    }

    // MARK: Split

    private var splitPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Split one ROM file into a file per chip.")
                .foregroundColor(.secondary)

            sourceBox

            HStack(spacing: 20) {
                Picker("Chips:", selection: $split.layout) {
                    ForEach(RomLayout.allCases) { l in Text(l.title).tag(l) }
                }
                .frame(width: 260)

                Picker("Chip size:", selection: $split.chipSize) {
                    ForEach(split.sizeChoices(presetSize: presetSize), id: \.self) { s in
                        Text(verbatim: sizeLabel(s)).tag(s)
                    }
                }
                .frame(width: 300)
                .disabled(split.data.isEmpty)
            }

            Text(verbatim: chipSizeHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !split.data.isEmpty { fillNote }

            if !split.parts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(split.parts) { part in
                        HStack(spacing: 12) {
                            Text(verbatim: part.lane.name)
                                .font(.system(.body, design: .monospaced)).bold()
                                .frame(width: 40, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: split.fileName(for: part))
                                Text(verbatim: part.lane.bus)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(verbatim: part.info)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            }

            HStack(spacing: 12) {
                Button("Save Parts…", action: saveParts)
                    .buttonStyle(.borderedProminent)
                    .disabled(split.parts.isEmpty)
                Toggle("Put them in the file list, ready to write", isOn: $addToList)
                    .toggleStyle(.checkbox)
                    .disabled(session.isBusy)
            }
            if let s = saved {
                Label(s, systemImage: "checkmark.circle.fill").foregroundColor(.green)
            }
            if let e = split.error {
                Text(verbatim: e).foregroundColor(.red)
            }
        }
    }

    private var sourceBox: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            if let url = split.source {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: url.lastPathComponent).bold()
                    Text(verbatim: split.sourceInfo)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let c = split.sourceChecksum {
                        Text(verbatim: c).font(.caption).foregroundColor(.green)
                    }
                }
            } else {
                Text("Drop a ROM file here").foregroundColor(.secondary)
            }
            Spacer()
            Button("Choose File…") {
                if let url = chooseFile() {
                    saved = nil
                    split.load(url, presetSize: presetSize)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(sourceTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: sourceTargeted ? 2 : 1, dash: [5, 3]))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $sourceTargeted) { providers in
            dropURL(providers) { url in
                saved = nil
                split.load(url, presetSize: presetSize)
            }
        }
    }

    @ViewBuilder private var fillNote: some View {
        let part = RomMath.sizeText(split.partSize)
        if split.copies > 1 {
            let chip = RomMath.sizeText(split.targetSize)
            let text: String = ["Each part is ", part, ". It is repeated ×", String(split.copies),
                                " to fill a ", chip, " chip."].joined()
            Label(text, systemImage: "square.on.square").foregroundColor(.secondary)
        } else {
            Label("Each part is " + part + ".", systemImage: "info.circle").foregroundColor(.secondary)
        }
        if split.unevenFill {
            Text("The chip isn't a whole multiple of the part size. The leftover space is filled with FF.")
                .font(.caption).foregroundColor(.orange)
        }
        if split.data.count % split.layout.ways != 0 {
            Text("The file size doesn't divide evenly between the chips. The last part is padded with FF.")
                .font(.caption).foregroundColor(.orange)
        }
    }

    private var chipSizeHint: String {
        if let p = presetSize, !preset.device.isEmpty {
            let parts: [String] = ["By default, each part is made to fit the chip in the current preset (",
                                   preset.device, ", ", RomMath.sizeText(p),
                                   "). If you're going to flash a different chip, pick its size here."]
            return parts.joined()
        }
        return "Pick the size of the chip you're going to flash. Each part is repeated to fill it."
    }

    private func sizeLabel(_ s: Int) -> String {
        if s == 0 {
            if split.partSize == 0 { return "Same as each part" }
            return "Same as each part (" + RomMath.sizeText(split.partSize) + ")"
        }
        var label = RomMath.sizeText(s)
        if split.partSize > 0 && s % split.partSize == 0 {
            label += " (×" + String(s / split.partSize) + ")"
        }
        if let p = presetSize, p == s { label += " · " + preset.device }
        return label
    }

    private func saveParts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.title = "Choose a folder for the parts"
        panel.directoryURL = split.source?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let targets: [URL] = split.parts.map { dir.appendingPathComponent(split.fileName(for: $0)) }
        let existing = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the existing files?"
            alert.informativeText = existing.map(\.lastPathComponent).joined(separator: "\n")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }

        do {
            for (part, url) in zip(split.parts, targets) {
                try Data(part.bytes).write(to: url, options: .atomic)
            }
        } catch {
            split.error = "Couldn't save: " + error.localizedDescription
            return
        }
        let names = targets.map(\.lastPathComponent).joined(separator: ", ")
        runner.append(.success, "Saved " + names)
        if addToList && !session.isBusy {
            session.clearFiles()
            session.addFiles(targets)
            saved = "Saved, and put in the file list. Insert the first chip and press Write."
        } else {
            saved = "Saved " + String(targets.count) + " files."
        }
    }

    // MARK: Join

    private var joinPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Put split parts back together as the entire ROM. Drop all 2 or 4 files at once, or load each part on its own, from a file or straight from the chip.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Picker("Chips:", selection: $join.layout) {
                    Text(RomLayout.pair.title).tag(RomLayout.pair)
                    Text(RomLayout.quad.title).tag(RomLayout.quad)
                }
                .frame(width: 260)
                Button("Choose All Parts…") {
                    let urls = chooseFiles()
                    if !urls.isEmpty {
                        saved = nil
                        join.loadAll(urls)
                    }
                }
            }

            VStack(spacing: 0) {
                ForEach(join.layout.lanes, id: \.self) { lane in
                    joinRow(lane)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))

            Toggle("Drop repeated copies (when the chips are bigger than the ROM)", isOn: $join.dropCopies)
                .toggleStyle(.checkbox)

            if let p = join.problem {
                Text(verbatim: p).foregroundColor(.red)
            }
            if join.result != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Result").bold()
                    Text(verbatim: join.resultInfo)
                        .font(.system(.body, design: .monospaced))
                    if let n = join.note {
                        Text(verbatim: n).font(.caption).foregroundColor(.secondary)
                    }
                    if let c = join.resultChecksum {
                        Text(verbatim: c).font(.caption).foregroundColor(.green)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Save ROM…", action: saveJoined)
                    .buttonStyle(.borderedProminent)
                    .disabled(join.result == nil)
                if let s = saved {
                    Label(s, systemImage: "checkmark.circle.fill").foregroundColor(.green)
                }
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            dropURLs(providers) { urls in
                saved = nil
                join.loadAll(urls)
            }
        }
    }

    // MARK: Join (stack)

    private var concatPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stack files one after another into one ROM, for example a ROM followed by a disk image. Each file starts where the one before it ends.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Add Files…") {
                    let urls = chooseFiles(title: "Choose files to stack")
                    if !urls.isEmpty {
                        saved = nil
                        concat.add(urls)
                    }
                }
                Button("Clear") { concat.items = []; concat.padTo = 0 }
                    .disabled(concat.items.isEmpty)
                Spacer()
                Picker("Fill the end to:", selection: $concat.padTo) {
                    ForEach(concat.padChoices, id: \.self) { s in
                        Text(verbatim: s == 0 ? "No padding" : RomMath.sizeText(s) + " (FF)").tag(s)
                    }
                }
                .frame(width: 260)
                .disabled(concat.items.isEmpty)
            }

            if concat.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 26)).foregroundColor(.secondary)
                    Text("Drop files here, in the order they go in the ROM").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(concat.items.enumerated()), id: \.element.id) { index, item in
                        concatRow(index: index, item: item)
                        Divider()
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
            }

            if let p = concat.problem {
                Text(verbatim: p).foregroundColor(.red)
            }
            if concat.result != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Result").bold()
                    Text(verbatim: concat.resultInfo)
                        .font(.system(.body, design: .monospaced))
                    if let c = concat.resultChecksum {
                        Text(verbatim: c).font(.caption).foregroundColor(.green)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Save ROM…", action: saveConcat)
                    .buttonStyle(.borderedProminent)
                    .disabled(concat.result == nil)
                Toggle("Put it in the file list, ready to write", isOn: $addToList)
                    .toggleStyle(.checkbox)
                    .disabled(session.isBusy)
            }
            if let s = saved {
                Label(s, systemImage: "checkmark.circle.fill").foregroundColor(.green)
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            dropURLs(providers) { urls in
                saved = nil
                concat.add(urls)
            }
        }
    }

    private func concatRow(index: Int, item: ConcatModel.Item) -> some View {
        let start = concat.start(of: item.id)
        let end = start + item.bytes.count - 1
        let range: String = [HexModel.hex(start), " - ", HexModel.hex(max(start, end))].joined()
        return HStack(spacing: 12) {
            Text(verbatim: "#" + String(index + 1))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.url.lastPathComponent).lineLimit(1)
                Text(verbatim: range)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(verbatim: item.info)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Button { concat.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
            Button { concat.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == concat.items.count - 1)
            Button { concat.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    private func saveConcat() {
        guard let r = concat.result else { return }
        let panel = NSSavePanel()
        let first = concat.items.first?.url
        let base = first?.deletingPathExtension().lastPathComponent ?? "rom"
        let ext = first?.pathExtension ?? ""
        panel.nameFieldStringValue = base + "_joined." + (ext.isEmpty ? "bin" : ext)
        panel.directoryURL = first?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.title = "Save the joined ROM"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(r).write(to: url, options: .atomic)
        } catch {
            concat.problem = "Couldn't save: " + error.localizedDescription
            return
        }
        runner.append(.success, "Saved " + url.lastPathComponent)
        if addToList && !session.isBusy {
            session.clearFiles()
            session.addFiles([url])
            saved = "Saved, and put in the file list."
        } else {
            saved = "Saved " + url.lastPathComponent
        }
    }

    // "MacSE_HI.bin" or "IIci_1-LL.bin" -> "MacSE.bin" / "IIci.bin"
    private func joinedName() -> String {
        let first = join.layout.lanes.first.flatMap { join.slots[$0.index]?.name } ?? ""
        let url = URL(fileURLWithPath: first)
        var base = url.deletingPathExtension().lastPathComponent
        let pattern = "[ _-]*(U?[0-9][ _-]*)?(HI|LO|LL|ML|MH|HH)$"
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let ns = base as NSString
            if let m = re.firstMatch(in: base, range: NSRange(location: 0, length: ns.length)), m.range.location > 0 {
                base = ns.substring(to: m.range.location)
            }
        }
        if base.isEmpty || first.isEmpty || first.contains(" read from ") { base = "joined" }
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        return base + "." + ext
    }

    private func joinRow(_ lane: RomLane) -> some View {
        let slot = join.slots[lane.index]
        let canRead = !preset.device.isEmpty && !preset.isLogicDevice && !session.isBusy
        return HStack(spacing: 12) {
            Text(verbatim: lane.name)
                .font(.system(.body, design: .monospaced)).bold()
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                if let s = slot {
                    Text(verbatim: s.name).lineLimit(1)
                    Text(verbatim: s.info)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                } else if readingLane == lane.index {
                    Text("Reading…").foregroundColor(.secondary)
                } else {
                    Text("Drop a file here").foregroundColor(.secondary)
                }
                Text(verbatim: lane.bus).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Choose File…") {
                if let url = chooseFile() {
                    saved = nil
                    join.load(url, into: lane)
                }
            }
            Button("Read Chip") { readChip(into: lane) }
                .disabled(!canRead)
                .help(Text(verbatim: "Read the chip in the socket with preset " + preset.name))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(laneTargeted == lane.index ? Color.accentColor.opacity(0.15) : Color.clear)
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { laneTargeted == lane.index },
            set: { on in laneTargeted = on ? lane.index : (laneTargeted == lane.index ? nil : laneTargeted) }
        )) { providers in
            dropURLs(providers) { urls in
                saved = nil
                if urls.count > 1 {
                    join.loadAll(urls)
                } else if let url = urls.first {
                    join.load(url, into: lane)
                }
            }
        }
    }

    private func readChip(into lane: RomLane) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("keroburn-read-" + UUID().uuidString + ".bin")
        var args = ["-p", preset.device, "-r", tmp.path]
        if preset.ignoreIDError { args.append("-y") }
        readingLane = lane.index
        saved = nil
        runner.run(args) { status, output in
            readingLane = nil
            if status == 0, let b = RomMath.readBytes(tmp) {
                let label: String = [lane.name, " read from ", preset.device].joined()
                join.set(lane, name: label, bytes: b)
            } else {
                let tail: String = output.last ?? ""
                join.slots[lane.index] = nil
                runner.append(.error, ["Read failed (exit ", String(status), "). ", tail].joined())
            }
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func saveJoined() {
        guard let r = join.result else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = joinedName()
        panel.canCreateDirectories = true
        panel.title = "Save the joined ROM"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(r).write(to: url, options: .atomic)
            runner.append(.success, "Saved " + url.lastPathComponent)
            saved = "Saved " + url.lastPathComponent
        } catch {
            runner.append(.error, "Couldn't save: " + error.localizedDescription)
        }
    }

    // MARK: Helpers

    private func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseFiles(title: String = "Choose the 2 or 4 parts") -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = title
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func dropURLs(_ providers: [NSItemProvider], _ handle: @escaping ([URL]) -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { handle(urls) }
        return true
    }

    private func dropURL(_ providers: [NSItemProvider], _ handle: @escaping (URL) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async { handle(url) }
        }
        return true
    }
}
