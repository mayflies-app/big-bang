import XCTest
import BigBangCore
import BigBangTestSupport
@testable import BigBangNetworking

final class ResponsesCompatibilityTests: XCTestCase {
    @MainActor private func collect(_ scenario: String, fixture: SSEFixture) async throws -> [StreamEvent] {
        let stream = ModelStream()
        let terminal = expectation(description: scenario + " terminates")
        var events: [StreamEvent] = []
        try stream.start(request(scenario, fixture: fixture)) { event in
            events.append(event)
            switch event {
            case .completed, .failed: terminal.fulfill()
            case .delta: break
            }
        }
        await fulfillment(of: [terminal], timeout: 5)
        stream.cancel()
        return events
    }

    private func request(_ scenario: String, fixture: SSEFixture) -> ModelRequest {
        var configuration = Configuration()
        configuration.apiBaseURL = fixture.baseURL
        configuration.apiMode = .responses
        configuration.model = "test-model"
        return .init(text: scenario, instructions: "Translate", configuration: configuration, apiKey: "local-test-key")
    }

    @MainActor func testGatewayUsageLifecycleIgnoresReasoningAndUnknownExtensions() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        let events = try await collect("responses-lifecycle", fixture: fixture)
        XCTAssertEqual(events, [.delta("你好 🌍"), .delta("\n流式完成"), .completed])
        XCTAssertEqual(fixture.recordedRequests.last?.path, "/proxy/openai/v1/responses")
    }

    @MainActor func testThinTextAndCompletedEventsNeedNoSDKMetadata() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        let events = try await collect("responses-thin-completed", fixture: fixture)
        XCTAssertEqual(events, [.delta("你好 🌍"), .delta("\n流式完成"), .completed])
    }

    @MainActor func testThinRefusalDeltaIsRenderedWithoutDuplicatingCompletedOutput() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        let events = try await collect("responses-refusal", fixture: fixture)
        XCTAssertEqual(events, [.delta("无法协助"), .completed])
    }

    @MainActor func testThinFailureTerminalsPreserveTextAndHideProviderPayload() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for scenario in ["responses-failed", "responses-error", "responses-incomplete"] {
            let events = try await collect(scenario, fixture: fixture)
            XCTAssertEqual(events.count, 2, scenario)
            XCTAssertEqual(events.first, .delta("你好 🌍"), scenario)
            guard case .failed(let message) = events.last else {
                XCTFail("Expected provider failure for \(scenario)"); continue
            }
            XCTAssertFalse(message.contains("provider-private-payload"), scenario)
            XCTAssertFalse(message.contains("local-test-key"), scenario)
        }
    }

    @MainActor func testEOFAndDoneSentinelCannotReplaceResponseCompleted() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for scenario in ["responses-truncated", "responses-done-only"] {
            let events = try await collect(scenario, fixture: fixture)
            XCTAssertEqual(events.count, 2, scenario)
            XCTAssertEqual(events.first, .delta("你好 🌍"), scenario)
            guard case .failed = events.last else {
                XCTFail("Missing response.completed must fail: \(scenario)"); continue
            }
        }
    }

    @MainActor func testMalformedTextEventsFailInsteadOfSilentlyDroppingContent() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for scenario in ["responses-malformed", "responses-missing-delta", "responses-nonstring-delta", "responses-missing-type"] {
            let events = try await collect(scenario, fixture: fixture)
            XCTAssertEqual(events.count, 2, scenario)
            XCTAssertEqual(events.first, .delta("你好 🌍"), scenario)
            guard case .failed = events.last else {
                XCTFail("Malformed event must fail: \(scenario)"); continue
            }
        }
    }

    @MainActor func testSSECommentsMetadataMultilineDataCRLFAndFragmentedUTF8() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        let events = try await collect("responses-framing", fixture: fixture)
        XCTAssertEqual(events, [.delta("你好 🌍"), .delta("\n流式完成"), .completed])
    }

    @MainActor func testResponsesCancellationAndRestartSuppressOldEvents() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        let stream = ModelStream()
        let firstDelta = expectation(description: "old request emits text")
        let noOldEvents = expectation(description: "cancelled request stays silent")
        noOldEvents.isInverted = true
        var oldEvents: [StreamEvent] = []
        var cancelled = false
        try stream.start(request("responses-cancel", fixture: fixture)) { event in
            if cancelled { noOldEvents.fulfill() }
            oldEvents.append(event)
            if oldEvents.count == 1 { firstDelta.fulfill() }
        }
        await fulfillment(of: [firstDelta], timeout: 5)
        XCTAssertEqual(oldEvents, [.delta("生成中 ")])
        stream.cancel()
        cancelled = true
        let completed = expectation(description: "new request completes")
        var newEvents: [StreamEvent] = []
        try stream.start(request("responses-thin-completed", fixture: fixture)) { event in
            newEvents.append(event)
            switch event {
            case .completed, .failed: completed.fulfill()
            case .delta: break
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        await fulfillment(of: [noOldEvents], timeout: 0.3)
        XCTAssertEqual(oldEvents, [.delta("生成中 ")])
        XCTAssertEqual(newEvents, [.delta("你好 🌍"), .delta("\n流式完成"), .completed])
        stream.cancel()
    }
}
