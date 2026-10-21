import Foundation
import LocalAuthentication
import Security

// This fixture only accesses uniquely named synthetic items, never application secrets.
#if FIXTURE_V2
let fixtureVersion = 2
#else
let fixtureVersion = 1
#endif

struct Result: Encodable {
    let action: String
    let version: Int
    let status: OSStatus
    let matchesExpected: Bool
}

guard CommandLine.arguments.count == 4 else { exit(64) }
let action = CommandLine.arguments[1]
let service = CommandLine.arguments[2]
let account = CommandLine.arguments[3]
guard service.hasPrefix("app.mayfiles.BigBang.signing-fixture."),
      UUID(uuidString: account) != nil,
      service == "app.mayfiles.BigBang.signing-fixture.\(account)" else { exit(64) }

let fixtureData = Data("public non-secret signing continuity fixture".utf8)
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account
]
// The compatibility bridge also suppresses UI for the traditional keychain.
// Neither setting changes the item's ACL or switches the keychain implementation.
let interactionStatus = FixtureDisableLegacyKeychainInteraction()
let authenticationContext = LAContext()
authenticationContext.interactionNotAllowed = true
query[kSecUseAuthenticationContext as String] = authenticationContext

let status: OSStatus
var matchesExpected = false
if interactionStatus != errSecSuccess {
    status = interactionStatus
} else {
    switch action {
    case "create":
        query[kSecValueData as String] = fixtureData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = SecItemAdd(query as CFDictionary, nil)
    case "read":
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        status = SecItemCopyMatching(query as CFDictionary, &value)
        matchesExpected = status == errSecSuccess && (value as? Data) == fixtureData
    case "delete":
        status = SecItemDelete(query as CFDictionary)
    default:
        exit(64)
    }
}
let result = Result(action: action, version: fixtureVersion,
                    status: status, matchesExpected: matchesExpected)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
guard let output = try? encoder.encode(result),
      let line = String(data: output, encoding: .utf8) else { exit(70) }
print(line)
if action == "delete" && status == errSecItemNotFound { exit(0) }
exit(status == errSecSuccess && (action != "read" || matchesExpected) ? 0 : 1)
