import XCTest
@testable import UpgraderKit

final class StepsTests: XCTestCase {
    private func makeBundle(receipt: Bool) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("WheelClick.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if receipt {
            let dir = app.appendingPathComponent("Contents/_MASReceipt")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: dir.appendingPathComponent("receipt"))
        }
        return app
    }

    func testAppStoreCopyYieldsItsReceipt() throws {
        guard case .appStore(let data) = findInstall(at: try makeBundle(receipt: true)) else { return XCTFail() }
        XCTAssertEqual(data, Data([1, 2, 3]))
    }
    func testDirectCopyHasNoReceipt() throws {
        guard case .direct = findInstall(at: try makeBundle(receipt: false)) else { return XCTFail() }
    }
    func testMissingApp() {
        guard case .missing = findInstall(at: URL(fileURLWithPath: "/nonexistent/WheelClick.app")) else { return XCTFail() }
    }
    func testSignatureCheckRejectsAnUnsignedBundle() throws {
        XCTAssertThrowsError(try verifySignature(of: try makeBundle(receipt: false)))
    }
    func testSignatureCheckRejectsAnotherTeam() {
        // Safari is Apple-signed: valid, but not Developer ID and not our team.
        XCTAssertThrowsError(try verifySignature(of: URL(fileURLWithPath: "/Applications/Safari.app")))
    }
    func testSignatureCheckAcceptsAnInstalledDirectBuild() throws {
        let app = URL(fileURLWithPath: "/Applications/WheelClick.app")
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["-dvv", app.path]
        let pipe = Pipe()
        check.standardError = pipe
        check.standardOutput = FileHandle.nullDevice
        try check.run(); check.waitUntilExit()
        let info = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard info.contains("Authority=Developer ID Application"), info.contains("TeamIdentifier=R2294BC6J8") else {
            throw XCTSkip("/Applications/WheelClick.app is not a Developer ID build of R2294BC6J8 on this Mac")
        }
        XCTAssertNoThrow(try verifySignature(of: app))
    }
}

final class PrivilegedScriptTests: XCTestCase {
    private let fresh = URL(fileURLWithPath: "/tmp/work dir/it's/WheelClick.app")
    private let target = URL(fileURLWithPath: "/Applications/WheelClick.app")

    private func index(_ needle: String, in s: String) -> String.Index {
        guard let r = s.range(of: needle) else { XCTFail("missing: \(needle)"); return s.endIndex }
        return r.lowerBound
    }

    func testCommandOrder() {
        let s = privilegedScript(fresh: fresh, target: target, user: "me")
        let kill = index("/usr/bin/pkill -9 -x WheelClick || true", in: s)
        let ditto = index("/usr/bin/ditto", in: s)
        let chown = index("/usr/sbin/chown -R 'me':staff '/Applications/.WheelClick.app.new'", in: s)
        let removeOld = index("rm -rf '/Applications/WheelClick.app' ||", in: s)
        let move = index("mv '/Applications/.WheelClick.app.new' '/Applications/WheelClick.app'", in: s)
        XCTAssertTrue(s.hasPrefix("/usr/bin/pkill"))
        XCTAssertLessThan(kill, ditto)
        XCTAssertLessThan(ditto, chown)
        XCTAssertLessThan(chown, removeOld)
        XCTAssertLessThan(removeOld, move)
        XCTAssertEqual(s.components(separatedBy: "rm -rf '/Applications/WheelClick.app'").count, 2, "the old bundle is removed exactly once")
        // Cleanup of the staged copy guards only the stages before the old bundle is gone.
        let cleanup = "{ rm -rf '/Applications/.WheelClick.app.new'; exit 1; }"
        let lastCleanup = s.range(of: cleanup, options: .backwards)!.lowerBound
        XCTAssertLessThan(lastCleanup, move)
        let afterRemoval = String(s[s.range(of: "rm -rf '/Applications/WheelClick.app' || " + cleanup)!.upperBound...])
        XCTAssertFalse(afterRemoval.contains("rm -rf"), "nothing is deleted once the old bundle is removed")
        XCTAssertTrue(afterRemoval.hasSuffix("mv '/Applications/.WheelClick.app.new' '/Applications/WheelClick.app' || exit \(stagedOnlyExitCode)"))
    }

