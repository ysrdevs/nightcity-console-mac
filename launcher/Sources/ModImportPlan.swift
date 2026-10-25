import Foundation

enum ModImportPlan {
    static func manifestBase(for url: URL) -> String {
        var directory: ObjCBool = false
        let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        return isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    // Manifests own installed files. Two packages must never silently replace each other's list.
    static func validate(_ urls: [URL]) throws {
        var seen = Set<String>()
        for url in urls {
            let base = manifestBase(for: url)
            guard seen.insert(base.lowercased()).inserted else {
                throw DuplicateName(name: base)
            }
        }
    }

    static func hasVirtualAtelier(in gameRoot: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: gameRoot.appendingPathComponent("archive/Mac/mod/VirtualAtelier.archive").path) { return true }
        let pattern = "(?m)^\\s*public\\s+class\\s+VirtualAtelierSiteListener\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let files = fm.enumerator(at: gameRoot.appendingPathComponent("r6/scripts"), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return false }
        return files.contains { value in
            guard let url = value as? URL, url.pathExtension.lowercased() == "reds",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let source = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
        }
    }

    struct DuplicateName: LocalizedError {
        let name: String
        var errorDescription: String? {
            "Two selected mods use the name ‘\(name)’. Give their ZIPs or folders distinct names before importing them together."
        }
    }
}
