import SwiftUI
import AppKit

// Logic IC test (minipro -T). minipro drives each test vector into the chip,
// reads every pin back with pull-ups and then pull-downs, and prints a table
// with a '-' after every pin that didn't match.

// MARK: - Catalog (logicic.xml)

struct LogicChip: Identifiable, Hashable {
    let name: String
    let aliases: [String]   // other names sharing the same test vectors
    let pins: Int
    let voltage: String
    var id: String { name }
}

final class LogicCatalog: ObservableObject {
    @Published private(set) var chips: [LogicChip] = []
    @Published private(set) var failure: String?
    private var loaded = false

    func load() {
        guard !loaded else { return }
        guard let exe = MiniproLocator.resolve() else {
            failure = "minipro not found"
            return
        }
        guard let url = Self.logicicURL(for: exe) else {
            failure = "logicic.xml not found next to minipro's database"
            return
        }
        loaded = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = Self.parse(url)
            DispatchQueue.main.async {
                self.chips = list
                if list.isEmpty { self.failure = "Could not read " + url.path }
            }
        }
    }

    static func logicicURL(for exe: URL) -> URL? {
        let candidates: [URL?] = [
            MiniproLocator.bundledDatabaseDir?.appendingPathComponent("logicic.xml"),
            MiniproLocator.infoicURL(for: exe)?.deletingLastPathComponent().appendingPathComponent("logicic.xml"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    // <ic name="7400,7437,74132" type="5" voltage="5V" pins="14">
    static func parse(_ url: URL) -> [LogicChip] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let pattern = "<ic\\s+name=\"([^\"]+)\"[^>]*?voltage=\"([^\"]*)\"[^>]*?pins=\"([0-9]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [LogicChip] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges > 3 else { return }
            let names = ns.substring(with: m.range(at: 1)).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let voltage = ns.substring(with: m.range(at: 2))
            let pins = Int(ns.substring(with: m.range(at: 3))) ?? 0
            for name in names where seen.insert(name).inserted {
                let others = names.filter { $0 != name }
                out.append(LogicChip(name: name, aliases: others, pins: pins, voltage: voltage))
            }
        }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return out
    }
}

// MARK: - Result

struct LogicResult {
    struct Cell {
        let state: Character   // 0 1 L H C Z X G V
        let bad: Bool
    }

    var rows: [[Cell]] = []
    var passed = false
    var errorCount = 0
    var message = ""

    // Pins that failed at least once, with how many vectors they failed in.
    var badPins: [(pin: Int, count: Int)] {
        var counts: [Int: Int] = [:]
        for row in rows {
            for (i, c) in row.enumerated() where c.bad { counts[i + 1, default: 0] += 1 }
        }
        return counts.keys.sorted().map { (pin: $0, count: counts[$0] ?? 0) }
    }

    // "0003: 1  1  L- 1  ..." -> three characters per pin: state, '-' or ' ', space.
    static func parse(_ lines: [String], pins: Int, status: Int32) -> LogicResult {
        var r = LogicResult()
        for line in lines {
            let chars = Array(line)
            guard chars.count > 6, chars[4] == ":",
                  chars[0...3].allSatisfy({ $0.isNumber }) else { continue }
            var row: [Cell] = []
            var i = 6
            while i < chars.count && row.count < pins {
                let state = chars[i]
                let bad = i + 1 < chars.count && chars[i + 1] == "-"
                row.append(Cell(state: state, bad: bad))
                i += 3
            }
            if !row.isEmpty { r.rows.append(row) }
        }
        r.errorCount = r.rows.reduce(0) { sum, row in sum + row.filter(\.bad).count }
        r.passed = status == 0 && !r.rows.isEmpty && r.errorCount == 0

        if r.passed {
            r.message = "Logic test passed"
        } else if r.errorCount > 0 {
            r.message = "Logic test failed: " + String(r.errorCount) + (r.errorCount == 1 ? " error" : " errors")
        } else {
            // No table at all: the programmer, the chip name or the socket is the problem.
            let useful = lines.last { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("Found") && !t.hasPrefix("Warning")
            }
            r.message = useful ?? ("minipro stopped (exit " + String(status) + ")")
        }
        return r
    }
}

// MARK: - Window

