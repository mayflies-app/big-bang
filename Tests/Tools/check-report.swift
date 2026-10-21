import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Report path required") }
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard report?["passed"] as? Bool == true else { throw NSError(domain: "Verification", code: 1) }
    print("Verified: \(CommandLine.arguments[1])")
} catch {
    fputs("Report failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
