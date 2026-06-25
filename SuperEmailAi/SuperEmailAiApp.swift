import SwiftUI
import AppKit

@main
struct SuperEmailAiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mailManager = MailManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mailManager)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)
    }
}

/// When run as a bare Swift Package executable (no `.app` bundle), macOS treats
/// the process as an accessory: the window opens behind others and can't take
/// keyboard focus. Forcing a regular activation policy and activating on launch
/// makes it behave like a normal foreground app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
