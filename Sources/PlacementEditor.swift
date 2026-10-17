import SwiftUI

// Popover for "where on the chip does this file go". Same idea as the
// file load dialog in Xgpro: chip address, start in the file, length.
struct PlacementEditor: View {
    let fileName: String
    let fileSize: Int64
    let onDone: (Placement?) -> Void
    private let original: Placement?

    @State private var offsetText: String
    @State private var fileOffsetText: String
    @State private var lengthText: String
    @State private var keep: Bool

    init(fileName: String, fileSize: Int64, placement: Placement, onDone: @escaping (Placement?) -> Void) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.onDone = onDone
        self.original = placement.isDefault ? nil : placement
        _offsetText = State(initialValue: placement.offset == 0 ? "" : String(placement.offset, radix: 16, uppercase: true))
        _fileOffsetText = State(initialValue: placement.fileOffset == 0 ? "" : String(placement.fileOffset, radix: 16, uppercase: true))
        _lengthText = State(initialValue: placement.length == 0 ? "" : String(placement.length, radix: 16, uppercase: true))
        _keep = State(initialValue: placement.keep)
    }

    private var parsed: Placement? {
        guard let o = Placement.parse(offsetText),
              let f = Placement.parse(fileOffsetText),
              let l = Placement.parse(lengthText) else { return nil }
        return Placement(offset: o, fileOffset: f, length: l, keep: keep)
    }

    private var problem: String? {
        guard let p = parsed else { return "Use hex numbers, like 8000 or 0x8000." }
        if Int64(p.fileOffset) >= fileSize && fileSize > 0 { return "Start in file is past the end of the file." }
        if p.length > 0 && Int64(p.fileOffset) + Int64(p.length) > fileSize { return "The file is shorter than that." }
        return nil
    }

    private var bytesText: String {
        guard let p = parsed else { return "" }
        let n: Int64 = p.length > 0 ? Int64(p.length) : max(0, fileSize - Int64(p.fileOffset))
        let end: Int64 = Int64(p.offset) + n - 1
        if n <= 0 { return "" }
        return "Writes 0x" + String(n, radix: 16, uppercase: true) + " bytes to chip 0x"
            + String(p.offset, radix: 16, uppercase: true) + "-0x" + String(end, radix: 16, uppercase: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: fileName).font(.headline).lineLimit(1).truncationMode(.middle)
            Grid3(label: "Chip address", text: $offsetText, hint: "0")
            Grid3(label: "Start in file", text: $fileOffsetText, hint: "0")
            Grid3(label: "Length", text: $lengthText, hint: "rest of file")
            Toggle("Keep what's already on the chip outside this range", isOn: $keep)
                .toggleStyle(.checkbox)
            Text("Without it, everything else on the chip ends up blank (FF). With it, the chip is read first and only this range changes. UV EPROMs can't be changed this way unless the new bytes only clear bits.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let msg = problem {
                Text(verbatim: msg).font(.caption).foregroundColor(.red)
            } else {
                Text(verbatim: bytesText).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
            }
            HStack {
                Button("Reset") { onDone(nil) }
                Spacer()
                Button("Cancel") { onDone(original) }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onDone(parsed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

private struct Grid3: View {
    let label: String
    @Binding var text: String
    let hint: String

    var body: some View {
        HStack {
            Text(label).frame(width: 96, alignment: .trailing).foregroundColor(.secondary)
            Text("0x").foregroundColor(.secondary).font(.system(.body, design: .monospaced))
            TextField(hint, text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(width: 140)
        }
    }
}
