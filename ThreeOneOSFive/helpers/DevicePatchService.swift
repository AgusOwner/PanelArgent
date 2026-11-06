import Foundation

enum DevicePatchService {
    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func inspectRestore(receipt: PatchTransactionReceipt) throws -> PatchRestoreInspection {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.inspectRestore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                allowChangedTargets: allowChangedTargets,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        project: PatchProject
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.resetToAppliedState(
                receipt: receipt,
                fallbackProject: project,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]

        for bundleID in bundleIDs {
            // 1) Camino normal: MCM/geod vía ContainerStore.
            if let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
               ContainerStore.isApplicationContainerPath(path) {
                roots[bundleID] = PatchPathValidator.canonicalFileURL(
                    URL(fileURLWithPath: path, isDirectory: true)
                )
                continue
            }

            // 2) Fallback: MCM deja de devolver contenedores de bundle en iOS 27.
            //    Se resuelve por filesystem, sin depender de la versión.
            if let resolved = PatchContainerFallback.resolve(bundleID: bundleID) {
                log("patch: fallback resolver used for \(bundleID)")
                roots[bundleID] = PatchPathValidator.canonicalFileURL(
                    URL(fileURLWithPath: resolved, isDirectory: true)
                )
                continue
            }

            throw PatchPackageError.targetAppUnavailable(bundleID)
        }
        return try operation(roots)
    }
}

// MARK: - Respaldo de resolución de contenedores

/// Resolución por sistema de archivos, sin MCM/geod.
/// MCM dejó de devolver contenedores de bundle en iOS 27, así que esto se usa
/// cuando `ContainerStore` no devuelve nada. No depende de la versión de iOS.
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

    private static let metadataName = ".com.apple.mobile_container_manager.metadata.plist"
    private static let metadataIdentifierKey = "MCMMetadataIdentifier"

    private static let lock = NSLock()
    private static var bundleCache: [String: String] = [:]
    private static var dataCache: [String: String] = [:]

    /// Devuelve el contenedor de datos (donde apuntan las rutas de los patches)
    /// o, si no hay datos, el bundle. nil si la app no está instalada.
    static func resolve(bundleID: String) -> String? {
        guard !bundleID.isEmpty,
              let bundlePath = bundlePath(forBundleID: bundleID) else { return nil }
        return dataPath(forBundleID: bundleID) ?? bundlePath
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