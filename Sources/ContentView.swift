import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: PresetStore
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var runner: MiniproRunner
    @EnvironmentObject private var catalog: DeviceCatalog

    @AppStorage("selectedPresetID") private var savedSelection = ""
    @State private var selection: UUID?
    @State private var editing: Preset?
    @State private var editingIsNew = false
    @State private var pendingDelete: Preset?
    @State private var checkedAtLaunch = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 960, minHeight: 700)
        .sheet(item: $editing) { preset in
            PresetEditor(preset: preset, isNew: editingIsNew) { saved in
                if let i = store.index(of: saved.id) {
                    store.presets[i] = saved
                } else {
                    store.presets.append(saved)
                }
                session.presetEdited(saved)
                selection = saved.id
            }
            .environmentObject(catalog)
        }
        .alert(item: $pendingDelete) { preset in
            Alert(title: Text("Delete “\(preset.name)”?"),
                  primaryButton: .destructive(Text("Delete")) { delete(preset) },
                  secondaryButton: .cancel())
        }
        .onAppear {
            if let id = UUID(uuidString: savedSelection), store.index(of: id) != nil {
                selection = id
            } else {
                selection = store.presets.first?.id
            }
            if !catalog.isLoaded { catalog.load() }
            // Check the programmer once at launch, so the header shows the model and firmware right away.
            // Wait a moment so the selected preset has loaded its files first
            // (that's skipped while minipro is busy).
            if !checkedAtLaunch {
                checkedAtLaunch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    session.runSingle(.programmer, preset: nil, extra: ["--version"], quiet: true)
                }
            }
        }
        .onChange(of: selection) { newValue in
            savedSelection = newValue?.uuidString ?? ""
            // Look the preset up in the store: on macOS 12/13 an onChange closure
            // still sees the previous view state, so the old preset would be used.
            if let i = store.index(of: newValue) {
                session.presetSelected(store.presets[i])
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            BrandHeader()
            List(selection: $selection) {
                Section(header: Text("Presets")) {
                    ForEach(store.presets) { preset in
                        PresetRow(preset: preset, known: catalog.knows(preset.device))
                            .tag(preset.id)
                            .contextMenu {
                                Button("Edit…") { beginEdit(preset) }
                                Button("Duplicate") { duplicate(preset) }
                                Divider()
                                Button("Delete…") { pendingDelete = preset }
                            }
                    }
                    .onMove { from, to in
                        store.presets.move(fromOffsets: from, toOffset: to)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 4) {
                Button { beginNew() } label: { Image(systemName: "plus") }
                    .help("New preset")
                Button {
                    if let p = selectedPreset { pendingDelete = p }
                } label: { Image(systemName: "minus") }
                    .help("Delete preset")
                    .disabled(selectedPreset == nil)
                Button {
                    if let p = selectedPreset { beginEdit(p) }
                } label: { Image(systemName: "pencil") }
                    .help("Edit preset")
                    .disabled(selectedPreset == nil)
                Spacer()
                catalogStatus
            }
            .buttonStyle(.borderless)
            .padding(8)
            .disabled(session.isBusy)
        }
    }

    @ViewBuilder private var catalogStatus: some View {
        switch catalog.state {
        case .loading:
            ProgressView().controlSize(.small).help("Loading minipro device list…")
        case .failed(let msg):
            Button { catalog.load() } label: {
                Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
            }
            .help("Could not load the device list: \(msg)\nClick to retry.")
        case .loaded:
            Text("\(catalog.names.count) devices").font(.caption2).foregroundColor(.secondary)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let id = selection, store.index(of: id) != nil {
            DetailPane(preset: presetBinding(id), onEdit: { if let p = selectedPreset { beginEdit(p) } },
                       onUseDevice: useDevice)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "memorychip").font(.system(size: 40)).foregroundColor(.secondary)
                Text("Pick a preset on the left").foregroundColor(.secondary)
            }
        }
    }

    private var selectedPreset: Preset? {
        guard let i = store.index(of: selection) else { return nil }
        return store.presets[i]
    }

    // Index-safe binding: deleting a preset while the pane is on screen must not crash.
    private func presetBinding(_ id: UUID) -> Binding<Preset> {
        Binding(
            get: {
                if let i = store.index(of: id) { return store.presets[i] }
                return Preset(name: "", device: "")
            },
            set: { newValue in
                if let i = store.index(of: id) { store.presets[i] = newValue }
            }
        )
    }

    // MARK: Preset actions

    private func beginNew() {
        editingIsNew = true
        editing = Preset(name: "New Preset", device: "")
    }

    private func beginEdit(_ preset: Preset) {
        editingIsNew = false
        editing = preset
    }

    private func duplicate(_ preset: Preset) {
        var copy = preset
        copy.id = UUID()
        copy.name += " copy"
        if let i = store.index(of: preset.id) {
            store.presets.insert(copy, at: i + 1)
        } else {
            store.presets.append(copy)
        }
        selection = copy.id
    }

    private func delete(_ preset: Preset) {
        guard let i = store.index(of: preset.id) else { return }
        store.presets.remove(at: i)
        if selection == preset.id {
            selection = store.presets.indices.contains(i) ? store.presets[i].id : store.presets.last?.id
        }
    }

    // After an ID mismatch: jump to a preset for the chip that's really in the socket, or make one.
    private func useDevice(_ device: String) {
        session.identified = nil
        session.outcome = nil
        // minipro names the bare part; keep the package of the preset we came from (e.g. @PLCC32).
        var wanted: [String] = [device]
        if let cur = selectedPreset?.device, let at = cur.firstIndex(of: "@"), !device.contains("@") {
            wanted.insert(device + String(cur[at...]), at: 0)
        }
        for w in wanted {
            if let p = store.presets.first(where: { $0.device.caseInsensitiveCompare(w) == .orderedSame }) {
                selection = p.id
                return
            }
        }
        if let p = store.presets.first(where: { $0.device.caseInsensitiveCompare(device) == .orderedSame }) {
            selection = p.id
            return
        }
        let p = Preset(name: PresetEditor.friendlyName(for: device), device: device)
        store.presets.append(p)
        selection = p.id
    }
}

