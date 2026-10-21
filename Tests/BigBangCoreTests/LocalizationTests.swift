import XCTest
@testable import BigBangCore

@MainActor private final class LanguageSink {
    var configuration: Configuration
    var writes = 0
    var keyWrites = 0
    var didSaveKey: (() -> Void)?
    var fail = false
    init(_ configuration: Configuration = Configuration(language: .simplifiedChinese)) { self.configuration = configuration }
    func editor(saveDelay: Duration = .seconds(30)) -> SettingsEditor {
        SettingsEditor(configuration: configuration, saveDelay: saveDelay, save: { candidate, key in
            if self.fail { throw ValidationError("保存失败") }
            self.configuration = candidate; self.writes += 1
            if !key.isEmpty {
                self.keyWrites += 1
                self.didSaveKey?()
            }
        }, deleteKey: {})
    }
}

final class LocalizationTests: XCTestCase {
    override func tearDown() { L10n.currentLanguage = .simplifiedChinese; super.tearDown() }

    func testFirstLaunchUsesFirstSupportedPreferredLanguage() {
        XCTAssertEqual(AppLanguage.preferred(in: ["fr-FR", "zh-Hant-TW", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.preferred(in: ["de-DE", "en_GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.preferred(in: ["fr", "ja"]), .english)
        XCTAssertEqual(AppLanguage.preferred(in: []), .english)
        XCTAssertEqual(AppLanguage.preferred(in: ["zh-Hans-CN"]), .simplifiedChinese)
        let firstLaunch = Configuration()
        XCTAssertEqual(firstLaunch.language, AppLanguage.preferred(in: Locale.preferredLanguages))
        XCTAssertEqual(firstLaunch.presets, Preset.defaults(for: firstLaunch.language))
    }

    func testLanguageSelectionPersistsAndReloadKeepsEditedPresets() throws {
        for language in AppLanguage.allCases {
            var configuration = Configuration(language: language)
            configuration.presets[0].name = "User title"
            configuration.presets[1].prompt = "User instructions"
            configuration.presets.reverse()
            XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(configuration)), configuration)
        }
        let english = try JSONDecoder().decode(Configuration.self, from: Data("{\"language\":\"en\"}".utf8))
        XCTAssertEqual(english.presets, Preset.defaults(for: .english))
    }

    func testDefaultsKeepIdentityAndUseLanguageSpecificInstructions() {
        let chinese = Preset.defaults(for: .simplifiedChinese)
        let english = Preset.defaults(for: .english)
        XCTAssertEqual(chinese, Preset.defaults)
        XCTAssertEqual(chinese.map(\.id), english.map(\.id))
        XCTAssertEqual(chinese.map(\.builtIn), english.map(\.builtIn))
        XCTAssertEqual(chinese.map(\.shortcut), english.map(\.shortcut))
        XCTAssertEqual(english.map(\.name), ["🌐 Translate", "💡 Explain", "📝 Summarize", "📊 Visualize", "🤖 Assistant"])
        XCTAssertTrue(english[0].prompt.contains("Simplified Chinese"))
        XCTAssertTrue(english[0].prompt.contains("English"))
        XCTAssertTrue(english[1].prompt.contains("in English"))
        XCTAssertTrue(english[2].prompt.contains("in English"))
    }

    func testAssistantUsesStandaloneInstructionsForDirectRequests() throws {
        for language in AppLanguage.allCases {
            let assistant = try XCTUnwrap(Preset.defaults(for: language).first { $0.builtIn?.rawValue == "assistant" })
            XCTAssertEqual(assistant.prompt, L10n.string("preset.assistant.instructions", language: language))
            XCTAssertFalse(assistant.prompt.contains(L10n.string("preset.singleTurn", language: language)))
        }
    }

    func testLocalizationUsesExplicitLanguageAndErrorsTranslateDynamically() throws {
        XCTAssertEqual(L10n.string("请输入模型名称。", language: .english), "Enter a model name.")
        XCTAssertEqual(L10n.string("未登记内容", language: .english), "未登记内容")
        let error = ValidationError(format: "钥匙串操作失败（%@）。请检查系统钥匙串授权。", arguments: ["100% 中文"])
        XCTAssertEqual(error.message, "钥匙串操作失败（100% 中文）。请检查系统钥匙串授权。")
        L10n.currentLanguage = .english
        XCTAssertEqual(error.localizedDescription, "Keychain operation failed (100% 中文). Check your Keychain permissions.")
        XCTAssertEqual(L10n.format("API 请求失败（HTTP %@），请检查服务状态。", "503", language: .english),
                       "The API request failed (HTTP 503). Check the service status.")
        L10n.currentLanguage = .simplifiedChinese
        XCTAssertEqual(error.localizedDescription, "钥匙串操作失败（100% 中文）。请检查系统钥匙串授权。")
    }

    func testResourceCatalogsHaveMatchingKeysAndFormatArguments() throws {
        let english = LocalizationResources.catalog(language: "en", bundle: L10n.resourceBundle)
        let chinese = LocalizationResources.catalog(language: "zh-Hans", bundle: L10n.resourceBundle)
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertEqual(english["界面语言"], "Interface Language")
        XCTAssertEqual(chinese["界面语言"], "界面语言")
        XCTAssertEqual(L10n.string("preset.translate.name", language: .english), "🌐 Translate")
        for catalog in [english, chinese] {
            for index in 1...7 {
                let chunk = try XCTUnwrap(catalog["demo.chunk.\(index)"])
                XCTAssertFalse(chunk.isEmpty)
            }
        }
        let placeholder = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?[hlLzjt]*[@diuoxXfFeEgGaAcCsSp]"#)
        func arguments(_ value: String) -> [String] {
            placeholder.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            }
        }
        for key in english.keys {
            XCTAssertEqual(arguments(english[key]!), arguments(chinese[key]!), key)
        }
    }

    @MainActor func testLanguageSwitchPersistsImmediatelyAndRoundTripRestoresDefaults() {
        let sink = LanguageSink(); let form = sink.editor()
        XCTAssertTrue(form.changeLanguage(to: .english))
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.configuration.language, .english)
        XCTAssertEqual(sink.configuration.presets, Preset.defaults(for: .english))
        XCTAssertTrue(form.changeLanguage(to: .simplifiedChinese))
        XCTAssertEqual(sink.configuration.presets, Preset.defaults)
        XCTAssertEqual(sink.writes, 2)
        XCTAssertTrue(form.changeLanguage(to: .simplifiedChinese))
        XCTAssertEqual(sink.writes, 2)
    }

    @MainActor func testSwitchPreservesEditedFieldsCustomPresetsIDsShortcutsAndOrder() {
        var configuration = Configuration(language: .simplifiedChinese)
        configuration.presets[0].name = "保留名称"
        configuration.presets[1].prompt = "保留指令"
        let explanationID = configuration.presets[1].id
        configuration.presets[2].shortcut = .init(keyCode: 22, modifiers: 6144, label: "⌃⌥6")
        configuration.presets.reverse()
        let custom = Preset(name: "自定义", prompt: "自定义指令", shortcut: .init(keyCode: 28, modifiers: 6144, label: "⌃⌥8"))
        configuration.presets.insert(custom, at: 1)
        let sink = LanguageSink(configuration); let form = sink.editor()
        XCTAssertTrue(form.changeLanguage(to: .english))
        XCTAssertEqual(form.draft.presets.map(\.id), configuration.presets.map(\.id))
        XCTAssertEqual(form.draft.presets.map(\.shortcut), configuration.presets.map(\.shortcut))
        XCTAssertEqual(form.draft.presets[1], custom)
        XCTAssertEqual(form.draft.presets.last?.name, "保留名称")
        XCTAssertEqual(form.draft.presets.last?.prompt, Preset.defaults(for: .english)[0].prompt)
        let explanation = form.draft.presets.first { $0.id == explanationID }
        XCTAssertEqual(explanation?.prompt, "保留指令")
        XCTAssertEqual(explanation?.name, "💡 Explain")
        XCTAssertTrue(form.changeLanguage(to: .simplifiedChinese))
        XCTAssertEqual(form.draft.presets, configuration.presets)
    }

    @MainActor func testFailedSwitchRollsBackAndPendingKeyResumesAfterRetry() async throws {
        let sink = LanguageSink(); let form = sink.editor(saveDelay: .milliseconds(30))
        let keySaved = expectation(description: "The pending key is saved after the language switch retry")
        keySaved.assertForOverFulfill = true
        sink.didSaveKey = { keySaved.fulfill() }
        form.apiKeyInput = "pending-key"
        sink.fail = true
        XCTAssertFalse(form.changeLanguage(to: .english))
        XCTAssertEqual(form.draft, Configuration(language: .simplifiedChinese))
        XCTAssertEqual(sink.configuration, Configuration(language: .simplifiedChinese))
        XCTAssertNotNil(form.error)
        XCTAssertEqual(sink.keyWrites, 0)
        sink.fail = false
        XCTAssertTrue(form.changeLanguage(to: .english))
        XCTAssertEqual(sink.writes, 1)
        XCTAssertEqual(sink.keyWrites, 0)
        await fulfillment(of: [keySaved], timeout: 2)
        XCTAssertEqual(sink.keyWrites, 1)
        XCTAssertEqual(sink.writes, 2)
        XCTAssertEqual(sink.configuration.language, .english)
    }

    @MainActor func testEnglishRecoveryUsesEnglishDefaultsAndAvoidsShortcutCollision() {
        var configuration = Configuration(language: .simplifiedChinese); configuration.language = .english
        configuration.presets = [Preset(name: "Custom", prompt: "Custom", shortcut: Preset.defaults[0].shortcut)]
        let sink = LanguageSink(configuration); let form = sink.editor()
        XCTAssertEqual(form.restoreDefaultPresets().count, Preset.defaults.count)
        XCTAssertEqual(Array(form.draft.presets.suffix(Preset.defaults.count)).map(\.name), Preset.defaults(for: .english).map(\.name))
        XCTAssertEqual(Array(form.draft.presets.suffix(Preset.defaults.count)).map(\.prompt), Preset.defaults(for: .english).map(\.prompt))
        XCTAssertNoThrow(try form.draft.validate())
        XCTAssertTrue(form.restoreDefaultPresets().isEmpty)
    }

    @MainActor func testInvalidDraftRejectsLanguageSwitchWithoutPartialReplacement() {
        let sink = LanguageSink(); let form = sink.editor()
        form.draft.model = ""
        let before = form.draft
        XCTAssertFalse(form.changeLanguage(to: .english))
        XCTAssertEqual(form.draft, before)
        XCTAssertEqual(sink.configuration, Configuration(language: .simplifiedChinese))
        XCTAssertEqual(sink.writes, 0)
    }
}
