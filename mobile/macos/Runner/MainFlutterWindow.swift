import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Preserve settings from earlier sandboxed releases without overwriting
    // settings already saved by the direct-distribution app.
    DesktopWebServices.preservePreferences()
    let flutterViewController = FlutterViewController()
    let windowFrame = NSRect(x: self.frame.origin.x, y: self.frame.origin.y, width: 1180, height: 800)
    self.minSize = NSSize(width: 560, height: 600)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let serviceChannel = FlutterMethodChannel(
      name: "top.jxcz.orialis/web_services", binaryMessenger: flutterViewController.engine.binaryMessenger)
    serviceChannel.setMethodCallHandler { call, result in
      guard call.method == "start", let arguments = call.arguments as? [String: Any],
            let service = arguments["id"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try DesktopWebServices.start(service)
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "service_start_failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    }

    super.awakeFromNib()
  }
}


private enum DesktopWebServices {
  private static let home = FileManager.default.homeDirectoryForCurrentUser
  private static let domain = "gui/\(getuid())"

  static func preservePreferences() {
    guard let bundle = Bundle.main.bundleIdentifier else { return }
    let legacy = home.appendingPathComponent("Library/Containers/\(bundle)/Data/Library/Preferences/\(bundle).plist")
    guard let data = try? Data(contentsOf: legacy),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: "orialis.directDistributionPreferencesImported") { return }
    let current = defaults.persistentDomain(forName: bundle) ?? [:]
    for (key, value) in values where key.hasPrefix("flutter.") && current[key] == nil {
      defaults.set(value, forKey: key)
    }
    defaults.set(true, forKey: "orialis.directDistributionPreferencesImported")
  }

  static func start(_ service: String) throws {
    switch service {
    case "paperclip":
      try ensureAgent("com.jxcz.aliyun-paperclip-hindsight-tunnel")
      try ensureAgent("com.jxcz.paperclip-aliyun-db-fast-tunnel")
      try ensureAgent("com.jxcz.paperclip-mac-cloud-db")
    case "hindsight":
      try ensureAgent("com.jxcz.aliyun-paperclip-hindsight-tunnel")
    case "server-monitor":
      let script = home.appendingPathComponent("Documents/Codex/2026-10-02/task/server-watch/app.py")
      guard FileManager.default.fileExists(atPath: script.path) else {
        throw NSError(domain: "Orialis", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "找不到服务器监控启动脚本"])
      }
      // launchd owns the detached process, which survives closing Orialis.
      let python = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3")
        ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
      let label = "top.jxcz.orialis.server-monitor"
      let status = try command(["print", "\(domain)/\(label)"]) == 0
        ? try command(["kickstart", "\(domain)/\(label)"])
        : try command(["submit", "-l", label, "--", python, script.path])
      guard status == 0 else {
        throw NSError(domain: "Orialis", code: 6,
          userInfo: [NSLocalizedDescriptionKey: "服务器监控进程未能启动"])
      }
    default:
      throw NSError(domain: "Orialis", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "未配置此服务的启动方式"])
    }
  }

  private static func ensureAgent(_ label: String) throws {
    if try command(["print", "\(domain)/\(label)"]) != 0 {
      let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
      guard FileManager.default.fileExists(atPath: plist.path),
            try command(["bootstrap", domain, plist.path]) == 0 else {
        throw NSError(domain: "Orialis", code: 3,
          userInfo: [NSLocalizedDescriptionKey: "后台服务配置未能加载：\(label)"])
      }
    }
    guard try command(["kickstart", "\(domain)/\(label)"]) == 0 else {
      throw NSError(domain: "Orialis", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "后台服务未能启动：\(label)"])
    }
  }

  private static func command(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = environment
    try process.run()
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
      process.terminate()
      throw NSError(domain: "Orialis", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "后台启动命令超时"])
    }
    return process.terminationStatus
  }
}
