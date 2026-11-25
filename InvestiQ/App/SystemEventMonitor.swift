import AppKit
import SwiftUI
import InvestiQPresentation

/// Locks the app on system sleep and screen lock, and records user activity for the inactivity
/// timer (FR-AUTH-3).
@MainActor
final class SystemEventMonitor {
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?

    func start(app: AppModel) {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await app.lock(reason: .systemSleep) }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in await app.lock(reason: .screenLocked) }
        })
        // Local event monitors are invoked on the main thread.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { app.registerActivity() }
            return event
        }
    }

    func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
}
