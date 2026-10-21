import XCTest
@testable import BigBangCore

final class CoreTests: XCTestCase {
    func testDefaultsAndSettingsRoundTrip() throws {
        let settings = Configuration(language: .simplifiedChinese)
        try settings.validate()
        XCTAssertEqual(settings.presets.map(\.name), ["🌐 翻译", "💡 解释", "📝 总结", "📊 可视化", "🤖 助手"])
        XCTAssertEqual(settings.presets[3].builtIn, .visualize)
        XCTAssertEqual(settings.presets[3].id, UUID(uuidString: "B16BA900-0000-4000-8000-000000000004"))
        XCTAssertEqual(settings.presets[3].shortcut, .init(keyCode: 21, modifiers: 6144, label: "⌃⌥4"))
        XCTAssertEqual(settings.presets[4].builtIn?.rawValue, "assistant")
        XCTAssertEqual(settings.presets[4].id, UUID(uuidString: "B16BA900-0000-4000-8000-000000000005"))
        XCTAssertEqual(settings.presets[4].shortcut, .init(keyCode: 23, modifiers: 6144, label: "⌃⌥5"))
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testShortcutCollisionIgnoresDisplayLabel() {
        var settings = Configuration(language: .simplifiedChinese)
        settings.presets[1].shortcut = settings.presets[0].shortcut
        settings.presets[1].shortcut.label = "other"
        XCTAssertThrowsError(try settings.validate())
    }
    func testEmptyPromptAndUnmodifiedKeyAreRejected() {
        var settings = Configuration(language: .simplifiedChinese)
        settings.presets[0].prompt = " \n"
        XCTAssertThrowsError(try settings.validate())
        settings = Configuration(language: .simplifiedChinese)
        settings.presets[0].shortcut.modifiers = 512
        XCTAssertThrowsError(try settings.validate())
    }
    func testOmittedConnectionFieldsUseDefaultsWithoutChangingPresets() throws {
        let original = Configuration(language: .simplifiedChinese)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "apiBaseURL"); object.removeValue(forKey: "apiMode")
        let decoded = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.requiresAPIKey)
    }
    func testCustomEndpointPortAndPrefixArePreserved() throws {
        let endpoint = try APIEndpoint(" http://127.0.0.1:11434/api/openai/v1/// \n")
        XCTAssertEqual(endpoint.scheme, "http")
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.port, 11434)
        XCTAssertEqual(endpoint.basePath, "/api/openai/v1")
        XCTAssertEqual(endpoint.normalizedURL, "http://127.0.0.1:11434/api/openai/v1")
        XCTAssertEqual(try APIEndpoint("https://example.com/").basePath, "")
        var config = Configuration(language: .simplifiedChinese); config.apiBaseURL = endpoint.normalizedURL; config.apiMode = .chatCompletions
        XCTAssertFalse(config.requiresAPIKey)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)), config)
    }
    func testInvalidEndpointsAreRejected() {
        for value in ["", "example.com/v1", "ftp://host/v1", "https://user:pass@host/v1", "https://host/v1?key=secret", "https://host/v1#fragment", "https://host:99999/v1", "https://host/v1/responses", "https://host/v1/chat/completions", "https://bad host/v1"] {
            XCTAssertThrowsError(try APIEndpoint(value), value)
        }
    }
}
