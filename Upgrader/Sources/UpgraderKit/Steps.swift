import AppKit
import Security

public enum Install { case appStore(receipt: Data), direct, missing }
public enum CrossgradeError: Error, Equatable { case server(code: String), network, badDownload, signature(String), replace(String), canceled, stagedOnly }

private let api = URL(string: "https://wheelclick.app/api/v1/")!
private let dmgURL = URL(string: "https://github.com/artginzburg/WheelClick-Community/releases/latest/download/WheelClick.dmg")!
public let installedApp = URL(fileURLWithPath: "/Applications/WheelClick.app")

public func findInstall(at app: URL = installedApp) -> Install {
    guard FileManager.default.fileExists(atPath: app.path) else { return .missing }
    if let receipt = try? Data(contentsOf: app.appendingPathComponent("Contents/_MASReceipt/receipt")) { return .appStore(receipt: receipt) }
    return .direct
}

/// Retries `in_progress` (409: the same purchase is being issued right now) a few times.
public func requestCheckout(receipt: Data, email: String, session: URLSession = .shared, attempts: Int = 5, retryDelay: UInt64 = 3_000_000_000) async throws -> String {
    var request = URLRequest(url: api.appendingPathComponent("crossgrade"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["receipt": receipt.base64EncodedString(), "email": email, "source": "upgrader"])
    for attempt in 1...attempts {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw CrossgradeError.network }
        guard let http = response as? HTTPURLResponse else { throw CrossgradeError.network }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode == 200, let id = body["checkout_id"] as? String { return id }
        let code = body["error"] as? String ?? "issue_failed"
        if code == "in_progress", attempt < attempts {
            try await Task.sleep(nanoseconds: retryDelay)
            continue
        }
        throw CrossgradeError.server(code: code)
    }
    throw CrossgradeError.server(code: "in_progress")
}

/// checkout-key answers 202 while Polar grants the license (seconds); give it a minute.
public func waitForKey(checkoutID: String, session: URLSession = .shared, pollInterval: UInt64 = 2_000_000_000) async throws -> String {
    var components = URLComponents(url: api.appendingPathComponent("checkout-key"), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "checkout_id", value: checkoutID)]
    for _ in 0..<30 {
        if let (data, response) = try? await session.data(from: components.url!),
           let status = (response as? HTTPURLResponse)?.statusCode {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 200, let key = body?["key"] as? String { return key }
            // A 4xx will not change by asking again.
            if (400..<500).contains(status) { throw CrossgradeError.server(code: body?["error"] as? String ?? "issue_failed") }
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
    throw CrossgradeError.network
}

public func downloadVerifiedApp() async throws -> URL {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("WheelClickUpgrader-\(UUID().uuidString)")
    let mount = work.appendingPathComponent("mnt")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let downloaded: URL
    do { (downloaded, _) = try await URLSession.shared.download(from: dmgURL) } catch { throw CrossgradeError.network }
    // The system may reclaim the temporary download; keep our own copy.
    let dmg = work.appendingPathComponent("WheelClick.dmg")
    try FileManager.default.moveItem(at: downloaded, to: dmg)
    try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
    defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
    let copy = work.appendingPathComponent("WheelClick.app")
    try FileManager.default.copyItem(at: mount.appendingPathComponent("WheelClick.app"), to: copy)
    try verifySignature(of: copy)
    return copy
}

public func verifySignature(of app: URL, team: String = "R2294BC6J8") throws {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw CrossgradeError.signature("unreadable") }
    // Anchored at Apple's Developer ID CA, with our team as the leaf's OU.
    let requirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
    var req: SecRequirement?
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req,
          SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    else { throw CrossgradeError.signature("not a Developer ID build of team \(team)") }
}

