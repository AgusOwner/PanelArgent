import Foundation
import CryptoKit
import Security

/// Registro local que sobrevive a la desinstalación de la app.
///
/// iOS conserva los elementos del llavero aunque se borre la aplicación, así
/// que sirve para recordar qué keys ya se activaron en este dispositivo y para
/// guardar un identificador estable del equipo. Se pierde solo al borrar todo
/// el contenido y ajustes, o al restaurar en otro equipo.
enum ActivationLedger {
    private static let service = "com.yangjiii.3105.activation"
    private static let burnedAccount = "burned-keys"
    private static let hwidAccount = "hwid"

    // MARK: - Identificador estable

    /// No cambia al reinstalar. Se envía como `hwid` a KeyAuth.
    static var hwid: String {
        if let stored = readString(account: hwidAccount), !stored.isEmpty {
            return stored
        }
        let generated = UUID().uuidString
        write(generated, account: hwidAccount)
        return generated
    }

    // MARK: - Keys quemadas

    static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func isBurned(_ key: String) -> Bool {
        burnedKeys.contains(fingerprint(normalize(key)))
    }

    static func burn(_ key: String) {
        var keys = burnedKeys
        let identifier = fingerprint(normalize(key))
        guard !keys.contains(identifier) else { return }
        keys.append(identifier)
        write(keys.joined(separator: "\n"), account: burnedAccount)
    }

    /// Útil para pruebas: permite volver a usar una key en el mismo equipo.
    static func reset() {
        delete(account: burnedAccount)
    }

    private static var burnedKeys: [String] {
        guard let raw = readString(account: burnedAccount), !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").map(String.init)
    }

    private static func fingerprint(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Llavero

    private static func readString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, account: String) {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}