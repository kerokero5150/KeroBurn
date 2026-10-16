import SwiftUI
import AppKit

@main
struct KeroBurnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PresetStore()
    @StateObject private var session = Session()
    @StateObject private var catalog = DeviceCatalog()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environmentObject(store)
                .environmentObject(session)
                .environmentObject(session.runner)
                .environmentObject(catalog)
        }
        .commands {
            // One window is enough for a single programmer.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.name)") { AboutPanel.show() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(catalog)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Standard About panel with credits for minipro and the libraries bundled with it.
enum AboutPanel {
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let mpVersion = (info["MiniproVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"

        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 4

        let credits = NSMutableAttributedString()
        func add(_ text: String, font: NSFont = body, link: String? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: center,
            ]
            if let link = link, let url = URL(string: link) { attrs[.link] = url }
            credits.append(NSAttributedString(string: text, attributes: attrs))
        }

        add("A Mac front end for XGecu programmers (T48, T56, TL866II+, TL866A/CS).\n\n")
        add("Powered by minipro " + mpVersion + "\n", font: bold)
        add("by Valentin Dudouyt, David Griffith and contributors\n")
        add("gitlab.com/DavidGriffith/minipro", link: "https://gitlab.com/DavidGriffith/minipro")
        add("\nLicensed under the GNU GPL v3.\n\n")
        add("Also includes libusb (LGPL 2.1) and zlib.\n\n")
        add("KeroBurn is free software under the GNU GPL v3.\n")
        add("kerosmm.com", link: "https://www.kerosmm.com")

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Kay Koba, Kero's Mac Mods",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
