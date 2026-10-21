import XCTest
import BigBangCore
import BigBangTestSupport
@testable import BigBangNetworking

final class ModelStreamTests: XCTestCase {
    @MainActor private func collect(_ source: String, mode: APIMode, fixture: SSEFixture, key: String = "local-test-key") async throws -> [StreamEvent] {
        let stream = ModelStream()
        var config = Configuration(); config.apiBaseURL = fixture.baseURL + "/"; config.apiMode = mode; config.model = "test-model"
        var events: [StreamEvent] = []
        let terminal = expectation(description: "terminal")
        try stream.start(.init(text: source, instructions: "Translate", configuration: config, apiKey: key)) { event in
            events.append(event)
            switch event { case .completed, .failed: terminal.fulfill(); case .delta: break }
        }
        await fulfillment(of: [terminal], timeout: 5)
        stream.cancel()
        return events
    }
    @MainActor func testBothSDKProtocolsStreamFragmentedUnicodeAndCustomPath() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let events = try await collect("success", mode: mode, fixture: fixture)
            XCTAssertEqual(events, [.delta("你好 🌍"), .delta("\n流式完成"), .completed])
            let request = try XCTUnwrap(fixture.recordedRequests.last)
            XCTAssertEqual(request.path, "/proxy/openai/v1" + mode.route)
            XCTAssertEqual(request.headers["authorization"], "Bearer local-test-key")
            XCTAssertEqual(request.body["model"] as? String, "test-model")
            XCTAssertEqual(request.body["stream"] as? Bool, true)
            if mode == .responses {
                XCTAssertEqual(request.body["input"] as? String, "success")
                XCTAssertEqual(request.body["instructions"] as? String, "Translate")
                XCTAssertEqual(request.body["store"] as? Bool, false)
            } else {
                let messages = try XCTUnwrap(request.body["messages"] as? [[String: Any]])
                XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
                XCTAssertEqual(messages.map { $0["content"] as? String }, ["Translate", "success"])
            }
        }
    }
    @MainActor func testTruncationAndOutputLimitPreservePartialResult() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            for scenario in ["truncated", "incomplete"] {
                let events = try await collect(scenario, mode: mode, fixture: fixture)
                XCTAssertEqual(events.first, .delta("部分结果"))
                guard case .failed = events.last else { XCTFail("Incomplete response reported as success"); continue }
            }
        }
    }
    @MainActor func testRefusalIsRendered() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            let events = try await collect("refusal", mode: mode, fixture: fixture)
            XCTAssertEqual(events, [.delta("无法协助"), .completed])
        }
    }
    @MainActor func testAPIErrorsAndMalformedEventsNeverExposeProviderPayload() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        for mode in APIMode.allCases {
            for scenario in ["unauthorized", "plain401", "missing", "rate", "invalid-json"] {
                let events = try await collect(scenario, mode: mode, fixture: fixture)
                guard case .failed(let message) = events.last else { XCTFail("Missing error"); continue }
                XCTAssertFalse(message.contains("local-test-key"))
                if scenario == "unauthorized" || scenario == "plain401" { XCTAssertTrue(message.contains("API Key")) }
            }
        }
    }
    @MainActor func testUnauthenticatedLocalServiceOmitsAuthorizationHeader() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        let events = try await collect("success", mode: .chatCompletions, fixture: fixture, key: "")
        XCTAssertEqual(events.last, .completed)
        XCTAssertNil(fixture.recordedRequests.last?.headers["authorization"])
    }
    @MainActor func testStopAndRestartDoNotDeliverOldStreamEvents() async throws {
        let fixture = try SSEFixture(); defer { fixture.stop() }
        let stream = ModelStream()
        var config = Configuration(); config.apiBaseURL = fixture.baseURL; config.model = "test-model"
        let firstChunk = expectation(description: "first delta")
        var oldEvents: [StreamEvent] = []
        try stream.start(.init(text: "cancel", instructions: "Test", configuration: config, apiKey: "local-test-key")) { event in
            oldEvents.append(event)
            if oldEvents.count == 1 { firstChunk.fulfill() }
        }
        await fulfillment(of: [firstChunk], timeout: 5)
        stream.cancel()
        let snapshot = oldEvents
        let complete = expectation(description: "new stream completes")
        var newEvents: [StreamEvent] = []
        try stream.start(.init(text: "success", instructions: "Test", configuration: config, apiKey: "local-test-key")) { event in
            newEvents.append(event)
            if event == .completed { complete.fulfill() }
        }
        await fulfillment(of: [complete], timeout: 5)
        XCTAssertEqual(oldEvents, snapshot)
        XCTAssertEqual(newEvents, [.delta("你好 🌍"), .delta("\n流式完成"), .completed])
        stream.cancel()
    }
    @MainActor func testMissingOfficialKeyAndEmptyInputNeverStartRequest() throws {
        let stream = ModelStream()
        let configuration = Configuration()
        XCTAssertThrowsError(try stream.start(.init(text: "text", instructions: "Test", configuration: configuration, apiKey: "")) { _ in XCTFail() })
        XCTAssertThrowsError(try stream.start(.init(text: " \n", instructions: "Test", configuration: configuration, apiKey: "key")) { _ in XCTFail() })
    }
}
