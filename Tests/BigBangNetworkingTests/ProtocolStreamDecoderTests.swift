import Foundation
import XCTest
import BigBangCore
@testable import BigBangNetworking

final class ProtocolStreamDecoderTests: XCTestCase {
    private func decode(_ json: String, mode: APIMode = .chatCompletions) throws -> [StreamEvent] {
        try ProtocolStreamDecoder.events(from: .init(name: "message", data: Data(json.utf8)), mode: mode, language: .english)
    }

    func testChatConsumesOnlyChoiceZeroWithoutUnrelatedProviderMetadata() throws {
        XCTAssertEqual(try decode("""
        {"choices":[{"index":1,"delta":{"content":"other choice"},"finish_reason":"stop"},
                    {"index":0,"delta":{"role":"assistant","content":"visible"},"finish_reason":null}],
         "provider_metadata":{"unknown":{"value":42}}}
        """), [.delta("visible")])
    }

    func testChatRoleAndUsageEventsCarryNoTextOrCompletion() throws {
        XCTAssertEqual(try decode("""
        {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}
        """), [])
        XCTAssertEqual(try decode("""
        {"choices":[],"usage":{"input_tokens":7,"provider_extension":true}}
        """), [])
    }

    func testChatOutputLimitPreservesTextInTheTerminalChunk() throws {
        let events = try decode("""
        {"choices":[{"index":0,"delta":{"content":"partial result"},"finish_reason":"length"}]}
        """)
        XCTAssertEqual(events.first, .delta("partial result"))
        XCTAssertEqual(events.count, 2)
        guard case .failed(let message) = events.last else { return XCTFail("Output limit must fail") }
        XCTAssertEqual(message, "The response did not finish normally (length). Partial output has been kept.")
    }

    func testUnknownFinishReasonAndNonTextContentAreRejected() throws {
        for json in [
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"provider-private-payload"}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":42},"finish_reason":null}]}"#
        ] {
            XCTAssertThrowsError(try decode(json))
        }
    }

    func testEmptyKeepalivesAndDoneAreNeverSuccessfulTerminals() throws {
        for mode in APIMode.allCases {
            XCTAssertEqual(try decode("", mode: mode), [])
            XCTAssertEqual(try decode("[DONE]", mode: mode), [])
        }
    }
}
