import AppKit

/// Minimal AppKit delegate: InvestiQ is a single-window app, so closing the last window quits it
/// (which also releases the unlocked session), and state restoration never restores zero windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
