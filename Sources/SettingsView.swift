import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var store: PresetStore
    @EnvironmentObject private var catalog: DeviceCatalog

    @AppStorage(MiniproLocator.customPathKey) private var customPath = ""
    @State private var confirmReset = false

    private var resolvedPath: String {
        MiniproLocator.resolve()?.path ?? "not found"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("minipro").font(.headline)
            HStack {
                TextField("Leave empty to use the copy inside the app", text: $customPath)
                Button("Choose…", action: chooseBinary)
            }
            Text(verbatim: "In use: " + resolvedPath)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            Button("Reload Device List") { catalog.load() }

            Divider()

            Text("Presets").font(.headline)
            Text("Presets are saved as JSON. You can edit the file by hand and reload it here.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Show presets.json") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                }
                Button("Reload from File") { store.load() }
                Spacer()
                Button("Restore Defaults…") { confirmReset = true }
            }
        }
        .padding(20)
        .frame(width: 540)
        .alert("Replace all presets with the defaults?", isPresented: $confirmReset) {
            Button("Restore", role: .destructive) { store.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your own presets will be removed.")
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose the minipro executable"
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            catalog.load()
        }
    }
}
