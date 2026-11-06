import Foundation

/// Resolución de contenedores por sistema de archivos, sin MCM/geod.
///
/// MCM dejó de devolver contenedores de bundle en iOS 27, así que esta ruta
/// se usa como respaldo (y como fuente principal) en todas las versiones.
/// Requiere que el escape de sandbox ya esté activo.
enum AppBundleLocator {

    private static let bundleRoots = [
        "/private/var/containers/Bundle/Application",
        "/var/containers/Bundle/Application"
    ]

    private static let dataRoots = [
        "/private/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/Application"
    ]

    private static let groupRoots = [
        "/private/var/mobile/Containers/Shared/AppGroup",
        "/var/mobile/Containers/Shared/AppGroup"
    ]

    private static let metadataName = ".com.apple.mobile_container_manager.metadata.plist"
    private static let metadataIdentifierKey = "MCMMetadataIdentifier"

    private static let lock = NSLock()
    private static var bundleCache: [String: String] = [:]
    private static var dataCache: [String: String] = [:]

    struct Resolved {
        let bundlePath: String
        let dataPath: String?
    }

    /// Punto de entrada único. Devuelve nil solo si el bundle no existe
    /// realmente en el disco.
    static func resolve(bundleID: String) -> Resolved? {
        guard !bundleID.isEmpty,
              let bundlePath = bundlePath(forBundleID: bundleID) else { return nil }
        return Resolved(bundlePath: bundlePath, dataPath: dataPath(forBundleID: bundleID))
    }

    static func isInstalled(bundleID: String) -> Bool {
        bundlePath(forBundleID: bundleID) != nil
    }

    static func bundlePath(forBundleID bundleID: String) -> String? {
        lock.lock()
        let cached = bundleCache[bundleID]
        lock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached) { return cached }

        for root in bundleRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let containerPath = root + "/" + entry
                guard let apps = try? FileManager.default.contentsOfDirectory(atPath: containerPath) else { continue }
                for app in apps where app.hasSuffix(".app") {
                    let appPath = containerPath + "/" + app
                    let identifier = Bundle(path: appPath)?.bundleIdentifier
                        ?? infoPlistIdentifier(appPath + "/Info.plist")
                    guard identifier == bundleID else { continue }
                    lock.lock(); bundleCache[bundleID] = appPath; lock.unlock()
                    return appPath
                }
            }
        }
        return nil
    }

    static func dataPath(forBundleID bundleID: String) -> String? {
        lock.lock()
        let cached = dataCache[bundleID]
        lock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached) { return cached }

        if let found = container(withIdentifier: bundleID, in: dataRoots) {
            lock.lock(); dataCache[bundleID] = found; lock.unlock()
            return found
        }
        // Los App Groups se resuelven con la misma metadata.
        return container(withIdentifier: bundleID, in: groupRoots)
    }

    static func invalidate() {
        lock.lock()
        bundleCache.removeAll()
        dataCache.removeAll()
        lock.unlock()
    }

    private static func container(withIdentifier identifier: String, in roots: [String]) -> String? {
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let containerPath = root + "/" + entry
                let metadataPath = containerPath + "/" + metadataName
                guard let data = FileManager.default.contents(atPath: metadataPath),
                      let plist = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                      ) as? [String: Any],
                      let value = plist[metadataIdentifierKey] as? String,
                      value == identifier else { continue }
                return containerPath
            }
        }
        return nil
    }

    private static func infoPlistIdentifier(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
}