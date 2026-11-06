import Foundation

/// Resolución de contenedores sin depender de tokens de MCM.
///
/// iOS 27 beta 5+ (24A5408d y posteriores, incluida la release) dejó de emitir
/// sandbox extensions por MCM class-2: `container_copy_sandbox_token` devuelve
/// NULL aunque la consulta resuelva. El token ya no sirve como fuente de
/// verdad. Esta ruta resuelve por MobileInstallation y por filesystem, y pide
/// un traversal grant con bad_query (class-13) sobre el contenedor, que es la
/// única vía que no depende de MCM.
///
/// Los grants quedan activos hasta `releaseAllGrants()`: una extensión liberada
/// deja de cubrir la escritura del patch.
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

    private static let lock = NSLock()
    private static var bundleCache: [String: String] = [:]
    private static var dataCache: [String: String] = [:]
    private static var installationCache: [String: String]?
    private static var activeGrants: Set<Int64> = []

    struct Resolved {
        let bundlePath: String
        let dataPath: String?
    }

    // MARK: - Grants

    /// Pide acceso al path. Devuelve false si bad_query no entrega nada.
    @discardableResult
    static func grant(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let handle = ContainerStore.grantContainerAccess(path)
        guard handle >= 0 else { return false }
        lock.lock(); activeGrants.insert(handle); lock.unlock()
        return true
    }

    static func releaseAllGrants() {
        lock.lock()
        let handles = activeGrants
        activeGrants.removeAll()
        lock.unlock()
        for handle in handles { bad_query_release(handle) }
    }

    // MARK: - Entradas

    static func resolve(bundleID: String) -> Resolved? {
        guard !bundleID.isEmpty else { return nil }

        // 1) MobileInstallation entrega el path del contenedor de datos sin
        //    necesitar token de MCM.
        if let installed = installationPath(for: bundleID),
           ContainerStore.isApplicationContainerPath(installed) {
            grant(installed)
            return Resolved(
                bundlePath: bundlePath(forBundleID: bundleID) ?? installed,
                dataPath: installed
            )
        }

        // 2) Escaneo por filesystem con grants por directorio.
        guard let bundlePath = bundlePath(forBundleID: bundleID) else { return nil }
        let dataPath = dataPath(forBundleID: bundleID)
        if let dataPath { grant(dataPath) }
        return Resolved(bundlePath: bundlePath, dataPath: dataPath)
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
            grant(root)
            for containerPath in entries(in: root) {
                for appPath in entries(in: containerPath) where appPath.hasSuffix(".app") {
                    let identifier = Bundle(path: appPath)?.bundleIdentifier
                        ?? infoPlistIdentifier((appPath as NSString).appendingPathComponent("Info.plist"))
                    guard identifier == bundleID else { continue }
                    grant(appPath)
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

        // Datos y App Groups comparten la misma metadata.
        if let found = container(withIdentifier: bundleID, in: dataRoots + groupRoots) {
            lock.lock(); dataCache[bundleID] = found; lock.unlock()
            return found
        }
        return nil
    }

    static func invalidate() {
        releaseAllGrants()
        lock.lock()
        bundleCache.removeAll()
        dataCache.removeAll()
        installationCache = nil
        lock.unlock()
    }

    // MARK: - Interno

    private static func installationPath(for bundleID: String) -> String? {
        lock.lock()
        var cache = installationCache
        lock.unlock()

        if cache == nil {
            var built: [String: String] = [:]
            for app in ContainerStore.installedAppsFromAPI() {
                let path = ContainerDiscoveryMerger.canonicalPath(app.containerPath)
                if !path.isEmpty { built[app.bundleID] = path }
            }
            lock.lock(); installationCache = built; lock.unlock()
            cache = built
        }
        return cache?[bundleID]
    }

    private static func entries(in path: String) -> [String] {
        ContainerStore.enumerateDirectories(path: path).map { entry in
            entry.hasPrefix("/") ? entry : (path as NSString).appendingPathComponent(entry)
        }
    }

    private static func container(withIdentifier identifier: String, in roots: [String]) -> String? {
        for root in roots {
            grant(root)
            for dir in entries(in: root) {
                guard UUID(uuidString: (dir as NSString).lastPathComponent) != nil else { continue }
                grant(dir)
                guard ContainerStore.readContainerMetadata(containerPath: dir)?.bundleID == identifier else { continue }
                return ContainerDiscoveryMerger.canonicalPath(dir)
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