/// Single-quotes a string for /bin/sh.
func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Escapes a string for use inside an AppleScript string literal.
func appleScriptQuoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// The privileged shell script: WheelClick is killed only once the password is accepted (SIGKILL,
/// because it can hang on SIGTERM), and the old bundle is removed only after the new one is fully
/// in place next to it.
/// `do shell script` reports the shell exit status as the AppleScript error number.
let stagedOnlyExitCode = 3

func privilegedScript(fresh: URL, target: URL, user: String) -> String {
    let t = shellQuoted(target.path)
    let staged = shellQuoted(target.deletingLastPathComponent().appendingPathComponent(".WheelClick.app.new").path)
    return [
        "/usr/bin/pkill -9 -x WheelClick || true",
        "rm -rf \(staged)",
        "{ /usr/bin/ditto \(shellQuoted(fresh.path)) \(staged) && /usr/sbin/chown -R \(shellQuoted(user)):staff \(staged); } || { rm -rf \(staged); exit 1; }",
        "rm -rf \(t) || { rm -rf \(staged); exit 1; }",
        // Past this point the new copy is the only one left: never delete it.
        "mv \(staged) \(t) || exit \(stagedOnlyExitCode)",
    ].joined(separator: "; ")
}

/// Measured 2026-09-15: FileManager and NSWorkspace fail on a root-owned App Store bundle without
/// ever prompting; an administrator `do shell script` prompts once and succeeds.
@MainActor public func replaceInstalledApp(with fresh: URL, at target: URL = installedApp) throws {
    // Checked again right before the prompt, to narrow the window for swapping the temp copy.
    try verifySignature(of: fresh)
    let shell = privilegedScript(fresh: fresh, target: target, user: NSUserName())
    let prompt = "WheelClick Upgrader wants to replace the App Store copy of WheelClick with the direct version."
    let source = "do shell script \(appleScriptQuoted(shell)) with administrator privileges with prompt \(appleScriptQuoted(prompt))"
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { throw CrossgradeError.replace("script") }
    script.executeAndReturnError(&error)
    if let error {
        let number = error[NSAppleScript.errorNumber] as? Int
        if number == -128 { throw CrossgradeError.canceled }
        if number == stagedOnlyExitCode { throw CrossgradeError.stagedOnly }
        throw CrossgradeError.replace((error[NSAppleScript.errorMessage] as? String) ?? "failed")
    }
    try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent())
}

public func activate(key: String) {
    var components = URLComponents(string: "wheelclick://activate")!
    components.queryItems = [URLQueryItem(name: "key", value: key)]
    NSWorkspace.shared.open(components.url!)
}

/// What a successful run should offer to clean up: the running app bundle itself, and any
/// `WheelClick-Upgrader*.zip` sitting in Downloads (the browser may have numbered it, e.g.
/// `WheelClick-Upgrader-2.zip`). Only these two locations are ever touched.
public func cleanupTargets(bundle: URL, downloads: URL, fileManager: FileManager = .default) -> [URL] {
    var targets = [bundle]
    let entries = (try? fileManager.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
    for entry in entries {
        let name = entry.lastPathComponent
        if name.hasPrefix("WheelClick-Upgrader") && name.hasSuffix(".zip") {
            targets.append(entry)
        }
    }
    return targets
}

/// Moves each URL to the Trash, returning the ones that failed (access refused, already gone, etc.).
/// `NSWorkspace.recycle`'s completion handler is delivered on the main thread, so this awaits it
/// with a continuation rather than blocking that thread on a semaphore, which would deadlock any
/// caller running on the main actor (the only caller there is).
public func moveToTrash(_ urls: [URL]) async -> [URL] {
    guard !urls.isEmpty else { return [] }
    return await withCheckedContinuation { continuation in
        NSWorkspace.shared.recycle(urls) { newURLs, error in
            let failed = (error != nil) ? urls : urls.filter { newURLs[$0] == nil }
            continuation.resume(returning: failed)
        }
    }
}

private func run(_ tool: String, _ args: [String]) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw CrossgradeError.badDownload }
}
