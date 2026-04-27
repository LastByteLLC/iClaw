import SwiftUI
import TipKit
import iClawCore

@main
struct iClawMobileApp: App {
    init() {
        try? Tips.configure([
            .displayFrequency(.daily),
            .datastoreLocation(.applicationDefault)
        ])
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}
