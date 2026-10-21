import Foundation
import OpenAI
import BigBangCore

enum ModelProtocolFailure: Error { case failed }

/// Only protocol semantics live here; framing, HTTP, cancellation and byte budgets are shared.
enum ProtocolStreamDecoder {
    static func events(from event: SSEEvent, mode: APIMode, language: AppLanguage) throws -> [StreamEvent] {
        // Preserve empty SSE keepalives; they carry no protocol JSON or completion evidence.
        if event.data.isEmpty { return [] }
        if String(data: event.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return [] }
        switch mode {
        case .responses: return try responses(event.data)
        case .chatCompletions: return try chat(event, language: language)
        }
    }

    private struct ResponseType: Decodable { let type: String }
    private struct TextDelta: Decodable { let delta: String }

    private static func responses(_ data: Data) throws -> [StreamEvent] {
        switch try JSONDecoder().decode(ResponseType.self, from: data).type {
        case "response.output_text.delta", "response.refusal.delta":
            let text = try JSONDecoder().decode(TextDelta.self, from: data).delta
            return text.isEmpty ? [] : [.delta(text)]
        case "response.completed":
            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = event["response"] as? [String: Any] else { throw SSETransportFailure.invalidEvent }
            if let status = response["status"] as? String, status != "completed" { throw ModelProtocolFailure.failed }
            if let error = response["error"], !(error is NSNull) { throw ModelProtocolFailure.failed }
            return [.completed]
        case "response.failed", "response.incomplete", "error": throw ModelProtocolFailure.failed
        default: return [] // Lifecycle, reasoning, usage and future extensions carry no displayed text.
        }
    }

    private struct ChatChunk: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let index: Int
            let delta: Delta
            let finishReason: String?
            private enum CodingKeys: String, CodingKey { case index, delta; case finishReason = "finish_reason" }
        }
        struct Delta: Decodable { let content: String?; let refusal: String? }
    }

    private static func chat(_ event: SSEEvent, language: AppLanguage) throws -> [StreamEvent] {
        guard event.name == "message" else { throw SSETransportFailure.invalidEvent }
        if let error = try? JSONDecoder().decode(APIErrorResponse.self, from: event.data) { throw error }
        let chunk = try JSONDecoder().decode(ChatChunk.self, from: event.data)
        var events: [StreamEvent] = []
        for choice in chunk.choices where choice.index == 0 {
            if let text = choice.delta.content, !text.isEmpty { events.append(.delta(text)) }
            if let refusal = choice.delta.refusal, !refusal.isEmpty { events.append(.delta(refusal)) }
            if let reason = choice.finishReason {
                if reason == "stop" { events.append(.completed) }
                else {
                    // Keep the former SDK's known reasons, without rendering arbitrary provider strings.
                    guard ["length", "content_filter", "tool_calls", "function_call"].contains(reason) else {
                        throw SSETransportFailure.invalidEvent
                    }
                    events.append(.failed(RuntimeTranslations.message("响应未正常完成（\(reason)），已保留部分结果。", language: language)))
                }
                break
            }
        }
        return events
    }
}
