import Foundation

/// Datos de tu aplicación en el panel de KeyAuth (keyauth.win/app).
/// El "secret" es sensible: cualquiera con el código fuente lo puede ver,
/// ya que este proyecto es público bajo GPLv3. No es una protección fuerte,
/// solo frena a usuarios casuales.
enum KeyAuthConfig {
    static let name = "Galaxy X"
    static let ownerid = "554yMP2JCV"
    static let secret = "50c9be481c75ef85fb7cdafac2e4ea9309281449db79c2fc7d10927d7c5d6e2b"
    static let version = "1.0"

    /// Dominio base de la API. keyauth.cc está bloqueado a propósito por KeyAuth;
    /// usa keyauth.win o tu dominio propio si configuraste uno en el panel.
    static let apiBaseURL = "https://keyauth.win/api/1.3/"
}
