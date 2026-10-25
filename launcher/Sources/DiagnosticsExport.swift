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
        panel.message = "Save a local ZIP of versions, mod names, graphics settings and recent logs. Personal paths and IDs are redacted. Saves and screenshots are excluded. Review before sharing."
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "NightCity-Diagnostics-\(Self.dateLabel()).zip"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let destination = panel.url else { self.exporting = false; return }
            self.message = "Collecting diagnostics…"
            let scoped = destination.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .utility).async {
                let result: Result<Void, Error>
                do {
                    let report = DiagnosticsCollector(snapshot: snapshot).collect()
                    try report.zipData().write(to: destination, options: .atomic)
                    result = .success(())
                } catch { result = .failure(error) }
                if scoped { destination.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    self.exporting = false
                    switch result {
                    case .success: self.message = "Diagnostics ZIP saved. Review it before sharing."
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
