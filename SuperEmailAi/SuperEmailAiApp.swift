import SwiftUI

@main
struct SuperEmailAiApp: App {
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
