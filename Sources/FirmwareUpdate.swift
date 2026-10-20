import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Programmer firmware update through minipro -F <updateXXX.dat>.
// minipro asks "continue? y/n" after checking the file, so the same command
// answered with "n" is a safe dry run: it checks the file against the
// programmer and tells us both versions without touching anything.

struct FirmwareUpdateView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var runner: MiniproRunner
    @Environment(\.dismiss) private var dismiss

    enum Stage: Equatable {
        case idle
        case checking
        case checked(fileVersion: String, relation: String)   // relation: newer / older / same
        case updating
        case done
        case failed(String)
    }

    @State private var file: URL?
    @State private var stage: Stage = .idle
    @State private var targeted = false
    @State private var attempt = 0
    @State private var stalledForRetry = false
    @State private var stallSince: Date?
    @State private var watchdog: Timer?

    private var running: Bool { stage == .checking || stage == .updating }

    private var canUpdate: Bool {
        if case .checked = stage { return !session.isBusy }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Update Programmer Firmware").font(.title3).bold()
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(stage == .updating)
            }
            Divider()

            Text("The firmware comes with XGecu's Xgpro software for Windows: UpdateT48.dat for the T48, updateII.dat for the TL866II+, updateT56.dat for the T56. Download Xgpro from XGecu or from the XGecu_Software mirror on GitHub, open the .rar with The Unarchiver, then open the XgproVxxxx_Setup.exe inside it the same way. The .dat files are in there.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)
            HStack(spacing: 18) {
                Link("XGecu downloads", destination: URL(string: "http://www.xgecu.com/download.html")!)
                Link("XGecu_Software on GitHub", destination: URL(string: "https://github.com/Kreeblah/XGecu_Software")!)
            }

            fileBox
            programmerBox
            stageView

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Check File") { check() }
                    .disabled(file == nil || running || session.isBusy)
                Button {
                    confirmAndUpdate()
                } label: {
                    Label("Update Firmware", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUpdate)
                if running { ProgressView().controlSize(.small) }
                if stage == .updating, let p = runner.progress {
                    Text(verbatim: String(Int(p * 100)) + "%")
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 440)
        .interactiveDismissDisabled(stage == .updating)
    }

    // MARK: File

    private var fileBox: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            if let f = file {
                Text(verbatim: f.lastPathComponent).bold()
            } else {
                Text("Drop the update file here").foregroundColor(.secondary)
            }
            Spacer()
            Button("Choose File…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.title = "Choose the firmware update file (.dat)"
                if panel.runModal() == .OK, let url = panel.url { setFile(url) }
            }
            .disabled(running)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 3]))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard !running, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { setFile(url) }
            }
            return true
        }
    }

    private func setFile(_ url: URL) {
        file = url
        stage = .idle
        check()
    }

    private var programmerBox: some View {
        HStack(spacing: 6) {
            Text("Programmer:").foregroundColor(.secondary)
            if let model = runner.programmerModel {
                let fw = runner.programmerFirmware.map { ", firmware " + $0 } ?? ""
                Text(verbatim: model + fw).bold()
            } else if runner.programmerMissing {
                Text("not found. Check the USB cable.").foregroundColor(.red)
            } else {
                Text("not checked yet").foregroundColor(.secondary)
            }
        }
    }

    // MARK: Status

    @ViewBuilder private var stageView: some View {
        switch stage {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking the file against the programmer…").foregroundColor(.secondary)
        case .checked(let version, let relation):
            VStack(alignment: .leading, spacing: 6) {
                Label(["The file holds firmware ", version, " (", relationText(relation), ")."].joined(),
                      systemImage: "checkmark.circle.fill")
                    .foregroundColor(relation == "older" ? .orange : .green)
                Text("Before you update: take any chip out of the socket, and don't unplug the programmer or quit KeroBurn until it says it's done. It takes about a minute.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .updating:
            VStack(alignment: .leading, spacing: 6) {
                Label("Updating. Don't unplug the programmer.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                if !runner.liveLine.isEmpty {
                    Text(verbatim: runner.liveLine)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if attempt > 1 {
                    Text("Second try, starting from bootloader mode.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        case .done:
            Label("Firmware updated. The new version is shown above.", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If the programmer stopped responding during an update, it's waiting in bootloader mode. Run the update again with the same file and it picks up from there.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func relationText(_ r: String) -> String {
        switch r {
        case "newer": return "newer than the programmer's"
        case "older": return "older than the programmer's"
        default: return "same as the programmer's"
        }
    }

    // MARK: Actions

    // Dry run: answer "n" to minipro's prompt.
    private func check() {
        guard let f = file, !session.isBusy else { return }
        stage = .checking
        runner.run(["-F", f.path], input: "n\n") { _, output in
            stage = Self.parseCheck(output)
        }
    }

    // "updateT48.dat contains firmware version 00.1.39 (newer)"
    static func parseCheck(_ lines: [String]) -> Stage {
        for line in lines {
            guard let r = line.range(of: "contains firmware version ") else { continue }
            let rest = line[r.upperBound...]
            let version = rest.split(separator: " ").first.map(String.init) ?? "?"
            var relation = "same"
            if rest.contains("(newer)") { relation = "newer" }
            if rest.contains("(older)") { relation = "older" }
            return .checked(fileVersion: version, relation: relation)
        }
        let all = lines.joined(separator: "\n")
        if all.contains("No programmer found") {
            return .failed("No programmer found. Check the USB cable.")
        }
        if all.contains("version error") {
            return .failed("This file isn't for this programmer. Pick the update file that matches its model.")
        }
        if all.contains("size error") || all.contains("CRC error") {
            return .failed("This doesn't look like a valid firmware update file.")
        }
        let last = lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return .failed(last ?? "minipro couldn't read the file.")
    }

    private func confirmAndUpdate() {
        guard let f = file, case .checked(let version, let relation) = stage else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update the programmer to firmware " + version + "?"
        var info = "Don't unplug the programmer or quit KeroBurn until it's finished."
        if relation == "older" {
            info = "This file is OLDER than the firmware already on the programmer. " + info
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        attempt = 0
        startUpdate(f, version: version)
    }

    // On macOS, minipro can stall on the first block when it switches the T48 to
    // the bootloader and writes in the same run. A fresh run that starts in
    // bootloader mode goes through, so if the write doesn't move we stop it and
    // run once more.
    private func startUpdate(_ f: URL, version: String) {
        attempt += 1
        stalledForRetry = false
        stallSince = nil
        stage = .updating
        startWatchdog()
        runner.run(["-F", f.path], input: "y\n") { status, output in
            watchdog?.invalidate()
            watchdog = nil
            let ok = status == 0 && output.contains { $0.contains("Reflash... OK") }
            if ok {
                stage = .done
                Sounds.success()
                runner.append(.success, "Firmware updated to " + version)
                // Ask the programmer for its version so the header shows the new one.
                // Give it a moment to come back on USB after the reset.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if !runner.isRunning { runner.run(["--version"]) { _, _ in } }
                }
            } else if stalledForRetry && attempt < 2 {
                runner.append(.info, "The write stalled after switching to the bootloader. Starting again in bootloader mode.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    startUpdate(f, version: version)
                }
            } else {
                let last = output.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                stage = .failed("The update didn't finish: " + (last ?? "exit " + String(status)))
                Sounds.failure()
            }
        }
    }

    // Watch for "Reflashing..." that never gets to a percentage.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard runner.isRunning else { return }
            let stuck = runner.liveLine.contains("Reflashing") && runner.progress == nil
            if !stuck {
                stallSince = nil
                return
            }
            let since = stallSince ?? Date()
            stallSince = since
            if attempt < 2 && Date().timeIntervalSince(since) > 15 {
                stalledForRetry = true
                runner.cancel()
            }
        }
    }
}
