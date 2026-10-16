import Foundation

enum AppInfo {
    static let name = "KeroBurn"
}

// A saved chip setup: a friendly name plus the exact minipro device string.
struct Preset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var device: String
    var note: String = ""
    var skipSizeCheck = false   // -s : don't fail when the file size differs from the chip size
    var ignoreIDError = false   // -y : keep going when the chip ID doesn't match
    var noVerify = false        // -v : skip the verify pass after writing
    var unprotect = false       // -u : turn off write protection before writing (AT28C, 28F, etc.)
    var protectAfter = false    // -P : turn write protection back on after writing

    init(name: String, device: String, note: String = "",
         skipSizeCheck: Bool = false, ignoreIDError: Bool = false, noVerify: Bool = false) {
        self.name = name
        self.device = device
        self.note = note
        self.skipSizeCheck = skipSizeCheck
        self.ignoreIDError = ignoreIDError
        self.noVerify = noVerify
    }

    // Tolerant decoding so hand-edited JSON with missing keys still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        skipSizeCheck = try c.decodeIfPresent(Bool.self, forKey: .skipSizeCheck) ?? false
        ignoreIDError = try c.decodeIfPresent(Bool.self, forKey: .ignoreIDError) ?? false
        noVerify = try c.decodeIfPresent(Bool.self, forKey: .noVerify) ?? false
        unprotect = try c.decodeIfPresent(Bool.self, forKey: .unprotect) ?? false
        protectAfter = try c.decodeIfPresent(Bool.self, forKey: .protectAfter) ?? false
    }

    // PLDs read and write JEDEC files instead of raw binaries.
    var isLogicDevice: Bool {
        let d = device.uppercased()
        return ["GAL", "ATF16", "ATF20", "ATF22", "ATF750", "PALCE", "PEEL"].contains { d.hasPrefix($0) }
    }

    var fileExtension: String { isLogicDevice ? "jed" : "bin" }

    static let defaults: [Preset] = [
        Preset(name: "SST39SF040 (DIP32)", device: "SST39SF040"),
        Preset(name: "SST39SF040 (PLCC32)", device: "SST39SF040@PLCC32"),
        Preset(name: "AM29F040 (DIP32)", device: "AM29F040@DIP32"),
        Preset(name: "AM29F040 (PLCC32)", device: "AM29F040@PLCC32"),
        Preset(name: "A29040 (DIP32)", device: "A29040"),
        Preset(name: "A29040 (PLCC32)", device: "A29040L@PLCC32"),
        Preset(name: "GAL16V8", device: "GAL16V8D"),
        Preset(name: "GAL20V8", device: "GAL20V8B"),
        Preset(name: "GAL22V10", device: "GAL22V10D"),
    ]
}

// Loads and saves presets as JSON in ~/Library/Application Support/KeroBurn/.
final class PresetStore: ObservableObject {
    @Published var presets: [Preset] = [] {
        didSet { save() }
    }

    let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("presets.json")
        load()
    }

    func load() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
               let list = try? JSONDecoder().decode([Preset].self, from: data) {
                presets = list
                return
            }
            // Keep a broken file around instead of silently overwriting it.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("presets.broken-\(stamp).json")
            try? fm.moveItem(at: fileURL, to: backup)
        }
        presets = Preset.defaults
        save()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(presets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func resetToDefaults() {
        presets = Preset.defaults
    }

    func index(of id: UUID?) -> Int? {
        guard let id = id else { return nil }
        return presets.firstIndex { $0.id == id }
    }
}
