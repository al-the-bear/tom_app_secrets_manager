import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // DP-30: closing the window keeps the app in the menu bar; it quits only
  // from the menu bar's menu.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
