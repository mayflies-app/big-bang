import AppKit
import BigBangCore
import BigBangNetworking
import OpenAI
import Security

/// Explicit, signed Release-only diagnostic. Never persists credentials, response text, or provider errors.
@MainActor enum LiveAPIDiagnostic {
    private static let text = "API connectivity check."
    private static let instructions = "Reply with exactly BIG_BANG_API_PROBE."
    private static let expected = "BIG_BANG_API_PROBE"

    static func run(configuration: Configuration) async {
        defer { NSApp.terminate(nil) }
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--report"), arguments.count > index + 1,
              NSString(string: arguments[index + 1]).isAbsolutePath else { return }
        let reportURL = URL(fileURLWithPath: arguments[index + 1])
        var report: [String: Any] = ["schemaVersion": 1]
        do {
            guard signedRelease() else { throw DiagnosticFailure.unsignedOrDebug }
            report["developerIDRelease"] = true
            try configuration.validate()
            let key = try Keychain.read()
            guard !key.isEmpty else { throw DiagnosticFailure.missingKey }
            for mode in APIMode.allCases {
                var selected = configuration; selected.apiMode = mode
                report[mode.rawValue] = await Probe().run(configuration: selected, key: key)
            }
            report["responsesWireShape"] = await wireShape(configuration: configuration, key: key)
        } catch let error as DiagnosticFailure {
            report["failure"] = error.rawValue
        } catch {
            report["failure"] = "configurationOrKeychainFailure"
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    private enum DiagnosticFailure: String, Error { case unsignedOrDebug, missingKey }
    private static func signedRelease() -> Bool {
        #if DEBUG
        return false
        #else
        var code: SecCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"79X3F8NVAV\" and identifier \"app.mayfiles.BigBang\""
        guard Bundle.main.bundleIdentifier == "app.mayfiles.BigBang",
              SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        #endif
    }

    @MainActor private final class Probe {
        let service = ModelStream()
        var continuation: CheckedContinuation<[String: Any], Never>?
        var timeout: Task<Void, Never>?
        var start = Date()
        var deltas = 0
        var output = ""

        func run(configuration: Configuration, key: String) async -> [String: Any] {
            start = Date()
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(60)); finish("failed", reason: "timeout") }
                    catch { }
                }
                do {
                    try service.start(.init(text: text, instructions: instructions, configuration: configuration, apiKey: key)) { [self] event in
                        switch event {
                        case .delta(let value): deltas += 1; output += value
                        case .completed: finish("completed")
                        case .failed: finish("failed", reason: "streamFailure")
                        }
                    }
                } catch { finish("failed", reason: "requestRejected") }
            }
        }
        func finish(_ state: String, reason: String = "") {
            guard let continuation else { return }
            self.continuation = nil; timeout?.cancel(); service.cancel()
            continuation.resume(returning: ["state": state, "reason": reason, "deltaCount": deltas,
                "textLength": output.count, "containsExpectedText": output.contains(expected),
                "elapsedSeconds": Date().timeIntervalSince(start)])
            output = ""
        }
    }

    private static func wireShape(configuration: Configuration, key: String) async -> [String: Any] {
        let started = Date()
        do {
            let endpoint = try APIEndpoint(configuration.apiBaseURL)
            guard let url = URL(string: endpoint.normalizedURL + APIMode.responses.route) else { return ["failure": "invalidURL"] }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["input": text, "instructions": instructions,
                "model": configuration.model, "max_output_tokens": 4096, "store": false, "stream": true])
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 60; settings.timeoutIntervalForResource = 60
            let session = URLSession(configuration: settings)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return ["httpStatus": status] }
            guard data.count <= 2_000_000, let string = String(data: data, encoding: .utf8) else {
                return ["httpStatus": status, "failure": "responseSizeOrEncoding"]
            }
            var events: [[String: Any]] = [], seen = Set<String>(), count = 0
            for line in string.components(separatedBy: .newlines) where line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                guard let bytes = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
                count += 1
                let event = safeEvent(json["type"] as? String)
                guard seen.insert(event).inserted, events.count < 16 else { continue }
                var entry: [String: Any] = ["event": event, "fields": shape(json)]
                do { _ = try JSONDecoder().decode(ResponseStreamEvent.self, from: bytes); entry["sdkDecoded"] = true }
                catch { entry["sdkDecoded"] = false; entry["sdkError"] = decodingFailure(error) }
                events.append(entry)
            }
            return ["httpStatus": status, "eventCount": count, "events": events,
                    "elapsedSeconds": Date().timeIntervalSince(started)]
        } catch { return ["failure": "transportOrRequestFailure", "elapsedSeconds": Date().timeIntervalSince(started)] }
    }

    private static func safeEvent(_ value: String?) -> String {
        let known: Set<String> = ["response.created", "response.in_progress", "response.completed", "response.failed",
            "response.incomplete", "response.queued", "response.output_item.added", "response.output_item.done",
            "response.content_part.added", "response.content_part.done", "response.output_text.delta",
            "response.output_text.done", "response.refusal.delta", "response.refusal.done", "error"]
        return value.flatMap { known.contains($0) ? $0 : nil } ?? "other"
    }
    private static func field(_ value: String) -> String {
        guard value.count <= 64, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_".unicodeScalars.contains($0) }) else { return "<field>" }
        return value
    }
    private static func shape(_ object: Any) -> [String: String] {
        var fields: [String: String] = [:]
        func visit(_ value: Any, path: String, depth: Int) {
            guard depth <= 7, fields.count < 160 else { return }
            if let map = value as? [String: Any] {
                fields[path] = "object"
                for key in map.keys.sorted().prefix(64) { visit(map[key]!, path: path + "." + field(key), depth: depth + 1) }
            } else if let array = value as? [Any] {
                fields[path] = "array"
                for value in array.prefix(2) { visit(value, path: path + "[]", depth: depth + 1) }
            } else if value is NSNull { fields[path] = "null" }
            else if value is String { fields[path] = "string" }
            else if let number = value as? NSNumber { fields[path] = CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number" }
        }
        visit(object, path: "$", depth: 0)
        return fields
    }
    private static func decodingFailure(_ error: Error) -> [String: Any] {
        let kind: String, path: [any CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key, let context): kind = "keyNotFound"; path = context.codingPath + [key]
        case DecodingError.typeMismatch(_, let context): kind = "typeMismatch"; path = context.codingPath
        case DecodingError.valueNotFound(_, let context): kind = "valueNotFound"; path = context.codingPath
        case DecodingError.dataCorrupted(let context): kind = "dataCorrupted"; path = context.codingPath
        default: return ["kind": "otherSDKDecodeFailure"]
        }
        return ["kind": kind, "codingPath": path.prefix(16).map { $0.intValue == nil ? field($0.stringValue) : "[]" }]
    }
}
