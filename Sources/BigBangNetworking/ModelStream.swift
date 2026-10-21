import Foundation
import OpenAI
import BigBangCore

/// One request lifecycle and transport policy; protocol adapters only interpret model events.
@MainActor public final class ModelStream {
    private var request: SSETransportRequest?
    private var session = UUID()
    private var finished = true
    public init() {}

    public func start(_ input: ModelRequest, receive: @escaping @MainActor (StreamEvent) -> Void) throws {
        let language = input.configuration.language
        try input.configuration.validate()
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError("当前没有选中的文本。") }
        guard !input.configuration.requiresAPIKey || !input.apiKey.isEmpty else { throw ValidationError("请先在设置中保存 API Key。") }
        let endpoint = try APIEndpoint(input.configuration.apiBaseURL)
        let urlRequest = try Self.makeRequest(input, endpoint: endpoint)
        cancel()
        let token = UUID(); session = token; finished = false
        let deliver: @Sendable (StreamEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.session == token, !self.finished else { return }
                    switch event {
                    case .completed, .failed:
                        self.finished = true
                        self.request?.cancel(); self.request = nil
                    case .delta: break
                    }
                    receive(event)
                }
            }
        }
        let mode = input.configuration.apiMode
        request = SSETransport.start(urlRequest, onEvent: { event in
            let updates = try ProtocolStreamDecoder.events(from: event, mode: mode, language: language)
            var terminal = false
            for update in updates {
                deliver(update)
                switch update { case .completed, .failed: terminal = true; case .delta: break }
            }
            return terminal
        }, onFailure: { error in
            deliver(.failed(Self.safeErrorMessage(error, language: language)))
        })
    }

    public func cancel() {
        session = UUID(); finished = true
        request?.cancel(); request = nil
    }
    deinit { request?.cancel() }

    private static func makeRequest(_ input: ModelRequest, endpoint: APIEndpoint) throws -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint.normalizedURL + input.configuration.apiMode.route)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !input.apiKey.isEmpty { request.setValue("Bearer " + input.apiKey, forHTTPHeaderField: "Authorization") }
        switch input.configuration.apiMode {
        case .responses:
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "input": input.text, "instructions": input.instructions, "model": input.configuration.model,
                "max_output_tokens": 4096, "store": false, "stream": true
            ])
        case .chatCompletions:
            let messages: [ChatQuery.ChatCompletionMessageParam] = [
                .system(.init(content: .textContent(input.instructions))),
                .user(.init(content: .string(input.text)))
            ]
            request.httpBody = try JSONEncoder().encode(ChatQuery(messages: messages, model: input.configuration.model, stream: true))
        }
        return request
    }

    nonisolated private static func safeErrorMessage(_ error: Error, language: AppLanguage) -> String {
        RuntimeTranslations.message(canonicalErrorMessage(error), language: language)
    }

    nonisolated private static func canonicalErrorMessage(_ error: Error) -> String {
        // Provider messages and arbitrary finish reasons may contain source text or credentials.
        if error is ModelProtocolFailure { return "模型响应失败或达到输出限制，可保留已有内容并重试。" }
        if let failure = error as? SSETransportFailure {
            switch failure {
            case .invalidEvent: return "无法解析模型响应，请确认端点支持所选接口类型。"
            case .interrupted: return "连接中断，未收到完成事件。可保留已有内容并重试。"
            case .http(let status, let code): return code.flatMap(providerErrorMessage) ?? httpErrorMessage(status)
            }
        }
        if let response = error as? APIErrorResponse {
            return providerErrorMessage(response.error.code ?? response.error.type)
                ?? "API 请求失败，请检查端点、接口类型、模型和 API Key。"
        }
        if error is DecodingError { return "无法解析模型响应，请确认端点支持所选接口类型。" }
        return "请求失败，请检查网络、API 端点与服务状态后重试。"
    }

    nonisolated private static func providerErrorMessage(_ code: String) -> String? {
        switch code {
        case "invalid_api_key", "authentication_error": return "API Key 无效，请检查设置。"
        case "insufficient_quota", "rate_limit_exceeded": return "额度不足或请求过于频繁，请稍后重试。"
        case "model_not_found": return "模型不存在或不可用，请修改模型名称。"
        default: return nil
        }
    }

    nonisolated private static func httpErrorMessage(_ status: Int) -> String {
        switch status {
        case 401: return "API Key 无效，请检查设置。"
        case 403: return "API Key 无权访问当前端点或模型。"
        case 404: return "接口或模型不存在，请检查 API 基础地址、接口类型和模型。"
        case 429: return "额度不足或请求过于频繁，请稍后重试。"
        default: return "API 请求失败（HTTP \(status)），请检查服务状态。"
        }
    }
}
