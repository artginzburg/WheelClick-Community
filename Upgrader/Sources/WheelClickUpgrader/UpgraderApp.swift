import SwiftUI
import UpgraderKit

@main struct UpgraderApp: App {
    @StateObject private var flow = UpgradeFlow()

    var body: some Scene {
        WindowGroup("WheelClick Upgrader") {
            ContentView(flow: flow)
        }
        .windowResizability(.contentSize)
    }
}
