import AppKit
import UniformTypeIdentifiers

enum ModFilePicker {
    static func choose(message: String, multiple: Bool, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = multiple
        panel.prompt = "Import"
        panel.message = message
        panel.begin { response in
            if response == .OK { completion(panel.urls) }
        }
    }

    static func resolveDrops(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let eligible = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !eligible.isEmpty else { return false }
        let group = DispatchGroup()
        let results = DroppedURLs()
        for (index, provider) in eligible.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.isFileURL { results.append(url, at: index) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(results.ordered()) }
        return true
    }

    private final class DroppedURLs {
        private let lock = NSLock()
        private var values: [Int: URL] = [:]
        func append(_ url: URL, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            values[index] = url
        }
        func ordered() -> [URL] {
            lock.lock(); defer { lock.unlock() }
            return values.keys.sorted().compactMap { values[$0] }
        }
    }
}
