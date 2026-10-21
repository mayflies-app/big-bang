import XCTest
import BigBangCore
import BigBangTestSupport
@testable import BigBangNetworking

final class RuntimeLocalizationTests: XCTestCase {
    func testKnownFailuresCanFollowLanguageSwitchWithoutChangingDetails() {
        let chinese = "API 请求失败（HTTP 503），请检查服务状态。"
        let english = RuntimeTranslations.message(chinese, language: .english)
        XCTAssertEqual(english, "The API request failed (HTTP 503). Check the service status.")
        XCTAssertEqual(RuntimeTranslations.message(english, language: .simplifiedChinese), chinese)

        let outputLimit = "响应未正常完成（length），已保留部分结果。"
        let translated = RuntimeTranslations.message(outputLimit, language: .english)
        XCTAssertEqual(translated, "The response did not finish normally (length). Partial output has been kept.")
        XCTAssertEqual(RuntimeTranslations.message(translated, language: .simplifiedChinese), outputLimit)

        let unknown = "User output: API request failed — this is quoted source text."
        XCTAssertEqual(RuntimeTranslations.message(unknown, language: .simplifiedChinese), unknown)
    }

    @MainActor func testStreamFailuresUseRequestLanguageInsteadOfGlobalLanguage() async throws {
        let saved = L10n.currentLanguage
        defer { L10n.currentLanguage = saved }
        let fixture = try SSEFixture()
        defer { fixture.stop() }
        for mode in APIMode.allCases {
            for language in [AppLanguage.english, .simplifiedChinese] {
                L10n.currentLanguage = language == .english ? .simplifiedChinese : .english
                let failure = try await collectFailure("plain401", mode: mode, language: language, fixture: fixture)
                XCTAssertEqual(failure, language == .english
                    ? "The API Key is invalid. Check your settings."
                    : "API Key 无效，请检查设置。")
                XCTAssertFalse(failure.contains("local-test-key"))

                let incomplete = try await collectFailure("incomplete", mode: mode, language: language, fixture: fixture)
                XCTAssertEqual(RuntimeTranslations.message(incomplete, language: language), incomplete)
                if language == .english {
                    XCTAssertFalse(incomplete.contains("响应"))
                    XCTAssertTrue(incomplete.contains("output") || incomplete.contains("Partial"))
                } else {
                    XCTAssertTrue(incomplete.contains("响应"))
                }
            }
        }
    }

    @MainActor private func collectFailure(_ scenario: String, mode: APIMode,
                                           language: AppLanguage, fixture: SSEFixture) async throws -> String {
        let stream = ModelStream()
        var configuration = Configuration()
        configuration.language = language
        configuration.apiBaseURL = fixture.baseURL
        configuration.apiMode = mode
        configuration.model = "test-model"
        let terminal = expectation(description: "localized terminal event")
        var failure: String?
        try stream.start(.init(text: scenario, instructions: "Test", configuration: configuration, apiKey: "local-test-key")) { event in
            switch event {
            case .failed(let message): failure = message; terminal.fulfill()
            case .completed: XCTFail("Expected failure"); terminal.fulfill()
            case .delta: break
            }
        }
        await fulfillment(of: [terminal], timeout: 5)
        stream.cancel()
        return try XCTUnwrap(failure)
    }
}
