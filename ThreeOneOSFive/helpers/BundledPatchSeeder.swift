import Foundation

/// Instala automáticamente los paquetes .3105 incluidos en el bundle de la app
/// dentro de PatchProjects/, para que aparezcan solos en la pestaña Installed.
///
/// Para agregar paquetes preinstalados, poné los archivos .3105 en la carpeta
/// BundledPatches/ de la raíz del proyecto (folder reference azul, ya incluida
/// en Copy Bundle Resources). No hace falta tocar el pbxproj para cada archivo.
///
/// Es idempotente y se puede llamar en cada arranque: solo copia lo que falta
/// o lo que cambió de tamaño, así que los paquetes nuevos de una build nueva
/// aparecen sin reinstalar la app.
enum BundledPatchSeeder {

    private static let folderName = "BundledPatches"
    private static let packageExtension = "3105"
    private static let maximumDepth = 2

    /// Devuelve cuántos paquetes se instalaron en esta pasada.
    @discardableResult
    static func seedIfNeeded() -> Int {
        let sources = bundledPackages()
        guard !sources.isEmpty else {
            log("seeder: no bundled packages found in the app bundle")
            return 0
        }
        guard let root = try? PatchProjectLibrary.packageRootURL() else {
            log("seeder: patch package root unavailable")
            return 0
        }

        var installed = 0
        for source in sources {
            let name = source.lastPathComponent
            let destination = root.appendingPathComponent(name)

            if let sourceSize = fileSize(source),
               let existingSize = fileSize(destination),
               sourceSize == existingSize {
                continue
            }

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                installed += 1
                log("seeder: installed \(name)")
                markAsAuthorCopyIfPossible(destination)
            } catch {
                log("seeder: failed to install \(name) — \(error.localizedDescription)")
            }
        }

        if installed > 0 {
            log("seeder: \(installed) bundled package(s) installed")
        }
        return installed
    }

    private static func markAsAuthorCopyIfPossible(_ url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let summary = try? PatchPackageCodec.inspect(data) else { return }
        try? PatchProjectLibrary.markAsAuthorCopy(packageID: summary.packageID)
    }

    private static func bundledPackages() -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()
        for directory in candidateDirectories() {
            for url in packages(in: directory) where seen.insert(url.lastPathComponent).inserted {
                results.append(url)
            }
        }
        return results
    }

    /// El folder reference se copia a la raíz del .app. Se cubren también
    /// variantes por si el recurso queda aplanado en la raíz del bundle.
    private static func candidateDirectories() -> [URL] {
        let bundles = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        var directories: [URL] = []
        for bundle in bundles {
            let nested = bundle.appendingPathComponent(folderName, isDirectory: true)
            if isDirectory(nested) { directories.append(nested) }
            if isDirectory(bundle) { directories.append(bundle) }
        }
        return directories
    }

    private static func packages(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let baseDepth = directory.standardizedFileURL.pathComponents.count
        var results: [URL] = []

        for case let url as URL in enumerator {
            let depth = url.standardizedFileURL.pathComponents.count - baseDepth
            guard depth <= maximumDepth else {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == packageExtension,
                  isFile(url) else { continue }
            results.append(url)
        }
        return results
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    private static func isFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}