import Foundation
import Security

@MainActor
final class BackendSettings: ObservableObject {
    nonisolated static let defaultBackendURL = "https://ai-glasses-for-research.fly.dev"
    nonisolated static let backendURLKey = "research.backendURL"

    @Published var backendURL: String {
        didSet { defaults.set(backendURL, forKey: Self.backendURLKey) }
    }

    @Published var trialToken: String {
        didSet {
            do {
                try keychain.set(trialToken)
                tokenError = nil
            } catch {
                tokenError = error.localizedDescription
            }
        }
    }

    @Published private(set) var tokenError: String?

    private let defaults: UserDefaults
    private let keychain: TrialTokenKeychain

    init(
        defaults: UserDefaults = .standard,
        keychain: TrialTokenKeychain = TrialTokenKeychain()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        backendURL = defaults.string(forKey: Self.backendURLKey) ?? Self.defaultBackendURL
        do {
            trialToken = try keychain.read() ?? ""
        } catch {
            trialToken = ""
            tokenError = error.localizedDescription
        }
    }

    var normalizedBaseURL: URL? {
        BackendEndpoint.baseURL(from: backendURL)
    }
}

enum BackendEndpoint {
    static func baseURL(from value: String) -> URL? {
        var input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if !input.contains("://") {
            input = "https://\(input)"
        }
        guard var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.url
    }

    static func httpURL(base: URL, path: String) -> URL? {
        append(path: path, to: base, websocket: false)
    }

    static func webSocketURL(base: URL, path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard let url = append(path: path, to: base, websocket: true),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private static func append(path: String, to base: URL, websocket: Bool) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if websocket {
            components.scheme = components.scheme == "https" ? "wss" : "ws"
        }
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (components.path.isEmpty ? "" : "/\(components.path)") + suffix
        return components.url
    }
}

struct TrialTokenKeychain {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "AIGlassesLink",
        account: String = "trial-token"
    ) {
        self.service = service
        self.account = account
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(updateStatus) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    init(_ status: OSStatus) {
        self.status = status
    }

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