struct LogicTestView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var runner: MiniproRunner
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = LogicCatalog()

    @AppStorage("logicTestChip") private var chipName = "7400"
    @State private var query = ""
    @State private var result: LogicResult?
    @State private var testedChip: LogicChip?

    private var selected: LogicChip? { catalog.chips.first { $0.name == chipName } }

    private var filtered: [LogicChip] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return catalog.chips }
        return catalog.chips.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logic IC Test").font(.title3).bold()
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                chipList
                VStack(alignment: .leading, spacing: 12) {
                    chipInfo
                    resultView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { catalog.load() }
    }

    // MARK: Chip list

    private var chipList: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search (7400, 74LS245, 4013…)", text: $query)
                .textFieldStyle(.roundedBorder)
            if let f = catalog.failure {
                Text(verbatim: f).foregroundColor(.red).font(.caption)
            }
            ScrollViewReader { proxy in
                List(filtered, id: \.name, selection: listSelection) { chip in
                    HStack {
                        Text(verbatim: chip.name)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(verbatim: String(chip.pins) + " pins")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .id(chip.name)
                }
                .onAppear { proxy.scrollTo(chipName, anchor: .center) }
            }
            Text(verbatim: String(catalog.chips.count) + " logic ICs in minipro's list")
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(width: 240)
    }

    private var listSelection: Binding<String?> {
        Binding(
            get: { chipName },
            set: { name in
                guard let name = name, name != chipName else { return }
                chipName = name
                result = nil
            }
        )
    }

    // MARK: Chip info and Test button

    @ViewBuilder private var chipInfo: some View {
        if let chip = selected {
            HStack(alignment: .top, spacing: 16) {
                DipSketch(pins: chip.pins)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: chip.name).font(.title2).bold()
                    Text(verbatim: [String(chip.pins), "-pin DIP, ", chip.voltage].joined())
                        .foregroundColor(.secondary)
                    if !chip.aliases.isEmpty {
                        Text(verbatim: "Same test as " + chip.aliases.joined(separator: ", "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Text("Put the chip in the socket with pin 1 at the top left, next to the lever, the same way as an EPROM.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            runTest(chip)
                        } label: {
                            Label("Test", systemImage: "play.fill").frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(session.isBusy)
                        if runner.isRunning { ProgressView().controlSize(.small) }
                    }
                }
            }
        } else if catalog.chips.isEmpty && catalog.failure == nil {
            ProgressView("Loading the logic IC list…")
        } else {
            Text("Pick a chip from the list.").foregroundColor(.secondary)
        }
    }

    private func runTest(_ chip: LogicChip) {
        result = nil
        testedChip = chip
        runner.run(["-p", chip.name, "-T"]) { status, output in
            let r = LogicResult.parse(output, pins: chip.pins, status: status)
            result = r
            if r.passed {
                runner.append(.success, chip.name + ": logic test passed")
                Sounds.success()
            } else {
                runner.append(.error, chip.name + ": " + r.message)
                Sounds.failure()
            }
        }
    }

    // MARK: Result

    @ViewBuilder private var resultView: some View {
        if let r = result, let chip = testedChip {
            Divider()
            if r.passed {
                Label(r.message, systemImage: "checkmark.circle.fill")
                    .font(.title3).foregroundColor(.green)
            } else {
                Label(r.message, systemImage: "xmark.octagon.fill")
                    .font(.title3).foregroundColor(.red)
            }
            if !r.badPins.isEmpty {
                let list = r.badPins.map { p in
                    ["pin ", String(p.pin), " (", String(p.count), "/", String(r.rows.count), ")"].joined()
                }
                Text(verbatim: "Wrong on " + list.joined(separator: ", "))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !r.rows.isEmpty {
                vectorTable(r, pins: chip.pins)
                Text("0 / 1: driven by the programmer   L / H: expected low / high   Z: expected floating   C: clock   X: not checked   G / V: ground / VCC. Red cells didn't match.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func vectorTable(_ r: LogicResult, pins: Int) -> some View {
        // Grow with the number of vectors, up to a point, and keep the table at the top left.
        let height = min(CGFloat(r.rows.count) * 19 + 34, 320)
        return GeometryReader { geo in
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 1) {
                    Text(verbatim: "#").frame(width: 34, alignment: .trailing)
                    ForEach(1...max(pins, 1), id: \.self) { pin in
                        Text(verbatim: String(pin)).frame(width: 24)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

                ForEach(Array(r.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 1) {
                        Text(verbatim: String(index)).frame(width: 34, alignment: .trailing)
                            .foregroundColor(.secondary)
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(verbatim: String(cell.state))
                                .frame(width: 24, height: 18)
                                .foregroundColor(cell.bad ? .white : color(for: cell.state))
                                .background(cell.bad ? Color.red : Color.clear)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            .padding(6)
            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
        }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
    }

    private func color(for state: Character) -> Color {
        switch state {
        case "L", "H", "Z": return .primary
        case "G", "V", "X": return .secondary
        default: return .accentColor
        }
    }
}

// A small top view of the chip with the notch and pin 1 marked.
struct DipSketch: View {
    let pins: Int

    var body: some View {
        let side = max(pins / 2, 1)
        let height = CGFloat(side) * 9 + 14
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(NSColor.darkGray))
                .frame(width: 44, height: height)
            Circle()
                .fill(Color(NSColor.windowBackgroundColor))
                .frame(width: 12, height: 12)
                .offset(x: 16, y: -6)
            Circle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 5, height: 5)
                .offset(x: 6, y: 8)
            Text(verbatim: "1")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.accentColor)
                .offset(x: -12, y: 4)
        }
        .frame(width: 60, height: height, alignment: .topTrailing)
        .clipped()
        .help("Top view. The notch and the dot mark pin 1.")
    }
}
