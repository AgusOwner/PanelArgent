import Foundation

enum ExploitSupportPolicy {
    static let verifiedIOS17Range = "17.0–17.7.x"
    static let verifiedIOS18Range = "18.0–18.7.1"
    static let verifiedIOS26Range = "26.0–26.7.2"
    static let verifiedIOS27Range = "27.0–27.2"

    /// Builds beta de iOS 27.0, previos al lanzamiento final.
    static let verifiedIOS27Betas: [(beta: Int, publicBeta: Int?, build: String)] = [
        (1, nil, "24A5355q"),
        (2, nil, "24A5370h"),
        (3, 1, "24A5380h"),
        (4, 2, "24A5390f"),
        (5, 3, "24A5408d"),
        (6, 4, "24A5418b"),
        (7, 5, "24A5424a")
    ]

    /// Builds finales (release) de iOS 27, por versión. Actualizar cuando Apple
    /// publique una versión nueva; no afecta si el exploit sigue funcionando ahí,
    /// solo si la app deja de bloquear el botón para esa versión.
    static let verifiedIOS27ReleaseBuilds: [String: [String]] = [
        "27.0": ["24A435", "24A437"],      // RC y RTM
        "27.0.1": ["24A446"],
        "27.2": ["24B115", "24B119"]       // RC y RTM
    ]

    static func iOS27BetaNumber(for build: String) -> Int? {
        verifiedIOS27Betas.first { $0.build == build }?.beta
    }

    static func iOS27PublicBetaNumber(for build: String) -> Int? {
        verifiedIOS27Betas.first { $0.build == build }?.publicBeta
    }

    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        if major == 17 {
            return minor <= 7
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 1)
        }

        return false
    }

    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        if supportsKernelExploit(major: major, minor: minor, patch: patch) {
            return true
        }

        if major == 26 {
            guard minor >= 0, patch >= 0 else { return false }
            // Cubre 26.0 a 26.7.2
            return minor < 7 || (minor == 7 && patch <= 2)
        }

        guard major == 27 else { return false }

        // Betas de iOS 27.0
        if minor == 0, patch == 0, iOS27BetaNumber(for: build) != nil {
            return true
        }

        // Versiones finales ya publicadas (27.0, 27.0.1, 27.2)
        let versionKey = patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        if let builds = verifiedIOS27ReleaseBuilds[versionKey] {
            return builds.contains(build)
        }

        return false
    }
}
