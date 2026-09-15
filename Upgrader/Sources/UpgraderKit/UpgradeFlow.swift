import SwiftUI

@MainActor public final class UpgradeFlow: ObservableObject {
    public enum Phase: Equatable {
        case needsEmail, working(String), done, alreadyDirect, missing
        case failed(message: String, key: String?)
        case canceled(key: String)
        case noPurchase
    }
    @Published public var phase: Phase
    @Published public var email = ""
    private var receipt = Data()

    public init() {
        phase = .missing
        readInstall()
    }

    /// Re-reads the receipt from disk (it changes once WheelClick syncs a purchase); keeps the email.
    public func readInstall() {
        switch findInstall() {
        case .appStore(let data): receipt = data; phase = .needsEmail
        case .direct: phase = .alreadyDirect
        case .missing: phase = .missing
        }
    }

    public func start() {
        Task {
            var key: String?
            do {
                phase = .working("Checking your purchase…")
                let checkout = try await requestCheckout(receipt: receipt, email: email.trimmingCharacters(in: .whitespacesAndNewlines))
                phase = .working("Issuing your license…")
                let issued = try await waitForKey(checkoutID: checkout)
                key = issued
                await install(key: issued)
            } catch CrossgradeError.server("no_purchase") {
                phase = .noPurchase
            } catch CrossgradeError.server(let code) {
                phase = .failed(message: Self.message(for: code), key: key)
            } catch {
                phase = .failed(message: "Couldn't reach wheelclick.app. Check your connection and try again.", key: nil)
            }
        }
    }

    /// Download, replace and activate with a key already issued; never calls the server again.
    public func retryInstall(key: String) {
        Task { await install(key: key) }
    }

    private func install(key: String) async {
        do {
            phase = .working("Downloading WheelClick…")
            let fresh = try await downloadVerifiedApp()
            phase = .working("Installing. macOS will ask for your password…")
            try replaceInstalledApp(with: fresh)
            activate(key: key)
            phase = .done
        } catch CrossgradeError.canceled {
            phase = .canceled(key: key)
        } catch CrossgradeError.stagedOnly {
            phase = .failed(message: "Your license is ready, but the new WheelClick couldn't be moved into place. It is at /Applications/.WheelClick.app.new: rename it to WheelClick.app, then press Activate.", key: key)
        } catch {
            phase = .failed(message: "Your license is ready, but the installation didn't finish. Download WheelClick from wheelclick.app, then press Activate.", key: key)
        }
    }

    static let noPurchaseMessage = "This copy of WheelClick has no purchase of the full version. If you bought it, open WheelClick once so the purchase syncs, then try again."

    static func message(for code: String) -> String {
        switch code {
        case "receipt_already_used": "This purchase has already been moved to a license under another email. Write to support@wheelclick.app if that wasn't you."
        case "no_purchase": noPurchaseMessage
        case "invalid_email": "Please check the email address."
        case "invalid_receipt": "This copy's App Store receipt couldn't be verified. Write to support@wheelclick.app."
        default: "The license couldn't be issued just now. Please try again in a minute."
        }
    }
}
