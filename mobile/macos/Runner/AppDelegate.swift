import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var retainedMainWindow: NSWindow?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    retainedMainWindow = NSApp.windows.first { $0 is MainFlutterWindow }
    retainedMainWindow?.isReleasedWhenClosed = false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      retainedMainWindow?.makeKeyAndOrderFront(nil)
      sender.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    NSLog("[OrialisMemory] Last window closed; keeping capture shortcuts active")
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
