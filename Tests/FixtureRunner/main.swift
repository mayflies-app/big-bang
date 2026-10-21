import Foundation
import BigBangTestSupport

do {
    let fixture = try SSEFixture()
    if let appIndex = CommandLine.arguments.firstIndex(of: "--app"), CommandLine.arguments.count > appIndex + 1,
       let reportIndex = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > reportIndex + 1 {
        let reportPath = CommandLine.arguments[reportIndex + 1]
        try? FileManager.default.removeItem(atPath: reportPath)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[appIndex + 1])
        let presetSwitch = CommandLine.arguments.contains("--preset-switch-test")
        child.arguments = [presetSwitch ? "--preset-switch-test" : "--integration-test", "--test-base-url", fixture.baseURL, "--report", reportPath]
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 45)
        timer.setEventHandler { if child.isRunning { child.terminate() } }
        try child.run(); timer.resume()
        child.waitUntilExit(); timer.cancel()
        var data = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        if presetSwitch, var report = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let requests = fixture.recordedRequests
            let expected = ["fixture-preset-A", "fixture-preset-B", "fixture-preset-B", "fixture-preset-C", "fixture-preset-B", "fixture-preset-C", "fixture-preset-C", "fixture-preset-A", "fixture-preset-A"]
            var requestChecks: [String: Bool] = [:]
            for (name, route) in [("responses", "/responses"), ("chatCompletions", "/chat/completions")] {
                let modeRequests = requests.filter { $0.path.hasSuffix(route) }
                let input = modeRequests.map { request -> String? in
                    let messages = request.body["messages"] as? [[String: Any]]
                    return request.body["input"] as? String ?? messages?.last?["content"] as? String
                }
                let instructions = modeRequests.map { request -> String? in
                    let messages = request.body["messages"] as? [[String: Any]]
                    return request.body["instructions"] as? String ?? messages?.first?["content"] as? String
                }
                requestChecks[name + ".httpRequestsKeepOriginalInput"] = input.count == expected.count && input.allSatisfy { $0 == "preset-switch-input" }
                requestChecks[name + ".httpInstructionsMatchActions"] = instructions == expected.map(Optional.some)
                report[name + ".recordedHTTPInstructions"] = instructions.map { $0 ?? "<missing>" }
                report[name + ".recordedHTTPRequestCount"] = modeRequests.count
            }
            for (name, passed) in requestChecks { report[name] = passed }
            report["passed"] = report["passed"] as? Bool == true && requestChecks.values.allSatisfy { $0 }
            data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        guard child.terminationStatus == 0,
              let report = try JSONSerialization.jsonObject(with: data) as? [String: Any], report["passed"] as? Bool == true else {
            throw NSError(domain: "Fixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Native integration failed; inspect report"])
        }
        print(String(decoding: data, as: UTF8.self))
    } else if let index = CommandLine.arguments.firstIndex(of: "--ready-file"), CommandLine.arguments.count > index + 1 {
        try fixture.baseURL.write(toFile: CommandLine.arguments[index + 1], atomically: true, encoding: .utf8)
        RunLoop.current.run()
    } else {
        throw NSError(domain: "Fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "--app/--report or --ready-file required"])
    }
    fixture.stop()
} catch {
    fputs("Fixture: \(error.localizedDescription)\n", stderr)
    exit(1)
}
