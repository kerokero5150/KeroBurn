import Foundation

enum AppInfo {
    static let name = "KeroBurn"
}

// Where a file goes on the chip. Maps to KeroBurn's minipro options
// --offset / --file_offset / --length / --keep (patches/keroburn-place-at-offset.patch).
struct Placement: Codable, Hashable {
    var offset: UInt32 = 0       // chip address the file starts at
    var fileOffset: UInt32 = 0   // where in the file to start
    var length: UInt32 = 0       // bytes to take, 0 = rest of the file
    var keep = false             // keep the chip's contents outside the range

    var isDefault: Bool { offset == 0 && fileOffset == 0 && length == 0 && !keep }

    var args: [String] {
        if isDefault { return [] }
        var a: [String] = ["--offset", Placement.hex(offset)]
        if fileOffset != 0 { a += ["--file_offset", Placement.hex(fileOffset)] }
        if length != 0 { a += ["--length", Placement.hex(length)] }
        if keep { a.append("--keep") }
        return a
    }

    // Short label for the file list, e.g. "at 0x8000, keep rest"
    var summary: String {
        var parts: [String] = ["at " + Placement.hex(offset)]
        if fileOffset != 0 { parts.append("from file " + Placement.hex(fileOffset)) }
        if length != 0 { parts.append(Placement.hex(length) + " bytes") }
        if keep { parts.append("keep rest") }
        return parts.joined(separator: ", ")
    }

    static func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16, uppercase: true) }

    // Accepts "8000", "0x8000", "$8000" (always hex). Empty means 0.
    static func parse(_ text: String) -> UInt32? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return 0 }
        if t.hasPrefix("0x") { t.removeFirst(2) }
        if t.hasPrefix("$") { t.removeFirst() }
        return UInt32(t, radix: 16)
    }
}

// A file remembered by a preset.
struct SavedFile: Codable, Hashable {
    var path: String
    var placement: Placement?
}

// A folder in the sidebar that groups presets.
struct PresetFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var expanded = true
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
    var skipPinCheck = false    // when false, a pin contact test (-z) runs before every write
    var icon = ""               // optional emoji shown in the sidebar
    var files: [SavedFile] = [] // files this preset loads by itself, in order
    var folder: UUID?           // sidebar folder, nil = not in a folder

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
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        files = try c.decodeIfPresent([SavedFile].self, forKey: .files) ?? []
        skipPinCheck = try c.decodeIfPresent(Bool.self, forKey: .skipPinCheck) ?? false
        folder = try c.decodeIfPresent(UUID.self, forKey: .folder)
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
        Preset(name: "ATF16V8B", device: "ATF16V8B"),
        Preset(name: "ATF22V10C", device: "ATF22V10C"),
    ]
}

// Loads and saves presets as JSON in ~/Library/Application Support/KeroBurn/.
final class PresetStore: ObservableObject {
    @Published var presets: [Preset] = [] {
        didSet { save() }
    }

    // Kept in their own file so presets.json stays a plain list.
    @Published var folders: [PresetFolder] = [] {
        didSet { saveFolders() }
    }

    let fileURL: URL
    let foldersURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(AppInfo.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("presets.json")
        foldersURL = dir.appendingPathComponent("folders.json")
        load()
        loadFolders()
        // A preset pointing at a folder that no longer exists goes back to the top level,
        // so it can't disappear from the sidebar.
        let known = Set(folders.map(\.id))
        if presets.contains(where: { $0.folder != nil && !known.contains($0.folder!) }) {
            var list = presets
            for i in list.indices where list[i].folder != nil && !known.contains(list[i].folder!) {
                list[i].folder = nil
            }
            presets = list
        }
    }

    func loadFolders() {
        if let data = try? Data(contentsOf: foldersURL),
           let list = try? JSONDecoder().decode([PresetFolder].self, from: data) {
            folders = list
        }
    }

    func saveFolders() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(folders) {
            try? data.write(to: foldersURL, options: .atomic)
        }
    }

    @discardableResult
    func addFolder(named name: String) -> PresetFolder {
        let f = PresetFolder(name: name)
        folders.append(f)
        return f
    }

    // Removing a folder keeps its presets; they move back to the top level.
    func removeFolder(_ id: UUID) {
        var list = presets
        for i in list.indices where list[i].folder == id { list[i].folder = nil }
        presets = list
        folders.removeAll { $0.id == id }
    }

    func setFolder(_ folder: UUID?, for presetID: UUID) {
        guard let i = index(of: presetID) else { return }
        presets[i].folder = folder
        if let f = folder, let fi = folders.firstIndex(where: { $0.id == f }) {
            folders[fi].expanded = true
        }
    }

    // Drag and drop: put a preset into `folder` (nil = top level) at position `index`
    // among that folder's presets. Works for reordering inside a folder too.
    func place(_ presetID: UUID, in folder: UUID?, at index: Int?) {
        guard let from = self.index(of: presetID) else { return }
        var all = presets
        var item = all[from]
        let sameGroup = item.folder == folder
        let oldPos = all[..<from].filter { $0.folder == folder }.count
        all.remove(at: from)
        item.folder = folder

        let slots = all.indices.filter { all[$0].folder == folder }
        var pos = index ?? slots.count
        if sameGroup && pos > oldPos { pos -= 1 }   // the list was counted with the item still in it
        pos = max(0, min(pos, slots.count))

        let target: Int
        if pos < slots.count {
            target = slots[pos]
        } else if let last = slots.last {
            target = last + 1
        } else {
            target = all.count
        }
        all.insert(item, at: target)
        presets = all
        if let f = folder, let fi = folders.firstIndex(where: { $0.id == f }) {
            folders[fi].expanded = true
        }
    }

    // Reorder within one folder (or the top level), leaving the others where they are.
    func movePresets(in folder: UUID?, from: IndexSet, to: Int) {
        var group = presets.filter { $0.folder == folder }
        group.move(fromOffsets: from, toOffset: to)
        var all = presets
        var next = 0
        for i in all.indices where all[i].folder == folder {
            all[i] = group[next]
            next += 1
        }
        presets = all
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
        folders = []
    }

    func index(of id: UUID?) -> Int? {
        guard let id = id else { return nil }
        return presets.firstIndex { $0.id == id }
    }
}
