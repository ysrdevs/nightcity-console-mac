import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class DiagnosticsExportController: ObservableObject {
    @Published private(set) var exporting = false
    @Published private(set) var message = ""

    func export(_ snapshot: DiagnosticsSnapshot) {
        guard !exporting else { return }
        exporting = true
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.message = "Save logs, versions, mod details and a 3-second thread sample if the selected game is running. For a freeze, leave the game open. Personal paths and IDs are redacted; saves and screenshots are excluded. Nothing is uploaded."
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "NightCity-Diagnostics-\(Self.dateLabel()).zip"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let destination = panel.url else { self.exporting = false; return }
            self.message = "Collecting diagnostics and checking for a running game to sample…"
            let scoped = destination.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .utility).async {
                let result: Result<String, Error>
                do {
                    let report = DiagnosticsCollector(snapshot: snapshot).collect()
                    try report.zipData().write(to: destination, options: .atomic)
                    result = .success(report.sampleStatus)
                } catch { result = .failure(error) }
                if scoped { destination.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    self.exporting = false
                    switch result {
                    case .success(let status):
                        switch status {
                        case "captured": self.message = "Diagnostics ZIP saved with a game thread sample. Review it before sharing."
                        case "not_running": self.message = "Diagnostics ZIP saved. No running game was found in the selected folder, so no thread sample was captured."
                        case "output_limit": self.message = "Diagnostics ZIP saved. The thread capture reached a size limit; the ZIP records whether a partial sample was available."
                        default: self.message = "Diagnostics ZIP saved. A complete game thread sample could not be captured; the ZIP records why."
                        }
                    case .failure: self.message = "Couldn't save diagnostics. Choose a writable folder and try again."
                    }
                }
            }
        }
    }
    private static func dateLabel() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}
