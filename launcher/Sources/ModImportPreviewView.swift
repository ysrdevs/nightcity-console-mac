import SwiftUI

struct ModImportApproval: Encodable {
    let workspace: String
    let reportSHA256: String
    let receiptName: String
}

struct ModImportCommitRequest: Encodable {
    let gameRoot: String
    let packages: [ModImportApproval]
}

struct ModImportPreviewSession: Identifiable {
    let id: UUID
    let gameRoot: String
    let workspace: URL
    let prepared: [ModPreparedImport]
    let approvals: [ModImportApproval]
    let review: ModImportBatchReview

    init(id: UUID = UUID(), gameRoot: String, workspace: URL, prepared: [ModPreparedImport],
         approvals: [ModImportApproval], review: ModImportBatchReview) {
        self.id = id; self.gameRoot = gameRoot; self.workspace = workspace
        self.prepared = prepared; self.approvals = approvals; self.review = review
    }
}

enum ModImportPreviewError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct ModImportPreviewView: View {
    @ObservedObject var model: Model
    let session: ModImportPreviewSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Mod Import").font(.title2.bold())
            Text("\(session.review.packages.count) package(s) · \(session.review.fileCount) files")
                .font(.callout).foregroundColor(.secondary)
            Text(model.busy ? "Installing the reviewed files…" : "Prepared in a temporary folder. Your game files have not changed.")
                .font(.callout)
            Text(session.gameRoot).font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(session.review.issues) { issue in issueRow(issue) }
                    ForEach(session.review.packages) { package in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(package.name).font(.headline).textSelection(.enabled)
                            if let identified = package.identifiedMod {
                                Text(identified + (package.version.map { " · \($0)" } ?? ""))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            ForEach(package.issues) { issue in issueRow(issue) }
                            if !package.dependencies.isEmpty {
                                Text("Requirements detected").font(.subheadline.bold())
                                ForEach(package.dependencies) { dependency in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: dependency.status == .missing ? "xmark.circle.fill" : "checkmark.circle")
                                            .foregroundColor(dependency.status == .missing ? .red : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(dependency.name + " · " + statusLabel(dependency.status))
                                                .font(.callout)
                                            Text(dependency.reason).font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            DisclosureGroup("Files to add (\(package.files.count))") {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(package.files.enumerated()), id: \.offset) { _, file in
                                        Text(file.destination).font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            }
                            .font(.caption)
                        }
                        Divider()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.busy {
                ProgressView(model.busyDetail.isEmpty ? "Installing…" : model.busyDetail).font(.caption)
            } else if model.status.hasPrefix("Import stopped:") || model.status.contains("installation changed") {
                Text(model.status).font(.callout).foregroundColor(.orange).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { model.cancelModImportPreview() }
                    .keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                if !session.review.canInstall {
                    Text("Resolve the blocking issues before installing.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Button("Install \(session.review.packages.count == 1 ? "Mod" : "Mods")") {
                    model.confirmModImport(session)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.review.canInstall || model.busy || model.gameIsRunning)
            }
        }
        .padding(22)
        .frame(width: 660, height: 600)
        .interactiveDismissDisabled(model.busy)
    }

    private func statusLabel(_ status: ModImportDependencyStatus) -> String {
        switch status {
        case .installed: return "Present"
        case .selected: return "In this import"
        case .missing: return "Missing"
        case .optional: return "Optional"
        }
    }

    private func issueRow(_ issue: ModImportReviewIssue) -> some View {
        Label(issue.message, systemImage: issue.blocking ? "xmark.octagon.fill" : "info.circle")
            .font(.callout).foregroundColor(issue.blocking ? .red : .secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}
