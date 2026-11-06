import Foundation

/// Copia los archivos .3105 incluidos en el bundle de la app
/// al directorio de patches de la app, una sola vez en el primer arranque.
/// Para agregar patches preinstalados, coloca los archivos .3105
/// dentro de la carpeta ThreeOneOSFive/BundledPatches/ del proyecto.
enum BundledPatchSeeder {

    private static let seededKey = "argent.bundledPatches.seeded"

    /// Llama esto al arrancar la app (en App.swift, dentro de .onAppear).
    /// Solo corre una vez; las siguientes veces no hace nada.
    static func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        seed()
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    private static func seed() {
        guard
            let bundleURL = Bundle.main.resourceURL?
                .appendingPathComponent("BundledPatches"),
            let files = try? FileManager.default.contentsOfDirectory(
                at: bundleURL,
                includingPropertiesForKeys: nil
            )
        else { return }

        let patches = files.filter { $0.pathExtension == "3105" }
        guard !patches.isEmpty else { return }

        guard let destinationRoot = try? PatchProjectLibrary.packageRootURL() else { return }

        for patch in patches {
            let destination = destinationRoot.appendingPathComponent(patch.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.copyItem(at: patch, to: destination)
            log("seeder: copied \(patch.lastPathComponent) to PatchProjects/")
        }
    }
}
