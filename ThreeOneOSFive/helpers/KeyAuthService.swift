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

enum KeyAuthError: LocalizedError {
    case network(String)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .server(let message): return message
        case .invalidResponse: return "Respuesta inválida del servidor."
        }
    }
}

/// Cliente mínimo para la API 1.3 de KeyAuth: inicializa sesión y valida una key.
actor KeyAuthService {
    static let shared = KeyAuthService()

    private var sessionId: String?

    private var hwid: String { ActivationLedger.hwid }

    private func post(_ params: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: KeyAuthConfig.apiBaseURL) else {
            throw KeyAuthError.network("URL de API inválida.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = params
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, _): (Data, URLResponse)
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw KeyAuthError.network("No se pudo conectar con KeyAuth. Revisa tu conexión.")
        }

        let rawText = String(data: data, encoding: .utf8) ?? "<no decodificable>"
        log("keyauth: response for type=\(params["type"] ?? "?") -> \(rawText)")

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw KeyAuthError.invalidResponse
        }
        return json
    }

    /// Inicializa la sesión con KeyAuth. Se debe llamar antes de validar una key.
    func initialize() async throws {
        let params: [String: String] = [
            "type": "init",
            "name": KeyAuthConfig.name,
            "ownerid": KeyAuthConfig.ownerid,
            "secret": KeyAuthConfig.secret,
            "ver": KeyAuthConfig.version,
            "hash": "",
        ]
        let json = try await post(params)

        guard (json["success"] as? Bool) == true else {
            let message = json["message"] as? String ?? "No se pudo inicializar KeyAuth."
            throw KeyAuthError.server(message)
        }
        sessionId = json["sessionid"] as? String
    }

    /// Valida una license key contra KeyAuth. Lanza error si es inválida,
    /// si ya se activó en este dispositivo o si pertenece a otro equipo.
    func validate(key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeyAuthError.server("Key inválida.")
        }

        // El llavero sobrevive a la desinstalación, así que una key ya usada
        // se rechaza aquí aunque la app se haya borrado y reinstalado.
        if ActivationLedger.isBurned(trimmed) {
            throw KeyAuthError.server(
                "Esta key ya fue activada en este dispositivo. Usa una key nueva."
            )
        }

        if sessionId == nil {
            try await initialize()
        }
        guard let sessionId else {
            throw KeyAuthError.invalidResponse
        }

        let params: [String: String] = [
            "type": "license",
            "key": trimmed,
            "hwid": hwid,
            "sessionid": sessionId,
            "name": KeyAuthConfig.name,
            "ownerid": KeyAuthConfig.ownerid,
        ]
        let json = try await post(params)

        guard (json["success"] as? Bool) == true else {
            let raw = (json["message"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            throw KeyAuthError.server(Self.spanish(raw))
        }

        // Solo se quema cuando KeyAuth confirmó la activación.
        ActivationLedger.burn(trimmed)
    }

    private static func spanish(_ raw: String) -> String {
        let value = raw.lowercased()
        guard !value.isEmpty else { return "Key inválida." }
        if value.contains("max uses") || value.contains("already used") || value.contains("reached") {
            return "Esta key ya fue usada y no puede volver a activarse. Pide una nueva."
        }
        if value.contains("hwid") || value.contains("hardware") {
            return "Esta key ya está vinculada a otro dispositivo."
        }
        if value.contains("expired") { return "La key caducó." }
        if value.contains("not found") || value.contains("does not exist") { return "La key no existe." }
        if value.contains("banned") { return "La key está baneada." }
        return raw
    }
}