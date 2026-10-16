import SwiftUI
import AppKit

struct PresetEditor: View {
    @EnvironmentObject private var catalog: DeviceCatalog
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Preset
    @State private var query: String
    let isNew: Bool
    let onSave: (Preset) -> Void

    init(preset: Preset, isNew: Bool, onSave: @escaping (Preset) -> Void) {
        _draft = State(initialValue: preset)
        _query = State(initialValue: preset.device.components(separatedBy: "@").first ?? "")
        self.isNew = isNew
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.device.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: isNew ? String("New Preset") : String("Edit Preset"))
                .font(.title2).bold()

            row("Name") {
                TextField("e.g. ROM-inator HI (PLCC32)", text: $draft.name)
            }

            row("Device") {
                HStack {
                    TextField("minipro device name", text: $draft.device)
                        .font(.system(.body, design: .monospaced))
                    deviceStatus
                }
            }

            row("Find") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search minipro's list, e.g. 39SF040 or 20V8", text: $query)
                    resultsList
                }
            }

            row("Note") {
                TextField("Optional, e.g. which board this is for", text: $draft.note)
            }

            row("Options") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow size mismatch (-s)", isOn: $draft.skipSizeCheck)
                    Toggle("Ignore ID check (-y)", isOn: $draft.ignoreIDError)
                    Toggle("Skip verify after write (-v)", isOn: $draft.noVerify)
                    Toggle("Unprotect before write (-u)", isOn: $draft.unprotect)
                    Toggle("Protect after write (-P)", isOn: $draft.protectAfter)
                    Toggle("Ignore pin check", isOn: $draft.skipPinCheck)
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespaces)
                    draft.device = draft.device.trimmingCharacters(in: .whitespaces)
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if !catalog.isLoaded { catalog.load() }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .frame(width: 64, alignment: .trailing)
                .foregroundColor(.secondary)
            content()
        }
    }

    @ViewBuilder private var deviceStatus: some View {
        switch catalog.knows(draft.device.trimmingCharacters(in: .whitespaces)) {
        case .some(true):
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                .help("Found in minipro's database")
        case .some(false):
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                .help("Not in minipro's database. Pick a name from the search list below.")
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var resultsList: some View {
        switch catalog.state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading device list…").foregroundColor(.secondary).font(.caption)
            }
            .frame(height: 180)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't load the device list.").foregroundColor(.orange)
                Text(message).font(.caption).foregroundColor(.secondary).lineLimit(4)
                Button("Retry") { catalog.load() }
            }
            .frame(height: 180, alignment: .topLeading)
        case .idle, .loaded:
            let results = catalog.search(query)
            List(results, id: \.self) { name in
                HStack {
                    Text(name).font(.system(.body, design: .monospaced))
                    Spacer()
                    if name == draft.device {
                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    draft.device = name
                    if draft.name == "New Preset" || draft.name.isEmpty {
                        draft.name = Self.friendlyName(for: name)
                    }
                }
            }
            .frame(height: 180)
            .overlay(
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Type part of a chip name").foregroundColor(.secondary)
                    } else if results.isEmpty {
                        Text("No matches").foregroundColor(.secondary)
                    }
                }
            )
        }
    }

    // "SST39SF040@PLCC32" -> "SST39SF040 (PLCC32)"
    static func friendlyName(for device: String) -> String {
        let parts = device.components(separatedBy: "@")
        guard parts.count == 2 else { return device }
        return "\(parts[0]) (\(parts[1]))"
    }
}
