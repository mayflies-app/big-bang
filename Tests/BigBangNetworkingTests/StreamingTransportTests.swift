import Foundation
import XCTest
import BigBangCore
import BigBangTestSupport
@testable import BigBangNetworking

/// Black-box contracts against a real loopback socket, shared by both public API modes.
/// No credentials, provider network access, or process-global URLProtocol interception.
final class StreamingTransportTests: XCTestCase {
    private final class WeakStream {
        weak var value: ModelStream?
        init(_ value: ModelStream?) { self.value = value }
    }

    private func request(_ scenario: String, mode: APIMode, fixture: SSEFixture) -> ModelRequest {
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.apiBaseURL = fixture.baseURL
        configuration.apiMode = mode
        configuration.model = "test-model"
        return .init(text: scenario, instructions: "Translate", configuration: configuration, apiKey: "local-test-key")
    }

    @MainActor private func eventually(_ description: String, timeout: TimeInterval = 3,
                                       condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), description)
    }

    @MainActor private func collect(_ scenario: String, mode: APIMode, fixture: SSEFixture,
                                    expectingPeerClose: Bool = false) async throws -> [StreamEvent] {
        let stream = ModelStream()
        let priorClosed = fixture.recordedPeerDisconnections.count
        var events: [StreamEvent] = []
        let terminal = expectation(description: "\(mode.rawValue) \(scenario) terminal")
        terminal.assertForOverFulfill = true
        try stream.start(request(scenario, mode: mode, fixture: fixture)) { event in
            events.append(event)
            switch event { case .completed, .failed: terminal.fulfill(); case .delta: break }
        }
        await fulfillment(of: [terminal], timeout: 8)
        // Catch late completions/errors while retaining the stream and its event callback.
        try? await Task.sleep(for: .milliseconds(40))
        if expectingPeerClose {
            // Explicit cleanup must not manufacture the socket-close evidence under test.
            await eventually("Transport failure must close the socket before explicit cleanup") {
                fixture.recordedPeerDisconnections.count > priorClosed
            }
        }
        stream.cancel()
        return events
    }

    @MainActor func testLineEndingsLFCRLFAndCRCompleteInBothModes() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            for ending in ["lf", "crlf", "cr"] {
                let events = try await collect("transport-lines-" + ending, mode: mode, fixture: fixture)
                XCTAssertEqual(events, [.delta("你好 🌍"), .completed], "\(mode.rawValue) \(ending)")
            }
        }
    }

    @MainActor func testFragmentedBOMUnicodeAndMultilineDataInBothModes() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let events = try await collect("transport-framing", mode: mode, fixture: fixture)
            XCTAssertEqual(events, [.delta("你好 🌍"), .completed], mode.rawValue)
        }
    }

    @MainActor func testEmptyDataKeepaliveBeforeTextAndTerminalSucceeds() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let events = try await collect("transport-empty-data", mode: mode, fixture: fixture)
            XCTAssertEqual(events, [.delta("你好 🌍"), .completed], mode.rawValue)
        }
    }

    @MainActor func testProtocolTerminalCompletesAndClosesConnectionWithoutWaitingForEOF() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let stream = ModelStream()
            let priorClosed = fixture.recordedPeerDisconnections.count
            var events: [StreamEvent] = []
            let terminal = expectation(description: "Protocol terminal without server EOF")
            try stream.start(request("transport-terminal-held", mode: mode, fixture: fixture)) { event in
                events.append(event)
                switch event { case .completed, .failed: terminal.fulfill(); case .delta: break }
            }
            await fulfillment(of: [terminal], timeout: 3)
            XCTAssertEqual(events, [.delta("你好 🌍"), .completed], mode.rawValue)
            // Retain the stream and avoid explicit cancel until peer-close evidence is observed.
            await eventually("Protocol terminal must close a connection that the server keeps open") {
                fixture.recordedPeerDisconnections.count > priorClosed
            }
            stream.cancel()
        }
    }

    @MainActor func testCancelBeforeHTTPHeadersClosesPeerConnection() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let stream = ModelStream()
            var events: [StreamEvent] = []
            let priorRequests = fixture.recordedRequests.count
            let priorClosed = fixture.recordedPeerDisconnections.count
            try stream.start(request("transport-waiting-headers", mode: mode, fixture: fixture)) { events.append($0) }
            await eventually("Server must receive request before cancellation") { fixture.recordedRequests.count > priorRequests }
            stream.cancel()
            await eventually("Cancel waiting for headers must close the actual socket") { fixture.recordedPeerDisconnections.count > priorClosed }
            XCTAssertEqual(events, [], mode.rawValue)
        }
    }

    @MainActor func testCancelAfterDeltaClosesSilentPeerConnection() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let stream = ModelStream()
            let first = expectation(description: "first delta")
            var events: [StreamEvent] = []
            let priorClosed = fixture.recordedPeerDisconnections.count
            try stream.start(request("transport-silent", mode: mode, fixture: fixture)) { event in
                events.append(event)
                if event == .delta("first") { first.fulfill() }
            }
            await fulfillment(of: [first], timeout: 3)
            stream.cancel()
            await eventually("Cancel a silent stream must close the actual socket") { fixture.recordedPeerDisconnections.count > priorClosed }
            XCTAssertEqual(events, [.delta("first")], mode.rawValue)
        }
    }

    @MainActor func testCrossModeReplacementSuppressesOldEventsInBothDirections() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for oldMode in APIMode.allCases {
            let newMode: APIMode = oldMode == .responses ? .chatCompletions : .responses
            let stream = ModelStream()
            let first = expectation(description: "old first delta")
            var oldEvents: [StreamEvent] = []
            try stream.start(request("transport-delayed", mode: oldMode, fixture: fixture)) { event in
                oldEvents.append(event)
                if event == .delta("first") { first.fulfill() }
            }
            await fulfillment(of: [first], timeout: 3)
            let complete = expectation(description: "replacement completes")
            var replacement: [StreamEvent] = []
            try stream.start(request("transport-lines-lf", mode: newMode, fixture: fixture)) { event in
                replacement.append(event)
                if event == .completed { complete.fulfill() }
            }
            await fulfillment(of: [complete], timeout: 3)
            try? await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(oldEvents, [.delta("first")])
            XCTAssertEqual(replacement, [.delta("你好 🌍"), .completed])
            stream.cancel()
        }
    }

    @MainActor func testOverlongUnterminatedLineFailsWithoutWaitingForEOF() async throws {
        try await assertBoundedFailure("transport-unfinished-line")
    }

    @MainActor func testOverlongUnterminatedEventFailsWithoutWaitingForEOF() async throws {
        try await assertBoundedFailure("transport-unfinished-event")
    }

    @MainActor private func assertBoundedFailure(_ scenario: String) async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let priorClosed = fixture.recordedPeerDisconnections.count
            let events = try await collect(scenario, mode: mode, fixture: fixture, expectingPeerClose: true)
            XCTAssertEqual(events.count, 1, mode.rawValue)
            guard case .failed(let message) = events.last else { XCTFail("Oversize SSE must fail before EOF: \(mode.rawValue)"); continue }
            XCTAssertFalse(message.contains("provider-private-payload"))
            XCTAssertFalse(message.contains("local-test-key"))
            await eventually("Oversize rejection must close the socket") { fixture.recordedPeerDisconnections.count > priorClosed }
        }
    }

    @MainActor func testLegalEventJustBelowByteBudgetSucceeds() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let events = try await collect("transport-near-limit", mode: mode, fixture: fixture)
            XCTAssertEqual(events, [.delta("near-limit"), .completed], mode.rawValue)
        }
    }

    @MainActor func testOversizedHTTPErrorBodyTerminatesEarlyWithStatusClassification() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            for (status, expected) in [(401, "API Key"), (404, "不存在"), (429, "频繁"), (503, "503")] {
                let priorClosed = fixture.recordedPeerDisconnections.count
                let events = try await collect("transport-error-large-\(status)", mode: mode, fixture: fixture, expectingPeerClose: true)
                XCTAssertEqual(events.count, 1)
                guard case .failed(let message) = events.last else { XCTFail("Oversized HTTP error body must terminate before EOF"); continue }
                XCTAssertTrue(message.contains(expected), "\(mode.rawValue) HTTP \(status): \(message)")
                XCTAssertFalse(message.contains("provider-private-payload"))
                XCTAssertFalse(message.contains("local-test-key"))
                await eventually("Bounded HTTP error must close socket") { fixture.recordedPeerDisconnections.count > priorClosed }
            }
        }
    }

    @MainActor func testSessionDoesNotPersistOrSendProviderCookiesAcrossRequests() async throws {
        let fixture = try SSEFixture()
        defer {
            // Remove only this fixture's UUID-named cookie if an old implementation leaked it.
            for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.name == fixture.transportCookieName {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
            fixture.stop()
        }
        for mode in APIMode.allCases {
            let initial = try await collect("transport-cookie-set", mode: mode, fixture: fixture)
            XCTAssertEqual(initial.last, .completed)
            let following = try await collect("transport-cookie-check", mode: mode, fixture: fixture)
            XCTAssertEqual(following.last, .completed)
            XCTAssertFalse(fixture.recordedRequests.last?.headers["cookie"]?.contains(fixture.transportCookieName) ?? false)
            XCTAssertFalse((HTTPCookieStorage.shared.cookies ?? []).contains { $0.name == fixture.transportCookieName })
        }
    }

    @MainActor func testFailureThenSuccessOnSameStreamDeliversSingleTerminalEach() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let stream = ModelStream()
            var failed: [StreamEvent] = []
            let firstTerminal = expectation(description: "first fails")
            try stream.start(request("invalid-json", mode: mode, fixture: fixture)) { event in
                failed.append(event)
                if case .failed = event { firstTerminal.fulfill() }
            }
            await fulfillment(of: [firstTerminal], timeout: 3)
            let recovered = expectation(description: "second succeeds")
            var successful: [StreamEvent] = []
            try stream.start(request("transport-lines-lf", mode: mode, fixture: fixture)) { event in
                successful.append(event)
                if event == .completed { recovered.fulfill() }
            }
            await fulfillment(of: [recovered], timeout: 3)
            try? await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(failed.count, 1)
            XCTAssertEqual(successful, [.delta("你好 🌍"), .completed])
            stream.cancel()
        }
    }

    // Sort last: the unfixed Responses implementation aborts the test process at this boundary.
    @MainActor func testZImmediateCancellationAndReleaseInSameActorTurnAreSilent() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            var events: [StreamEvent] = []
            for _ in 0..<10 {
                let stream = ModelStream()
                try stream.start(request("transport-waiting-headers", mode: mode, fixture: fixture)) { events.append($0) }
                stream.cancel()
                var released: ModelStream? = ModelStream()
                let identity = WeakStream(released)
                try released?.start(request("transport-waiting-headers", mode: mode, fixture: fixture)) { events.append($0) }
                released = nil
                XCTAssertNil(identity.value, "An unstarted transport must not keep ModelStream alive")
            }
            try? await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(events, [], mode.rawValue)
        }
    }
}
