import Foundation

public struct Shortcut: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String
    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public var identity: String { "\(keyCode):\(modifiers)" }
}

public struct Preset: Codable, Identifiable, Equatable {
    public enum BuiltIn: String, Codable { case translate, explain, summarize, visualize, assistant }
    public var id: UUID
    public var name: String
    public var prompt: String
    public var shortcut: Shortcut
    /// Retains a default preset's identity even after its name, prompt, or shortcut is edited.
    public var builtIn: BuiltIn?
    public init(id: UUID = UUID(), name: String, prompt: String, shortcut: Shortcut, builtIn: BuiltIn? = nil) {
        self.id = id; self.name = name; self.prompt = prompt; self.shortcut = shortcut; self.builtIn = builtIn
    }
    private enum CodingKeys: String, CodingKey { case id, name, prompt, shortcut, builtIn }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        prompt = try values.decode(String.self, forKey: .prompt)
        shortcut = try values.decode(Shortcut.self, forKey: .shortcut)
        builtIn = try values.decodeIfPresent(BuiltIn.self, forKey: .builtIn)
    }
    public static let defaults: [Preset] = defaults(for: .simplifiedChinese)

    public static func defaults(for language: AppLanguage) -> [Preset] {
        let singleTurn = L10n.string("preset.singleTurn", language: language)
        return [
            Preset(id: UUID(uuidString: "B16BA900-0000-4000-8000-000000000001")!,
                   name: L10n.string("preset.translate.name", language: language),
                   prompt: singleTurn + "\n\n" + L10n.string("preset.translate.instructions", language: language),
                   shortcut: .init(keyCode: 18, modifiers: 6144, label: "⌃⌥1"), builtIn: .translate),
            Preset(id: UUID(uuidString: "B16BA900-0000-4000-8000-000000000002")!,
                   name: L10n.string("preset.explain.name", language: language),
                   prompt: singleTurn + "\n\n" + L10n.string("preset.explain.instructions", language: language),
                   shortcut: .init(keyCode: 19, modifiers: 6144, label: "⌃⌥2"), builtIn: .explain),
            Preset(id: UUID(uuidString: "B16BA900-0000-4000-8000-000000000003")!,
                   name: L10n.string("preset.summarize.name", language: language),
                   prompt: singleTurn + "\n\n" + L10n.string("preset.summarize.instructions", language: language),
                   shortcut: .init(keyCode: 20, modifiers: 6144, label: "⌃⌥3"), builtIn: .summarize),
            Preset(id: UUID(uuidString: "B16BA900-0000-4000-8000-000000000004")!,
                   name: L10n.string("preset.visualize.name", language: language),
                   prompt: singleTurn + "\n\n" + L10n.string("preset.visualize.instructions", language: language),
                   shortcut: .init(keyCode: 21, modifiers: 6144, label: "⌃⌥4"), builtIn: .visualize),
            Preset(id: UUID(uuidString: "B16BA900-0000-4000-8000-000000000005")!,
                   name: L10n.string("preset.assistant.name", language: language),
                   prompt: L10n.string("preset.assistant.instructions", language: language),
                   shortcut: .init(keyCode: 23, modifiers: 6144, label: "⌃⌥5"), builtIn: .assistant)
        ]
    }
}

public struct Configuration: Codable, Equatable {
    public var model = "gpt-4.1-mini"
    public var apiBaseURL = "https://api.openai.com/v1"
    public var apiMode: APIMode = .responses
    public var copyFallback = true
    public var language: AppLanguage
    public var presets: [Preset]
    public init(language: AppLanguage = .preferred()) {
        self.language = language
        presets = Preset.defaults(for: language)
    }
    private enum CodingKeys: String, CodingKey { case model, apiBaseURL, apiMode, copyFallback, language, presets }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? model
        apiBaseURL = try values.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? apiBaseURL
        apiMode = try values.decodeIfPresent(APIMode.self, forKey: .apiMode) ?? apiMode
        copyFallback = try values.decodeIfPresent(Bool.self, forKey: .copyFallback) ?? copyFallback
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? language
        presets = try values.decodeIfPresent([Preset].self, forKey: .presets) ?? Preset.defaults(for: language)
    }
    public var requiresAPIKey: Bool { (try? APIEndpoint(apiBaseURL).host.lowercased()) == "api.openai.com" }
    public func validate() throws {
        _ = try APIEndpoint(apiBaseURL)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("请输入模型名称。") }
        guard !presets.isEmpty else { throw ValidationError("至少保留一个预设。") }
        guard Set(presets.map(\.id)).count == presets.count else { throw ValidationError("预设 ID 重复。") }
        guard Set(presets.map { $0.shortcut.identity }).count == presets.count else { throw ValidationError("快捷键重复，请为每个预设设置不同的快捷键。") }
        for preset in presets {
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !preset.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("预设名称和提示词不能为空。") }
            // Carbon: cmdKey=256, optionKey=2048, controlKey=4096, shiftKey=512.
            guard preset.shortcut.modifiers & (256 | 2048 | 4096) != 0 else { throw ValidationError("快捷键至少需要 Command、Option 或 Control 中的一个修饰键。") }
        }
    }
}

public struct ValidationError: LocalizedError {
    public let message: String
    private let format: String?
    private let arguments: [String]
    public init(_ message: String) { self.message = message; format = nil; arguments = [] }
    /// Preserve the Chinese source and arguments so errors can follow a later language change.
    public init(format: String, arguments: [String]) {
        self.format = format; self.arguments = arguments
        message = L10n.formatted(format, arguments: arguments.map { $0 as CVarArg }, language: .simplifiedChinese)
    }
    public var errorDescription: String? {
        guard let format else { return L10n.string(message) }
        return L10n.formatted(format, arguments: arguments.map { $0 as CVarArg }, language: L10n.currentLanguage)
    }
}

public enum APIMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case responses
    case chatCompletions
    public var id: String { rawValue }
    public var title: String { self == .responses ? "Responses" : "Chat Completions" }
    public var route: String { self == .responses ? "/responses" : "/chat/completions" }
}

/// A base URL, including the provider's API prefix; never a complete operation URL.
public struct APIEndpoint: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public let basePath: String
    public let normalizedURL: String
    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.url != nil else {
            throw ValidationError("API 端点需为完整的 HTTP(S) 基础地址，例如 https://api.openai.com/v1；不要包含账号、查询参数或片段。")
        }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw ValidationError("API 端点端口无效。") }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.hasSuffix("/responses"), !path.hasSuffix("/chat/completions") else {
            throw ValidationError("请填写 API 基础地址（通常以 /v1 结尾），不要填写 /responses 或 /chat/completions 的完整地址。")
        }
        components.scheme = scheme
        components.path = path
        self.scheme = scheme; self.host = host; self.port = port; self.basePath = path
        normalizedURL = components.string!
    }
}

public struct ModelRequest {
    public let text: String
    public let instructions: String
    public let configuration: Configuration
    public let apiKey: String
    public init(text: String, instructions: String, configuration: Configuration, apiKey: String) {
        self.text = text; self.instructions = instructions; self.configuration = configuration; self.apiKey = apiKey
    }
}

public enum StreamEvent: Equatable, Sendable {
    case delta(String)
    case completed
    case failed(String)
}