    func testQuotingSurvivesSpacesAndQuotes() throws {
        let s = privilegedScript(fresh: fresh, target: target, user: "o'brien")
        XCTAssertTrue(s.contains(#"'/tmp/work dir/it'\''s/WheelClick.app'"#))
        // Run the ditto source argument through a real shell to prove it round-trips.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s \(shellQuoted(fresh.path))"]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), fresh.path)
        XCTAssertTrue(s.contains("'o'\\''brien':staff"))
    }

    func testAppleScriptQuoting() {
        XCTAssertEqual(appleScriptQuoted(#"a "b" \c"#), #""a \"b\" \\c""#)
    }
}

final class CleanupTargetsTests: XCTestCase {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws { try Data().write(to: url) }

    func testAlwaysIncludesTheBundleItself() throws {
        let downloads = try makeDir()
        let bundle = URL(fileURLWithPath: "/somewhere/else/WheelClick Upgrader.app")
        XCTAssertEqual(cleanupTargets(bundle: bundle, downloads: downloads), [bundle])
    }

    func testFindsAMatchingZipInDownloads() throws {
        let downloads = try makeDir()
        let zip = downloads.appendingPathComponent("WheelClick-Upgrader.zip")
        try touch(zip)
        let bundle = URL(fileURLWithPath: "/somewhere/else/WheelClick Upgrader.app")
        XCTAssertEqual(Set(cleanupTargets(bundle: bundle, downloads: downloads).map(\.standardizedFileURL)), Set([bundle, zip].map(\.standardizedFileURL)))
    }

    func testFindsSeveralNumberedZips() throws {
        let downloads = try makeDir()
        let zip1 = downloads.appendingPathComponent("WheelClick-Upgrader.zip")
        let zip2 = downloads.appendingPathComponent("WheelClick-Upgrader-2.zip")
        let zip3 = downloads.appendingPathComponent("WheelClick-Upgrader-3.zip")
        try touch(zip1); try touch(zip2); try touch(zip3)
        let bundle = URL(fileURLWithPath: "/somewhere/else/WheelClick Upgrader.app")
        XCTAssertEqual(Set(cleanupTargets(bundle: bundle, downloads: downloads).map(\.standardizedFileURL)), Set([bundle, zip1, zip2, zip3].map(\.standardizedFileURL)))
    }

    func testIgnoresUnrelatedFiles() throws {
        let downloads = try makeDir()
        try touch(downloads.appendingPathComponent("something-else.zip"))
        try touch(downloads.appendingPathComponent("WheelClick-Upgrader.dmg"))
        let bundle = URL(fileURLWithPath: "/somewhere/else/WheelClick Upgrader.app")
        XCTAssertEqual(cleanupTargets(bundle: bundle, downloads: downloads), [bundle])
    }

    func testMissingDownloadsDirectoryYieldsJustTheBundle() {
        let bundle = URL(fileURLWithPath: "/somewhere/else/WheelClick Upgrader.app")
        let downloads = URL(fileURLWithPath: "/nonexistent/Downloads")
        XCTAssertEqual(cleanupTargets(bundle: bundle, downloads: downloads), [bundle])
    }

    func testBundleInsideDownloadsIsNotDoubleCounted() throws {
        let downloads = try makeDir()
        let bundle = downloads.appendingPathComponent("WheelClick Upgrader.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let zip = downloads.appendingPathComponent("WheelClick-Upgrader.zip")
        try touch(zip)
        // The app bundle isn't a .zip, so the directory scan doesn't pick it up a second time.
        XCTAssertEqual(Set(cleanupTargets(bundle: bundle, downloads: downloads).map(\.standardizedFileURL)), Set([bundle, zip].map(\.standardizedFileURL)))
        XCTAssertEqual(cleanupTargets(bundle: bundle, downloads: downloads).filter { $0.standardizedFileURL == bundle.standardizedFileURL }.count, 1)
    }
}

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.responses[min(Self.requests, Self.responses.count - 1)]
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WaitForKeyTests: XCTestCase {
    func session(_ responses: [(Int, String)]) -> URLSession {
        StubProtocol.responses = responses; StubProtocol.requests = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    func testPollsThrough202() async throws {
        let s = session([(202, #"{"pending":true}"#), (202, #"{"pending":true}"#), (200, #"{"key":"K"}"#)])
        let key = try await waitForKey(checkoutID: "c", session: s, pollInterval: 1_000_000)
        XCTAssertEqual(key, "K")
        XCTAssertEqual(StubProtocol.requests, 3)
    }

    func testStopsOn4xx() async {
        let s = session([(404, #"{"error":"not_found"}"#)])
        do {
            _ = try await waitForKey(checkoutID: "c", session: s, pollInterval: 1_000_000)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? CrossgradeError, .server(code: "not_found"))
            XCTAssertEqual(StubProtocol.requests, 1)
        }
    }
}

final class RequestCheckoutTests: XCTestCase {
    private let stubs = WaitForKeyTests()

    func testRetriesInProgressThenSucceeds() async throws {
        let s = stubs.session([(409, #"{"error":"in_progress"}"#), (409, #"{"error":"in_progress"}"#), (200, #"{"checkout_id":"co_1"}"#)])
        let id = try await requestCheckout(receipt: Data([1]), email: "a@b.c", session: s, retryDelay: 1_000_000)
        XCTAssertEqual(id, "co_1")
        XCTAssertEqual(StubProtocol.requests, 3)
    }

    func testGivesUpAfterFiveInProgress() async {
        let s = stubs.session([(409, #"{"error":"in_progress"}"#)])
        do {
            _ = try await requestCheckout(receipt: Data([1]), email: "a@b.c", session: s, retryDelay: 1_000_000)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? CrossgradeError, .server(code: "in_progress"))
            XCTAssertEqual(StubProtocol.requests, 5)
        }
    }

    func testNoPurchaseDoesNotRetry() async {
        let s = stubs.session([(422, #"{"error":"no_purchase"}"#), (200, #"{"checkout_id":"co_1"}"#)])
        do {
            _ = try await requestCheckout(receipt: Data([1]), email: "a@b.c", session: s, retryDelay: 1_000_000)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? CrossgradeError, .server(code: "no_purchase"))
            XCTAssertEqual(StubProtocol.requests, 1)
        }
    }
}