// Kero's hand sign and the app name at the top of the sidebar.
struct BrandHeader: View {
    private static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true   // follows light/dark mode
        return img
    }()

    var body: some View {
        HStack(spacing: 10) {
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 40)
                    .foregroundColor(.primary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: AppInfo.name).font(.title3).bold()
                Text(verbatim: "Kero's Mac Mods").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

struct PresetRow: View {
    let preset: Preset
    let known: Bool?

    private var deviceLabel: String {
        if preset.device.isEmpty { return "(no device)" }
        return preset.device
    }

    var body: some View {
        HStack(spacing: 6) {
            if !preset.icon.isEmpty {
                Text(verbatim: preset.icon)
                    .font(.system(size: 20))
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).lineLimit(1)
                Text(verbatim: deviceLabel)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if known == false {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help("This device name isn't in minipro's database")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail pane

struct DetailPane: View {
    @Binding var preset: Preset
    let onEdit: () -> Void
    var onUseDevice: (String) -> Void = { _ in }

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var runner: MiniproRunner
    @EnvironmentObject private var catalog: DeviceCatalog

    @State private var dropTargeted = false
    @State private var showHex = false
    @State private var showTools = false
    @State private var showLogic = false
    @State private var showFirmware = false
    @State private var readOnOpen = false
    @State private var placementTarget: UUID?

    init(preset: Binding<Preset>, onEdit: @escaping () -> Void, onUseDevice: @escaping (String) -> Void = { _ in }) {
        _preset = preset
        self.onEdit = onEdit
        self.onUseDevice = onUseDevice
    }

    private var busy: Bool { session.isBusy }

    private var deviceLabel: String {
        if preset.device.isEmpty { return "(no device set)" }
        return preset.device
    }

    private var queueHint: String {
        if session.files.count > 1 { return "— written in this order, one chip each" }
        return ""
    }

    private var writeTitle: String {
        let n = session.files.count
        if n > 1 { return "Write " + String(n) + " Chips" }
        return "Write"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            filesBox
            optionsRow
            if let next = session.waitingIndex, session.files.indices.contains(next) {
                swapBanner(next)
            }
            actionRow
            statusRow
            logBox
        }
        .padding(18)
        .onAppear { session.presetSelected(preset) }
        .sheet(isPresented: $showHex) {
            HexViewer(preset: preset, initialFile: session.files.first?.url,
                      initialPlacement: session.files.first?.placement, readOnOpen: readOnOpen)
                .environmentObject(session)
                .environmentObject(runner)
        }
        .sheet(isPresented: $showFirmware) {
            FirmwareUpdateView()
                .environmentObject(session)
                .environmentObject(runner)
        }
        .sheet(isPresented: $showLogic) {
            LogicTestView()
                .environmentObject(session)
                .environmentObject(runner)
        }
        .sheet(isPresented: $showTools) {
            RomTools(preset: preset, presetSize: preset.isLogicDevice ? nil : catalog.size(of: preset.device))
                .environmentObject(session)
                .environmentObject(runner)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).font(.title2).bold()
                HStack(spacing: 8) {
                    Text(verbatim: deviceLabel)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    deviceBadge
                }
                if !preset.note.isEmpty {
                    Text(preset.note).foregroundColor(.secondary).font(.callout)
                }
                hardwareLine
            }
            Spacer()
            Button("Logic Test…") { showLogic = true }
                .disabled(busy)
                .help("Test a 74 / 4000 series logic chip")
            Button("Check Programmer") {
                // --version opens the programmer and prints "Found T48 00.1.39 (0x127)", which -k leaves out.
                session.runSingle(.programmer, preset: nil, extra: ["--version"])
            }
            .disabled(busy)
            Button("Edit Preset…", action: onEdit)
                .disabled(busy)
        }
    }

    // Programmer and confirmed chip ID, so they show up in screenshots people post when asking for help.
    private var programmerText: String {
        if runner.programmerMissing { return "No programmer found" }
        guard let model = runner.programmerModel else { return "Programmer not checked yet" }
        if let fw = runner.programmerFirmware { return model + "  ·  firmware " + fw }
        return model
    }

    private var programmerColor: Color {
        if runner.programmerMissing { return .red }
        if runner.programmerModel != nil { return .green }
        return .secondary
    }

    private var hardwareLine: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(programmerColor)
                Text(verbatim: programmerText)
            }
            // Low-key on purpose: most people never need to update.
            Button { showFirmware = true } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .help("Programmer firmware")
            if let cid = runner.lastChipID, cid.device == preset.device {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(verbatim: "Chip ID " + cid.id)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .padding(.top, 2)
    }

    @ViewBuilder private var deviceBadge: some View {
        switch catalog.knows(preset.device) {
        case .some(true):
            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                .help("Found in minipro's database")
        case .some(false):
            Label("Not in minipro's database — fix it in Edit Preset", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.callout)
        case .none:
            EmptyView()
        }
    }

    // MARK: Files

    private var filesBox: some View {
        GroupBox(label: HStack {
            Text("Files")
            Text(verbatim: queueHint)
                .foregroundColor(.secondary)
                .font(.caption)
            Spacer()
            if !preset.files.isEmpty && session.loadedFrom == preset.id {
                Label("From preset", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button("Save to Preset") {
                preset.files = session.savedFiles
                session.markSaved(to: preset)
            }
            .disabled(busy || session.files.isEmpty || session.loadedFrom == preset.id)
            .help("Remember these files (and their offsets) so this preset loads them by itself")
            Button("Add…", action: openFiles)
            Button("Split / Join…") { showTools = true }
                .disabled(busy)
                .help("Split a ROM into a file per chip for 16-bit or 32-bit boards, or join parts back into one ROM")
            Button("Sort by Name") { session.sortByName() }
                .disabled(busy || session.files.count < 2)
            Button("Clear") { session.clearFiles() }
                .disabled(busy || session.files.isEmpty)
        }) {
            ZStack {
                if session.files.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 28)).foregroundColor(.secondary)
                        Text("Drop .\(preset.fileExtension) files here")
                            .foregroundColor(.secondary)
                        Text("Drop a HI/LO pair or a 4-file SIMM set to write them one after another.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(session.files.enumerated()), id: \.element.id) { index, file in
                                fileRow(index: index, file: file)
                                if index < session.files.count - 1 { Divider() }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 110, maxHeight: 190)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(dropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        }
    }

    private func fileRow(index: Int, file: QueuedFile) -> some View {
        let highlighted = session.waitingIndex == index || session.activeIndex == index
        return HStack(spacing: 10) {
            statusIcon(file.status)
                .frame(width: 18)
            Text("#\(index + 1)")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
                fileDetail(file)
            }
            Spacer()
            if !preset.isLogicDevice {
                offsetButton(file)
                    .controlSize(.small)
                    .disabled(busy)
                    .help("Write this file at an address instead of from 0")
                    .popover(isPresented: placementBinding(file.id), arrowEdge: .bottom) {
                        PlacementEditor(fileName: file.name, fileSize: file.size,
                                        placement: file.placement ?? Placement()) { p in
                            session.setPlacement(file.id, p)
                            placementTarget = nil
                        }
                    }
            }
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .binary))
                .font(.caption)
                .foregroundColor(.secondary)
            Group {
                Button { session.move(file.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { session.move(file.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == session.files.count - 1)
                Button { session.remove(file.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(busy)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(highlighted ? Color.accentColor.opacity(0.15) : Color.clear)
        .contextMenu {
            Button("Write from Here") { session.startBatch(.write, preset: preset, from: index) }
                .disabled(busy || preset.device.isEmpty)
            Button("Verify from Here") { session.startBatch(.verify, preset: preset, from: index) }
                .disabled(busy || preset.device.isEmpty)
        }
    }

    @ViewBuilder private func fileDetail(_ file: QueuedFile) -> some View {
        if !file.exists {
            Label("Not found, moved or renamed?", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        } else {
            HStack(spacing: 8) {
                if let d = file.modified {
                    Text(verbatim: "Modified " + Self.dateText.string(from: d))
                }
                if let p = file.placement {
                    Text(verbatim: p.summary).foregroundColor(.accentColor)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private static let dateText: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // A real button, filled in once an offset is set, so it reads as clickable.
    @ViewBuilder private func offsetButton(_ file: QueuedFile) -> some View {
        if file.placement != nil {
            Button { placementTarget = file.id } label: {
                Label("Offset", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { placementTarget = file.id } label: {
                Label("Offset…", systemImage: "arrow.right.to.line")
            }
            .buttonStyle(.bordered)
        }
    }

    private func placementBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { placementTarget == id },
                set: { if !$0 { placementTarget = nil } })
    }

    @ViewBuilder private func statusIcon(_ status: QueuedFile.Status) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundColor(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
        case .skipped: Image(systemName: "forward.fill").foregroundColor(.secondary)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !busy else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { session.addFiles([url]) }
            }
        }
        return true
    }

    private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose files to write"
        if panel.runModal() == .OK {
            session.addFiles(panel.urls)
        }
    }

    // MARK: Options

    private var optionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Toggle("Allow size mismatch (-s)", isOn: $preset.skipSizeCheck)
                Toggle("Ignore ID check (-y)", isOn: $preset.ignoreIDError)
                Toggle("Skip verify after write (-v)", isOn: $preset.noVerify)
                Spacer()
            }
            HStack(spacing: 18) {
                Toggle("Unprotect before write (-u)", isOn: $preset.unprotect)
                Toggle("Protect after write (-P)", isOn: $preset.protectAfter)
                Toggle("Ignore pin check", isOn: $preset.skipPinCheck)
                    .help("When off, the pin contact test (-z) runs before every write and stops on a bad contact.")
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .disabled(busy)
    }

    // MARK: Chip swap

    @ViewBuilder private func swapBanner(_ next: Int) -> some View {
        if session.retryIndex == next {
            retryBanner(next)
        } else {
            nextChipBanner(next)
        }
    }

    // A chip in the middle of a multi-chip run failed. Retry just that one.
    private func retryBanner(_ index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(index + 1) failed: reseat or replace that chip").bold()
                Text(session.retryMessage ?? session.files[index].name)
                    .font(.callout)
                    .lineLimit(2)
                Text(index > 0 ? "The chips before it are done. Retry carries on from here." : "Retry carries on from here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Stop") { session.stopBatch() }
            Button("Skip") { session.skipNext() }
            Button("Retry") { session.continueBatch() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(Color.red.opacity(0.15))
        .cornerRadius(8)
    }

    private func nextChipBanner(_ next: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Swap the chip").bold()
                Text("Next: #\(next + 1)  \(session.files[next].name)")
                    .font(.callout)
            }
            Spacer()
            Button("Stop") { session.stopBatch() }
            Button("Skip") { session.skipNext() }
            Button("Continue") { session.continueBatch() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.22))
        .cornerRadius(8)
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                session.startBatch(.write, preset: preset)
            } label: {
                Label(writeTitle, systemImage: "square.and.arrow.down")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(busy || session.files.isEmpty || preset.device.isEmpty)
            .help("⌘↩")

            Button("Verify") { session.startBatch(.verify, preset: preset) }
                .controlSize(.large)
                .disabled(busy || session.files.isEmpty || preset.device.isEmpty)

            Divider().frame(height: 22)

            Group {
                Button("Hex View…") { readOnOpen = false; showHex = true }
                    .help("Look at a file, read the chip and compare them byte by byte")
                Button("Read…") {
                    // PLDs come back as JEDEC text, so those still go straight to a file.
                    if preset.isLogicDevice {
                        session.read(preset: preset)
                    } else {
                        readOnOpen = true
                        showHex = true
                    }
                }
                .help("Read the chip and look at it. Save it from there if you want to keep it.")
                Button("Blank Check") { session.runSingle(.blank, preset: preset, extra: ["-b"]) }
                Button("Erase") { session.runSingle(.erase, preset: preset, extra: ["-E"]) }
                Button("Chip ID") { session.runSingle(.chipID, preset: preset, extra: ["-D"]) }
                Button("Pin Check") { session.runSingle(.pinCheck, preset: preset, extra: ["-z"]) }
            }
            .disabled(busy || preset.device.isEmpty)

            Spacer()

            if runner.isRunning || session.waitingIndex != nil {
                Button(role: .destructive) { session.stopBatch() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 10) {
            if runner.isRunning {
                RunStatusBar()
            } else if let outcome = session.outcome {
                switch outcome {
                case .success(let msg):
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.title3.bold())
                        .foregroundColor(.green)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.octagon.fill")
                        .font(.title3.bold())
                        .foregroundColor(.red)
                    if let real = session.identified {
                        Button("Use " + real) { onUseDevice(real) }
                            .help("Switch to a preset for this chip, or make one")
                    }
                }
            } else {
                Text(" ").font(.title3)
            }
            Spacer()
        }
        .frame(minHeight: 28)
    }

    // MARK: Log

    private var logBox: some View {
        GroupBox(label: HStack {
            Text("Log")
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(runner.plainText, forType: .string)
            }
            Button("Clear") { runner.clear() }
                .disabled(runner.isRunning)
            Button("Show Log Files") {
                try? FileManager.default.createDirectory(at: ActivityLog.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(ActivityLog.directory)
            }
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(runner.lines) { line in
                            Text(line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(color(for: line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: runner.lines.count) { _ in
                    if let last = runner.lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .command: return .accentColor
        case .output: return .primary
        case .info: return .secondary
        case .success: return .green
        case .error: return .red
        }
    }
}

// Step name, a bar (real percentage when minipro reports one, moving otherwise) and elapsed time.
struct RunStatusBar: View {
    @EnvironmentObject private var runner: MiniproRunner

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: runner.phase ?? "Working")
                .font(.headline)
                .frame(width: 120, alignment: .leading)
            if let p = runner.progress {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text(verbatim: String(Int(p * 100)) + "%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 240)
                Text(verbatim: "")
                    .frame(width: 48)
            }
            TimelineView(.periodic(from: runner.phaseStart, by: 0.1)) { context in
                Text(verbatim: Self.elapsed(since: runner.phaseStart, now: context.date))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            Text(verbatim: runner.liveLine)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let t = max(0, now.timeIntervalSince(start))
        return String(format: "%.1fs", t)
    }
}
