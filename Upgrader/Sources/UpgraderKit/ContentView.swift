import AppKit
import SwiftUI

public struct ContentView: View {
    @ObservedObject var flow: UpgradeFlow
    private let site = URL(string: "https://wheelclick.app")!

    public init(flow: UpgradeFlow) { self.flow = flow }

    public var body: some View {
        Group {
            switch flow.phase {
            case .needsEmail:
                VStack(spacing: 14) {
                    Text("Move your App Store copy of WheelClick to the direct version, free. Your license key goes to this email.")
                        .multilineTextAlignment(.center)
                    TextField("Email", text: $flow.email)
                        .textFieldStyle(.roundedBorder)
                    Button("Move to the direct version") { flow.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!flow.email.contains("@"))
                }
            case .working(let text):
                VStack(spacing: 14) {
                    ProgressView()
                    Text(text)
                }
            case .done:
                VStack(spacing: 14) {
                    Text("Done. WheelClick is activated.")
                    Button("Quit") { NSApp.terminate(nil) }
                }
            case .alreadyDirect:
                Text("You already have the direct version.")
            case .missing:
                VStack(spacing: 14) {
                    Text("WheelClick isn't in Applications.")
                    Link("wheelclick.app", destination: site)
                }
            case .canceled(let key):
                VStack(spacing: 14) {
                    Text("Installation was canceled. Your license is ready.")
                    HStack {
                        Button("Try again") { flow.retryInstall(key: key) }.keyboardShortcut(.defaultAction)
                        Button("Activate") { activate(key: key) }
                    }
                    Link("wheelclick.app", destination: site)
                }
            case .noPurchase:
                VStack(spacing: 14) {
                    Text(UpgradeFlow.noPurchaseMessage).multilineTextAlignment(.center)
                    Button("Try again") { flow.readInstall() }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message, let key):
                VStack(spacing: 14) {
                    Text(message).multilineTextAlignment(.center)
                    if let key { Button("Activate") { activate(key: key) } }
                    Link("wheelclick.app", destination: site)
                }
            }
        }
        .padding(24)
        .frame(width: 420, height: 260)
    }
}
