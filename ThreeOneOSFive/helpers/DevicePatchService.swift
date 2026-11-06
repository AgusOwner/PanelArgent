import Foundation
import UIKit

enum DevicePatchService {
    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        try withResolvedContainers(bundleIDs: orderedBundleIdentifiers(in: project)) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: resolver(roots)
            )
        }
    }

    static func inspectRestore(receipt: PatchTransactionReceipt) throws -> PatchRestoreInspection {
        try withResolvedContainers(
            bundleIDs: PatchTransaction.requiredBundleIdentifiers(for: receipt)
        ) { roots in
            try PatchTransaction.inspectRestore(receipt: receipt, containerResolver: resolver(roots))
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false
    ) throws {
        try withResolvedContainers(
            bundleIDs: PatchTransaction.requiredBundleIdentifiers(for: receipt)
        ) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                allowChangedTargets: allowChangedTargets,
                containerResolver: resolver(roots)
            )
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        project: PatchProject
    ) throws {
        try withResolvedContainers(
            bundleIDs: PatchTransaction.requiredBundleIdentifiers(for: receipt)
        ) { roots in
            try PatchTransaction.resetToAppliedState(
                receipt: receipt,
                fallbackProject: project,
                containerResolver: resolver(roots)
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    private static func resolver(_ roots: [String: URL]) -> (String) throws -> URL {
        { bundleID in
            guard let root = roots[bundleID] else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            return root
        }
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    private static func canonical(_ path: String) -> URL {
        PatchPathValidator.canonicalFileURL(URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        PatchContainerFallback.invalidate()
        defer { PatchContainerFallback.releaseAllGrants() }

        var roots: [String: URL] = [:]

        for bundleID in bundleIDs {
            // 1) MCM/MHA-C2: resuelve el path, pero en iOS 27 sin token.
            if let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
               ContainerStore.isApplicationContainerPath(path) {
                PatchContainerFallback.grant(path)
                roots[bundleID] = canonical(path)
                log("patch: MCM resolved \(bundleID)")
                continue
            }

            // 2) MobileInstallation + filesystem + bad_query class-13.
            if let resolved = PatchContainerFallback.resolve(bundleID: bundleID) {
                roots[bundleID] = canonical(resolved)
                log("patch: filesystem resolved \(bundleID) -> \(resolved)")
                continue
            }

            // Diagnóstico honesto: separa "no instalada" de "sin acceso".
            let bundlePath = PatchContainerFallback.bundlePath(forBundleID: bundleID)
            let dataPath = PatchContainerFallback.dataPath(forBundleID: bundleID)
            for root in [
                "/private/var/containers/Bundle/Application",
                "/private/var/mobile/Containers/Data/Application"
            ] {
                let granted = PatchContainerFallback.grant(root)
                let count = ContainerStore.enumerateDirectories(path: root).count
                log("diag: \(root) grant=\(granted) entradas=\(count)")
            }
            log("diag: bundlePath=\(bundlePath ?? "nil") dataPath=\(dataPath ?? "nil")")
            log("diag: \(bundleID) sin resolver — bundle inexistente o sandbox sin grants")

            throw PatchPackageError.targetAppUnavailable(bundleID)
        }

        return try operation(roots)
    }
}

// MARK: - Respaldo de resolución de contenedores

/// Resolución sin depender de tokens de MCM.
///
/// iOS 27 beta 5+ (24A5408d y posteriores, incluida la release) dejó de emitir
/// sandbox extensions por MCM class-2: `container_copy_sandbox_token` devuelve
/// NULL aunque la consulta resuelva. Esta ruta resuelve por MobileInstallation
/// y por filesystem, y pide un traversal grant con bad_query (class-13), que es
/// la única vía que no depende de MCM.
///
/// Los grants quedan activos hasta `releaseAllGrants()`: una extensión liberada
/// deja de cubrir la escritura del patch.
enum PatchContainerFallback {

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

    // MARK: Grants

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

    // MARK: Resolución

    /// Devuelve el contenedor de datos, o el bundle si no hay datos.
    static func resolve(bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }

        // MobileInstallation entrega el path del contenedor sin token de MCM.
        if let installed = installationPath(for: bundleID),
           ContainerStore.isApplicationContainerPath(installed) {
            grant(installed)
            return installed
        }

        guard let bundlePath = bundlePath(forBundleID: bundleID) else { return nil }
        if let dataPath = dataPath(forBundleID: bundleID) {
            grant(dataPath)
            return dataPath
        }
        return bundlePath
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

    // MARK: Interno

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