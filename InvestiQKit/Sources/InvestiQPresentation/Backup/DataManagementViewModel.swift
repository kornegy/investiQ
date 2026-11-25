import Foundation
import Observation
import InvestiQCore
import InvestiQSecurity
import InvestiQServices

/// Settings → Backup & data: encrypted backup and restore, JSON export, clearing cached market data.
@MainActor
@Observable
public final class DataManagementViewModel {
    public var passphrase = ""
    public var confirmation = ""
    public private(set) var backupData: Data?
    public private(set) var pendingRestore: Data?
    public private(set) var restoreSummary: BackupSummary?
    public private(set) var exportData: Data?
    public private(set) var message: Message?
    public private(set) var isWorking = false

    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public var isDemo: Bool { app.isDemo }
    public var passphraseIssues: [PasswordIssue] { PasswordPolicy().issues(password: passphrase, confirmation: confirmation) }

    public func createBackup() async {
        guard let services = app.services else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            backupData = try await services.backup.createBackup(passphrase: passphrase, confirmation: confirmation)
            message = Message("backup.created")
        } catch {
            backupData = nil
            message = Self.message(for: error)
        }
    }

    public func backupWritten() {
        backupData = nil
        passphrase = ""
        confirmation = ""
    }

    /// Step 1: the user picked a file and entered its passphrase; nothing is changed yet.
    public func prepareRestore(_ data: Data) async {
        guard let services = app.services else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            restoreSummary = try await services.backup.inspect(data, passphrase: passphrase)
            pendingRestore = data
            message = nil
        } catch {
            restoreSummary = nil
            pendingRestore = nil
            message = Self.message(for: error)
        }
    }

    /// Step 2: after explicit confirmation, replace this profile's data.
    public func confirmRestore() async {
        guard let services = app.services, let data = pendingRestore else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await services.backup.restore(data, passphrase: passphrase)
            try await app.reloadAfterRestore()
            pendingRestore = nil
            restoreSummary = nil
            passphrase = ""
            message = Message("backup.restored")
        } catch {
            message = Self.message(for: error)
        }
    }

    public func cancelRestore() {
        pendingRestore = nil
        restoreSummary = nil
    }

    public func prepareExport() async {
        guard let services = app.services else { return }
        do {
            exportData = try await services.dataExport.exportJSON()
        } catch {
            message = Message("export.error.failed")
        }
    }

    public func exportWritten() { exportData = nil }

    public func clearCache() async {
        guard let services = app.services else { return }
        do {
            try await services.cacheMaintenance.clearAll()
            message = Message("data.cacheCleared")
        } catch {
            message = Message("data.error.cacheClearFailed")
        }
    }

    static func message(for error: any Error) -> Message {
        switch error as? BackupServiceError {
        case .weakPassphrase?: return Message("backup.error.weakPassphrase")
        case .notAvailableInDemo?: return Message("backup.error.demo")
        case .file(.wrongPassphraseOrDamaged)?: return Message("backup.error.wrongPassphrase")
        case .file(.notABackup)?, .file(.unsupportedVersion)?, .file(.tooLarge)?: return Message("backup.error.notABackup")
        case .newerThanApp?: return Message("backup.error.newer")
        case .damaged?: return Message("backup.error.damaged")
        case nil: return Message("backup.error.failed")
        }
    }
}
