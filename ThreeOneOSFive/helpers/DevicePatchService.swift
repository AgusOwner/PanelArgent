import Foundation

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
        AppBundleLocator.invalidate()
        defer { AppBundleLocator.releaseAllGrants() }

        var roots: [String: URL] = [:]

        for bundleID in bundleIDs {
            // 1) MCM/MHA-C2: resuelve el path, pero en iOS 27 sin token.
            if let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
               ContainerStore.isApplicationContainerPath(path) {
                AppBundleLocator.grant(path)
                roots[bundleID] = canonical(path)
                log("patch: MCM resolved \(bundleID)")
                continue
            }

            // 2) MobileInstallation + filesystem + bad_query class-13.
            if let resolved = AppBundleLocator.resolve(bundleID: bundleID) {
                let path = resolved.dataPath ?? resolved.bundlePath
                roots[bundleID] = canonical(path)
                log("patch: filesystem resolved \(bundleID) -> \(path)")
                continue
            }

            // Diagnóstico honesto: separa "no instalada" de "sin acceso".
            let bundlePath = AppBundleLocator.bundlePath(forBundleID: bundleID)
            let dataPath = AppBundleLocator.dataPath(forBundleID: bundleID)
            for root in [
                "/private/var/containers/Bundle/Application",
                "/private/var/mobile/Containers/Data/Application"
            ] {
                let granted = AppBundleLocator.grant(root)
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

// MARK: - Compatibilidad

enum PatchContainerFallback {
    static func resolve(bundleID: String) -> String? {
        guard let resolved = AppBundleLocator.resolve(bundleID: bundleID) else { return nil }
        return resolved.dataPath ?? resolved.bundlePath
    }

    static func bundlePath(forBundleID bundleID: String) -> String? {
        AppBundleLocator.bundlePath(forBundleID: bundleID)
    }

    static func dataPath(forBundleID bundleID: String) -> String? {
        AppBundleLocator.dataPath(forBundleID: bundleID)
    }

    static func invalidate() {
        AppBundleLocator.invalidate()
    }
}