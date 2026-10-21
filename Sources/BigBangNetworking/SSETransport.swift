import Foundation

struct SSEEvent: Sendable {
    let name: String
    let data: Data
}

enum SSETransportFailure: Error {
    case invalidEvent, interrupted
    case http(status: Int, code: String?)
}

/// Both API protocols share request isolation, bounded framing, and cancellation semantics.
enum SSETransport {
    static let maxLineBytes = 2_000_000
    static let maxEventBytes = 2_000_000
    static let maxErrorBodyBytes = 65_536

    static func start(_ request: URLRequest,
                      onEvent: @escaping @Sendable (SSEEvent) throws -> Bool,
                      onFailure: @escaping @Sendable (Error) -> Void) -> SSETransportRequest {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let delegate = SSETransportDelegate(onEvent: onEvent, onFailure: onFailure)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        var isolatedRequest = request
        isolatedRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: isolatedRequest)
        // No cancellation handle escapes until task creation and delegate ownership are complete.
        delegate.register(session: session, task: task)
        let handle = SSETransportRequest(task: task)
        task.resume()
        return handle
    }
}

/// URLSessionTask.cancel is thread safe and never invalidates a session during task creation.
final class SSETransportRequest: @unchecked Sendable {
    private let task: URLSessionDataTask

    fileprivate init(task: URLSessionDataTask) { self.task = task }

    func cancel() { task.cancel() }
}

/// All mutable state after register is confined to this request's serial delegate queue.
private final class SSETransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onEvent: @Sendable (SSEEvent) throws -> Bool
    private let onFailure: @Sendable (Error) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var parser = SSEFrameParser()
    private var status: Int?
    private var errorBody = Data()
    private var terminal = false

    init(onEvent: @escaping @Sendable (SSEEvent) throws -> Bool,
         onFailure: @escaping @Sendable (Error) -> Void) {
        self.onEvent = onEvent
        self.onFailure = onFailure
    }

    func register(session: URLSession, task: URLSessionDataTask) {
        self.session = session
        self.task = task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !terminal else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse else {
            fail(SSETransportFailure.invalidEvent)
            completionHandler(.cancel)
            return
        }
        status = response.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !terminal, let status else { return }
        guard (200..<300).contains(status) else {
            guard data.count <= SSETransport.maxErrorBodyBytes - errorBody.count else {
                // A truncated error body cannot be trusted for classification; keep only HTTP status.
                fail(SSETransportFailure.http(status: status, code: nil))
                return
            }
            errorBody.append(data)
            return
        }
        do {
            if try parser.append(data, receive: onEvent) {
                terminal = true
                // Protocol completion need not wait for a provider to close its connection.
                task?.cancel()
            }
        } catch {
            fail(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            // Task creation is already complete. Invalidation here releases the session's delegate.
            self.session?.finishTasksAndInvalidate()
            self.task = nil
            self.session = nil
        }
        guard !terminal else { return }
        if let status, !(200..<300).contains(status) {
            fail(SSETransportFailure.http(status: status, code: Self.safeErrorCode(errorBody)))
        } else {
            // Do not flush unfinished SSE lines/events on EOF, or infer protocol completion from it.
            fail(error ?? SSETransportFailure.interrupted)
        }
    }

    private func fail(_ error: Error) {
        guard !terminal else { return }
        terminal = true
        task?.cancel()
        onFailure(error)
    }

    private static func safeErrorCode(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        let allowed = ["invalid_api_key", "authentication_error", "insufficient_quota",
                       "rate_limit_exceeded", "model_not_found"]
        for field in ["code", "type"] {
            if let code = error[field] as? String, allowed.contains(code) { return code }
        }
        return nil
    }
}

/// Iterate each incoming chunk once; buffers never shift their contents one byte at a time.
private struct SSEFrameParser {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let dataPrefix: [UInt8] = [100, 97, 116, 97, 58] // data:
    private var line = Data()
    private var data = Data()
    private var eventName = "message"
    private var hasData = false
    private var firstLine = true
    private var skipLF = false
    private var dataValueOffset: Int?

    mutating func append(_ chunk: Data, receive: (SSEEvent) throws -> Bool) throws -> Bool {
        for byte in chunk {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                skipLF = byte == 13
                if let event = try finishLine(), try receive(event) { return true }
                continue
            }
            guard line.count < SSETransport.maxLineBytes else { throw SSETransportFailure.invalidEvent }
            line.append(byte)
            if line.count == 5 || (firstLine && line.count == 8) {
                let prefixSize = firstLine && line.starts(with: Self.bom) ? 3 : 0
                if line.count == prefixSize + 5, line.suffix(5).elementsEqual(Self.dataPrefix) {
                    dataValueOffset = line.count
                }
            }
            if let offset = dataValueOffset {
                let valueOffset = line.count > offset && line[offset] == 32 ? offset + 1 : offset
                let pendingCount = line.count - valueOffset
                // Count a pending data line before its newline or event's blank line arrives.
                guard data.count + (hasData ? 1 : 0) + pendingCount <= SSETransport.maxEventBytes else {
                    throw SSETransportFailure.invalidEvent
                }
            }
        }
        return false
    }

    private mutating func finishLine() throws -> SSEEvent? {
        let start = firstLine && line.starts(with: Self.bom) ? 3 : 0
        firstLine = false
        defer {
            line.removeAll(keepingCapacity: true)
            dataValueOffset = nil
        }
        if line.count == start { return try dispatch() }
        if line[start] == 58 { return nil } // Comment.
        let separator = line[start...].firstIndex(of: 58)
        let fieldEnd = separator ?? line.endIndex
        var valueStart = separator.map { $0 + 1 } ?? line.endIndex
        if valueStart < line.endIndex, line[valueStart] == 32 { valueStart += 1 }
        let field = line[start..<fieldEnd]
        if field.elementsEqual([100, 97, 116, 97]) { // data
            let value = line[valueStart...]
            guard data.count + (hasData ? 1 : 0) + value.count <= SSETransport.maxEventBytes else {
                throw SSETransportFailure.invalidEvent
            }
            if hasData { data.append(10) }
            data.append(contentsOf: value)
            hasData = true
        } else if field.elementsEqual([101, 118, 101, 110, 116]) { // event
            guard let name = String(data: line[valueStart...], encoding: .utf8) else {
                throw SSETransportFailure.invalidEvent
            }
            eventName = name
        }
        // id, retry and unknown metadata are intentionally ignored.
        return nil
    }

    private mutating func dispatch() throws -> SSEEvent? {
        let name = eventName.isEmpty ? "message" : eventName
        eventName = "message"
        guard hasData else { return nil }
        guard String(data: data, encoding: .utf8) != nil else { throw SSETransportFailure.invalidEvent }
        let event = SSEEvent(name: name, data: data)
        data = Data()
        hasData = false
        return event
    }
}
