import Foundation
import LocalAuthentication
import Security

/// Acesso simples ao Keychain do iPhone.
enum Keychain {
    static let service = "br.com.colorsoftware.expediente"

    @discardableResult
    static func set(_ data: Data, account: String, accessControl: SecAccessControl? = nil) -> Bool {
        delete(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        if let accessControl {
            query[kSecAttrAccessControl as String] = accessControl
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String, context: LAContext? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Face ID / Touch ID. A chave dos dados fica no Keychain, liberada só pela biometria cadastrada no aparelho.
enum Biometrics {
    static let account = "biometric-data-key"

    enum Kind { case none, faceID, touchID, opticID }

    static var kind: Kind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    static var isAvailable: Bool { kind != .none }

    static var name: String {
        switch kind {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return "biometria"
        }
    }

    static var symbol: String {
        switch kind {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "faceid"
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "biometricsEnabled")
    }

    static func enable(key: Data) -> Bool {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else { return false }
        let ok = Keychain.set(key, account: account, accessControl: access)
        UserDefaults.standard.set(ok, forKey: "biometricsEnabled")
        return ok
    }

    static func disable() {
        Keychain.delete(account: account)
        UserDefaults.standard.set(false, forKey: "biometricsEnabled")
    }

    /// Pede a biometria e devolve a chave dos dados. Roda fora da thread principal.
    static func unlock() async -> Data? {
        let context = LAContext()
        context.localizedCancelTitle = "Usar senha"
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                      localizedReason: "Entrar no Expediente")
            guard ok else { return nil }
        } catch {
            return nil
        }
        return await Task.detached { Keychain.get(account: account, context: context) }.value
    }
}
