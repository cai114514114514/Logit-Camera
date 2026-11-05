import Foundation
import Security

enum AICredentials {
    static let model = "deepseek-flash"
    static let displayName = "DeepSeek V4.1 Flash"
    private static let service = "com.logitcamera.deepseek"
    private static let account = "api-key"

    static func load() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AIError.message("请输入 API 密钥。") }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status) }
    }

    static func remove() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }

    static func importDevelopmentKey() throws {
        #if DEBUG
        let directory = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("DeepSeekBootstrap.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let value = try JSONDecoder().decode(Bootstrap.self, from: Data(contentsOf: url))
        try save(value.apiKey)
        // The temporary private-container file is removed after Keychain import.
        try FileManager.default.removeItem(at: url)
        #endif
    }

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private struct Bootstrap: Decodable { let apiKey: String }
    private struct KeychainError: LocalizedError {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
        var errorDescription: String? { "无法访问本机密钥，请解锁手机后重试（\(status)）。" }
    }
}

enum AIError: LocalizedError {
    case message(String)
    case authentication
    case rateLimited
    case invalidResponse
    case staleScene

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .authentication: "DeepSeek 密钥无效或账户额度不足，请检查 AI 设置。"
        case .rateLimited: "DeepSeek 请求受限，稍后重试。"
        case .invalidResponse: "DeepSeek 没有返回有效的相机操作，当前参数未更改。"
        case .staleScene: "画面已经变化，重新观察。"
        }
    }
}
