import SwiftUI
import UniformTypeIdentifiers
import InvestiQCore
import InvestiQPresentation

extension UTType {
    /// Encrypted InvestiQ backup (`.iqbackup`).
    static var investiQBackup: UTType { UTType(filenameExtension: "iqbackup", conformingTo: .data) ?? .data }
}

/// Binary file for exporting backups and JSON.
struct BinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.investiQBackup, .json, .data] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Settings → Backup & data.
struct DataManagementView: View {
    @Environment(AppModel.self) private var app
    @State private var model: DataManagementViewModel?

    var body: some View {
        Group {
            if let model { DataManagementContent(model: model) } else { ProgressView() }
        }
        .task { if model == nil { model = DataManagementViewModel(app: app) } }
    }
}

private struct DataManagementContent: View {
    @Bindable var model: DataManagementViewModel
    @State private var exportingBackup = false
    @State private var exportingJSON = false
    @State private var importing = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            if model.isDemo {
                Section { Text("backup.demoNote").foregroundStyle(.secondary) }
            } else {
                Section("backup.title") {
                    Text("backup.intro").fixedSize(horizontal: false, vertical: true)
                    SecureField("backup.passphrase", text: $model.passphrase)
                    SecureField("backup.confirmation", text: $model.confirmation)
                    Text("backup.passphraseNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("backup.create") {
                            Task {
                                await model.createBackup()
                                if model.backupData != nil { exportingBackup = true }
                            }
                        }
                        .disabled(!model.passphraseIssues.isEmpty || model.isWorking)
                        Button("backup.restore") { importing = true }.disabled(model.passphrase.isEmpty || model.isWorking)
                        if model.isWorking { ProgressView().controlSize(.small) }
                    }
                    Text("backup.restoreNote").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let summary = model.restoreSummary {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(L10n.string(Message("backup.summary", [.instant(summary.createdAt), .integer(summary.portfolios),
                                                                       .integer(summary.transactions)])))
                            Text("backup.replaceWarning").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("backup.confirmRestore", role: .destructive) { Task { await model.confirmRestore() } }
                                Button("common.cancel") { model.cancelRestore() }
                            }
                        }
                    }
                }
                Section("export.title") {
                    Text("export.intro").fixedSize(horizontal: false, vertical: true)
                    Button("export.json") {
                        Task {
                            await model.prepareExport()
                            if model.exportData != nil { exportingJSON = true }
                        }
                    }
                    Text("export.unencryptedWarning").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("data.cache") {
                Text("data.cacheIntro").fixedSize(horizontal: false, vertical: true)
                Button("data.clearCache") { confirmClear = true }
            }
            if let message = model.message {
                Section { InlineMessage(message: message, isError: !["backup.created", "backup.restored", "data.cacheCleared"].contains(message.key)) }
            }
        }
        .formStyle(.grouped)
        .fileExporter(isPresented: $exportingBackup, document: model.backupData.map(BinaryDocument.init(data:)),
                      contentType: .investiQBackup, defaultFilename: "InvestiQ-backup") { _ in model.backupWritten() }
        .fileExporter(isPresented: $exportingJSON, document: model.exportData.map(BinaryDocument.init(data:)),
                      contentType: .json, defaultFilename: "InvestiQ-export") { _ in model.exportWritten() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.investiQBackup, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Task { await model.prepareRestore(data) }
            } catch {
                Task { await model.prepareRestore(Data()) }
            }
        }
        .confirmationDialog("data.clearCacheConfirm", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("data.clearCache", role: .destructive) { Task { await model.clearCache() } }
            Button("common.cancel", role: .cancel) {}
        }
    }
}
