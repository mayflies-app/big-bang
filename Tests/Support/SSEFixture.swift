import Foundation
import Network

public struct RecordedRequest {
    public let path: String
    public let headers: [String: String]
    public let body: [String: Any]
}

/// Real, numerically bound loopback HTTP/SSE server for SDK and packaged UI tests.
public final class SSEFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BigBang.fixture")
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var requests: [RecordedRequest] = []
    private var peerDisconnections: [RecordedRequest] = []
    private var serverClosedConnections: Set<ObjectIdentifier> = []
    private var monitoredConnections: Set<ObjectIdentifier> = []
    public let transportCookieName = "BigBangFixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    public private(set) var port: UInt16 = 0
    public var baseURL: String { "http://127.0.0.1:\(port)/proxy/openai/v1" }
    public var recordedRequests: [RecordedRequest] { queue.sync { requests } }
    /// Requests for which the client closed its side while the fixture kept the response open.
    public var recordedPeerDisconnections: [RecordedRequest] { queue.sync { peerDisconnections } }

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID(); self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.connections.removeValue(forKey: id)
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, case .ready = listener.state,
              let boundPort = listener.port, boundPort.rawValue != 0 else {
            let state = listener.state
            listener.cancel(); throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Loopback server did not start: \(state)"])
        }
        port = boundPort.rawValue
    }
    public func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections.values {
                if monitoredConnections.contains(ObjectIdentifier(connection)) {
                    serverClosedConnections.insert(ObjectIdentifier(connection))
                }
                connection.cancel()
            }
            connections.removeAll()
        }
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer; buffer.append(data ?? Data())
            guard buffer.count < 1_000_000, error == nil else { connection.cancel(); return }
            if let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
               let head = String(data: buffer.prefix(upTo: separator.lowerBound), encoding: .utf8) {
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let bodyData = buffer.suffix(from: separator.upperBound)
                if bodyData.count >= length {
                    guard let body = (try? JSONSerialization.jsonObject(with: bodyData.prefix(length))) as? [String: Any],
                          let path = lines.first?.split(separator: " ").dropFirst().first else { connection.cancel(); return }
                    let request = RecordedRequest(path: String(path), headers: headers, body: body)
                    self.requests.append(request)
                    self.respond(connection, request: request)
                    return
                }
            }
            if done { connection.cancel() } else { self.read(connection, buffer: buffer) }
        }
    }
    private func respond(_ connection: NWConnection, request: RecordedRequest) {
        let isChat = request.path.hasSuffix("/chat/completions")
        let messages = request.body["messages"] as? [[String: Any]]
        let scenario = request.body["input"] as? String ?? messages?.last?["content"] as? String ?? "success"
        if scenario.hasPrefix("transport-") {
            monitorPeer(connection, request: request)
            respondTransport(connection, scenario: scenario, chat: isChat)
            return
        }
        let status: Int?
        switch scenario { case "unauthorized", "plain401": status = 401; case "missing": status = 404; case "rate": status = 429; default: status = nil }
        if let status {
            let body = scenario == "plain401" ? "invalid credentials" : "{\"error\":{\"message\":\"never expose local-test-key\",\"type\":\"api_error\",\"code\":\"\(status == 401 ? "invalid_api_key" : status == 404 ? "model_not_found" : "rate_limit_exceeded")\"}}"
            send(connection, data: Data("HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8), final: true)
            return
        }
        send(connection, data: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8))
        if scenario == "invalid-json" { send(connection, data: Data("data: {broken}\n\n".utf8), final: true); return }
        if !isChat && scenario.hasPrefix("responses-") {
            respondCompatibleResponses(connection, scenario: scenario)
            return
        }
        let instructions = request.body["instructions"] as? String ?? messages?.first?["content"] as? String ?? ""
        if scenario == "preset-switch-input", ["fixture-preset-A", "fixture-preset-B", "fixture-preset-C"].contains(instructions) {
            let name = String(instructions.suffix(1))
            send(connection, data: delta(name + " first", chat: isChat, sequence: 1))
            let delay = name == "A" ? 0.9 : name == "C" ? 0.45 : 0.2
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.send(connection, data: self.delta("\n" + name + " complete", chat: isChat, sequence: 2))
                self.send(connection, data: self.terminal(chat: isChat, incomplete: false), final: true)
            }
            return
        }
        if scenario == "cancel" {
            for index in 0..<100 {
                queue.asyncAfter(deadline: .now() + Double(index) * 0.1) { [weak self] in
                    self?.send(connection, data: self?.delta("生成中 ", chat: isChat, sequence: index) ?? Data())
                }
            }
            return
        }
        let firstText = scenario == "truncated" || scenario == "incomplete" ? "部分结果" : scenario == "refusal" ? "无法协助" : "你好 🌍"
        let first = delta(firstText, chat: isChat, sequence: 1, refusal: scenario == "refusal")
        // Split a real four-byte emoji in the middle of its UTF-8 encoding.
        let split = first.range(of: Data("🌍".utf8)).map { $0.lowerBound + 2 } ?? first.count / 2
        send(connection, data: first.prefix(split))
        queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.send(connection, data: first.suffix(from: split), final: scenario == "truncated")
        }
        guard scenario != "truncated" else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if scenario != "refusal" && scenario != "incomplete" { self.send(connection, data: self.delta("\n流式完成", chat: isChat, sequence: 2)) }
            self.send(connection, data: self.terminal(chat: isChat, incomplete: scenario == "incomplete"), final: true)
        }
    }
    /// These scenarios never close the response unless stated explicitly. A failure/cancel test
    /// therefore proves client termination rather than a fixture-generated EOF.
    private func monitorPeer(_ connection: NWConnection, request: RecordedRequest) {
        monitoredConnections.insert(ObjectIdentifier(connection))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            guard let self else { return }
            if done || error != nil {
                self.monitoredConnections.remove(ObjectIdentifier(connection))
                if self.serverClosedConnections.remove(ObjectIdentifier(connection)) == nil {
                    self.peerDisconnections.append(request)
                }
                connection.cancel()
            } else {
                self.monitorPeer(connection, request: request)
            }
        }
    }

    private func respondTransport(_ connection: NWConnection, scenario: String, chat: Bool) {
        if scenario == "transport-waiting-headers" { return }
        if scenario.hasPrefix("transport-error-large-") {
            let status = Int(scenario.split(separator: "-").last!)!
            send(connection, data: Data("HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".utf8))
            // Deliberately incomplete JSON, larger than the error-body budget, with no EOF.
            sendHeld(connection, data: Data(("{\"error\":\"provider-private-payload local-test-key " + String(repeating: "x", count: 150_000)).utf8))
            return
        }
        let cookie = scenario == "transport-cookie-set" ? "Set-Cookie: \(transportCookieName)=private; Path=/proxy/openai/v1\r\n" : ""
        send(connection, data: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\(cookie)Connection: close\r\n\r\n".utf8))
        if scenario == "transport-silent" || scenario == "transport-delayed" {
            send(connection, data: delta("first", chat: chat, sequence: 1))
            if scenario == "transport-delayed" {
                queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.send(connection, data: self.delta("stale", chat: chat, sequence: 2))
                    self.send(connection, data: self.terminal(chat: chat, incomplete: false), final: true)
                }
            }
            return
        }
        if scenario == "transport-unfinished-line" {
            sendHeld(connection, data: Data(("data: provider-private-payload local-test-key " + String(repeating: "x", count: 2_010_000)).utf8))
            return
        }
        if scenario == "transport-unfinished-event" {
            let line = "data: " + String(repeating: "x", count: 10_000) + "\n"
            sendHeld(connection, data: Data(("data: provider-private-payload local-test-key\n" + String(repeating: line, count: 201)).utf8))
            return
        }
        if scenario == "transport-near-limit" {
            let object: [String: Any] = chat
                ? ["id": "chatcmpl_test", "object": "chat.completion.chunk", "created": 1, "model": "test-model", "choices": [["index": 0, "delta": ["content": "near-limit"], "finish_reason": NSNull()]], "padding": String(repeating: "x", count: 1_998_000)]
                : ["type": "response.output_text.delta", "delta": "near-limit", "padding": String(repeating: "x", count: 1_998_000)]
            send(connection, data: sse(object, named: !chat))
            send(connection, data: terminal(chat: chat, incomplete: false), final: true)
            return
        }
        let newline = scenario == "transport-lines-cr" ? "\r" : scenario == "transport-lines-crlf" ? "\r\n" : "\n"
        if scenario == "transport-framing" {
            let text = String(decoding: delta("你好 🌍", chat: chat, sequence: 1), as: UTF8.self)
            // JSON whitespace may cross SSE data lines. Split at a comma, outside strings.
            let splitAt = text.firstIndex(of: ",")!
            let multiline = String(text[...splitAt]) + "\ndata: " + String(text[text.index(after: splitAt)...])
            let framed = Data(("\u{FEFF}: keepalive\nid: test\nretry: 1000\n" + multiline).utf8)
            let emojiSplit = framed.range(of: Data("🌍".utf8))!.lowerBound + 2
            send(connection, data: framed.prefix(1))
            queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                guard let self else { return }
                self.send(connection, data: framed[1..<emojiSplit])
                self.queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    guard let self else { return }
                    self.send(connection, data: framed.suffix(from: emojiSplit))
                    self.send(connection, data: self.terminal(chat: chat, incomplete: false), final: true)
                }
            }
            return
        }
        if scenario == "transport-empty-data" {
            send(connection, data: Data("data:\n\n".utf8))
        }
        var bytes = delta("你好 🌍", chat: chat, sequence: 1)
        bytes.append(terminal(chat: chat, incomplete: false))
        let framed = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\n", with: newline)
        send(connection, data: Data(framed.utf8), final: scenario != "transport-terminal-held")
    }

    /// Send bounded chunks without a terminal EOF; the peer monitor records early rejection.
    private func sendHeld(_ connection: NWConnection, data: Data, offset: Int = 0) {
        guard offset < data.count, case .ready = connection.state else { return }
        let end = min(offset + 65_536, data.count)
        connection.send(content: data[offset..<end], completion: .contentProcessed { [weak self] error in
            guard error == nil else { return }
            self?.sendHeld(connection, data: data, offset: end)
        })
    }

    /// Deliberately thin provider events: text consumers must not require unrelated SDK fields.
    private func respondCompatibleResponses(_ connection: NWConnection, scenario: String) {
        func response(_ status: String, output: [[String: Any]] = []) -> [String: Any] {
            var body: [String: Any] = ["id": "resp_gateway", "object": "response", "created_at": 1,
                                       "model": "test-model", "status": status, "output": output]
            if scenario == "responses-lifecycle" {
                body["parallel_tool_calls"] = false
                body["tool_choice"] = "auto"
                body["tools"] = []
                // Observed Vercel lifecycle shape: cached_tokens is present but cache_write_tokens is absent.
                // The SDK requires the latter, so even response.created fails before any text is consumed.
                body["usage"] = ["input_tokens": 10, "output_tokens": 2, "total_tokens": 12,
                                 "input_tokens_details": ["cached_tokens": 0],
                                 "output_tokens_details": ["reasoning_tokens": 0]] as [String: Any]
            }
            return body
        }
        func event(_ type: String, _ fields: [String: Any] = [:]) -> Data {
            sse(fields.merging(["type": type]) { _, type in type }, named: true)
        }
        let completion = event("response.completed", ["response": response("completed", output: [
            ["id": NSNull(), "type": "reasoning", "summary": [["type": "summary_text", "text": "private reasoning"]]],
            ["id": "msg_gateway", "type": "message", "role": "assistant", "status": "completed",
             "content": [["type": "output_text", "text": "你好 🌍\n流式完成", "annotations": []]]]
        ])])
        if scenario == "responses-cancel" {
            send(connection, data: event("response.output_text.delta", ["delta": "生成中 "]))
            let oldDelta = event("response.output_text.delta", ["delta": "旧请求尾部"])
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.send(connection, data: oldDelta)
                self.send(connection, data: completion, final: true)
            }
            return
        }
        if scenario == "responses-lifecycle" {
            send(connection, data: event("response.created", ["response": response("in_progress")]))
            send(connection, data: event("response.in_progress", ["response": response("in_progress")]))
            send(connection, data: event("response.output_item.added", ["output_index": 0,
                 "item": ["id": NSNull(), "type": "reasoning", "summary": []]]))
            send(connection, data: event("response.reasoning.delta", ["delta": "private reasoning"]))
            send(connection, data: event("response.gateway_metadata", ["gateway": ["version": 1]]))
        }
        let first = event(scenario == "responses-refusal" ? "response.refusal.delta" : "response.output_text.delta",
                          ["delta": scenario == "responses-refusal" ? "无法协助" : "你好 🌍"])
        if scenario == "responses-framing" {
            // SSE joins data lines with LF; comments and transport metadata carry no model text.
            let framed = ": keepalive\r\nid: gateway-1\r\nretry: 1000\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\r\ndata: \"delta\":\"你好 🌍\"}\r\n\r\n"
            let bytes = Data(framed.utf8)
            let split = bytes.range(of: Data("🌍".utf8))!.lowerBound + 2
            let nextDelta = event("response.output_text.delta", ["delta": "\n流式完成", "output_index": 1, "content_index": 0])
            send(connection, data: bytes.prefix(split))
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                self.send(connection, data: bytes.suffix(from: split))
                self.send(connection, data: nextDelta)
                self.send(connection, data: completion, final: true)
            }
            return
        }
        send(connection, data: first, final: scenario == "responses-truncated")
        if scenario == "responses-truncated" { return }
        let tail: Data
        switch scenario {
        case "responses-failed", "responses-incomplete":
            let status = scenario == "responses-failed" ? "failed" : "incomplete"
            var body = response(status)
            body["error"] = ["code": "server_error", "message": "never expose provider-private-payload local-test-key"]
            tail = event("response.\(status)", ["response": body]) + completion
        case "responses-error":
            tail = event("error", ["code": "server_error", "message": "never expose provider-private-payload local-test-key"]) + completion
        case "responses-done-only": tail = Data("data: [DONE]\n\n".utf8)
        case "responses-malformed": tail = Data("data: {broken}\n\n".utf8) + completion
        case "responses-missing-delta": tail = event("response.output_text.delta") + completion
        case "responses-nonstring-delta": tail = event("response.output_text.delta", ["delta": 42]) + completion
        case "responses-missing-type": tail = sse(["delta": "invalid event"]) + completion
        case "responses-refusal": tail = completion
        default:
            var result = event("response.output_text.delta", ["delta": "\n流式完成", "output_index": 1, "content_index": 0])
            result.append(completion)
            tail = result
        }
        send(connection, data: tail, final: true)
    }
    private func delta(_ text: String, chat: Bool, sequence: Int, refusal: Bool = false) -> Data {
        if chat {
            return sse(["id": "chatcmpl_test", "object": "chat.completion.chunk", "created": 1, "model": "test-model",
                        "choices": [["index": 0, "delta": [refusal ? "refusal" : "content": text], "finish_reason": NSNull()]]])
        }
        return sse(["type": refusal ? "response.refusal.delta" : "response.output_text.delta", "delta": text,
                    "item_id": "msg_test", "content_index": 0, "output_index": 0, "sequence_number": sequence, "logprobs": []], named: true)
    }
    private func terminal(chat: Bool, incomplete: Bool) -> Data {
        if chat {
            var result = sse(["id": "chatcmpl_test", "object": "chat.completion.chunk", "created": 1, "model": "test-model",
                              "choices": [["index": 0, "delta": [:], "finish_reason": incomplete ? "length" : "stop"]]])
            result.append(Data("data: [DONE]\n\n".utf8)); return result
        }
        return sse(["type": incomplete ? "response.incomplete" : "response.completed", "sequence_number": 3,
                    "response": ["id": "resp_test", "created_at": 1, "object": "response", "model": "test-model", "output": [],
                                 "parallel_tool_calls": false, "tool_choice": "auto", "tools": [], "status": incomplete ? "incomplete" : "completed"]], named: true)
    }
    private func sse(_ object: [String: Any], named: Bool = false) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        var data = Data((named ? "event: \(object["type"]!)\n" : "").utf8)
        data.append(Data("data: ".utf8)); data.append(json); data.append(Data("\n\n".utf8)); return data
    }
    private func send(_ connection: NWConnection, data: Data, final: Bool = false) {
        guard case .ready = connection.state else { return }
        if final, monitoredConnections.contains(ObjectIdentifier(connection)) {
            serverClosedConnections.insert(ObjectIdentifier(connection))
        }
        connection.send(content: data, isComplete: final, completion: .contentProcessed { error in
            if error != nil || final { connection.cancel() }
        })
    }
}
