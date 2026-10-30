import Cocoa
import FlutterMacOS
import WidgetKit
import Carbon
import ApplicationServices
import CryptoKit
import ImageIO

class MainFlutterWindow: NSWindow {
  private var memoryBridge: DesktopMemoryBridge?
  override func awakeFromNib() {
    // Preserve settings from earlier sandboxed releases without overwriting
    // settings already saved by the direct-distribution app.
    DesktopWebServices.preservePreferences()
    let flutterViewController = FlutterViewController()
    let available = (self.screen ?? NSScreen.main)?.visibleFrame.size
    let size = NSSize(width: min(1440, available?.width ?? 1440),
                      height: min(900, available?.height ?? 900))
    let windowFrame = NSRect(origin: self.frame.origin, size: size)
    self.minSize = NSSize(width: 560, height: 600)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let widgetChannel = FlutterMethodChannel(
      name: "top.jxcz.orialis/widgets", binaryMessenger: flutterViewController.engine.binaryMessenger)
    widgetChannel.setMethodCallHandler { call, result in
      guard call.method == "updateSnapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        guard let payload = call.arguments as? [String: Any],
              JSONSerialization.isValidJSONObject(payload) else {
          throw NSError(domain: "OrialisWidgets", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Invalid widget snapshot"])
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        _ = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        guard let url = WidgetSnapshot.fileURL else {
          throw NSError(domain: "OrialisWidgets", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Widget App Group unavailable"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
        result(nil)
      } catch {
        result(FlutterError(code: "widget_snapshot_failed", message: error.localizedDescription, details: nil))
      }
    }

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

    memoryBridge = DesktopMemoryBridge(messenger: flutterViewController.engine.binaryMessenger)

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

/// Native capture stays scoped to the signed-in account; no clipboard mutation.
private final class DesktopMemoryBridge {
  private let channel: FlutterMethodChannel
  private var scope: String?
  private var hotKeys: [EventHotKeyRef] = []
  private var handler: EventHandlerRef?
  private var capturing = false
  private static let shortcutsPreference = "orialis.memory.shortcuts"
  private var shortcuts = MemoryShortcut.defaults
  private var shortcutsSuspended = false
  private let manager = FileManager.default
  private var directory: URL? {
    guard let scope = scope else { return nil }
    let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    return manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Orialis/Memory/\(hash)", isDirectory: true)
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "top.jxcz.orialis/memory", binaryMessenger: messenger)
    if let saved = UserDefaults.standard.dictionary(forKey: Self.shortcutsPreference),
       let parsed = try? MemoryShortcut.parsePair(saved) { shortcuts = parsed }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        let arguments = call.arguments as? [String: Any] ?? [:]
        if ["importCloud", "storeCloudImage"].contains(call.method),
           let expected = arguments["expectedScope"] as? String, self.scope != expected {
          throw self.failure("账号已变更，请重试。")
        }
        switch call.method {
        case "status":
          result(["supported": true, "silentCaptureSupported": true,
                  "silentCaptureEnabled": CGPreflightScreenCaptureAccess()])
        case "getShortcuts": result(self.shortcuts.mapValues { $0.dictionary })
        case "suspendShortcuts":
          self.unregisterKeyReferences()
          self.shortcutsSuspended = true
          result(nil)
        case "resumeShortcuts":
          if self.shortcutsSuspended {
            do { try self.registerKeys(self.shortcuts) }
            catch { self.unregisterKeyReferences(); throw error }
            self.shortcutsSuspended = false
          }
          result(nil)
        case "setShortcuts":
          let next = try MemoryShortcut.parsePair(arguments)
          let previous = self.shortcuts
          self.unregisterKeyReferences()
          do {
            try self.registerKeys(next)
          } catch {
            self.unregisterKeyReferences()
            if !self.shortcutsSuspended {
              do { try self.registerKeys(previous) }
              catch { self.showCaptureAlert("原快捷键恢复失败，请重新启动 Orialis。") }
            }
            throw self.failure("快捷键已被占用或无法注册，原设置已保留。")
          }
          if self.shortcutsSuspended { self.unregisterKeyReferences() }
          self.shortcuts = next
          UserDefaults.standard.set(next.mapValues { $0.dictionary }, forKey: Self.shortcutsPreference)
          result(next.mapValues { $0.dictionary })
        case "setScope":
          self.scope = (arguments["scope"] as? String).flatMap { $0.isEmpty ? nil : $0 }
          result(nil)
        case "list":
          guard let directory = self.directory else { result([]); return }
          let files = (try? self.manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
          result(try files.filter { $0.pathExtension == "json" }.map { try self.readURL($0) })
        case "read": result(try self.read(self.identifier(arguments)))
        case "update":
          let id = try self.identifier(arguments)
          var record = try self.read(id)
          if let expected = arguments["expectedAnalysisRequestId"] as? String,
             (record["analysisRequestId"] as? String ?? "") != expected {
            throw self.failure("这条记忆的分析任务已更新，请刷新后重试。")
          }
          let allowed = Set(["title", "notes", "summary", "analysisStatus", "analysisError", "analysisConversationId", "analysisMessageId", "analysisRequestId", "category", "sourceUrl", "videoStatus", "videoSummary", "videoError", "cloudVersion", "cloudRecordHash", "cloudImageSha256", "cloudDeletedAt", "cloudSyncError"])
          for (key, value) in arguments["fields"] as? [String: Any] ?? [:] where allowed.contains(key) {
            if value is NSNull { record.removeValue(forKey: key) } else { record[key] = value }
          }
          try self.write(record, id: id)
          result(record)
        case "importCloud":
          guard let incoming = arguments["record"] as? [String: Any],
                let id = incoming["id"] as? String, UUID(uuidString: id) != nil,
                arguments.keys.contains("expectedRecord"), !incoming.keys.contains("imagePath") else {
            throw self.failure("云端记忆或本地快照无效。")
          }
          let url = try self.file(id, extension: "json")
          let current = self.manager.fileExists(atPath: url.path) ? try self.read(id) : nil
          if let expected = arguments["expectedRecord"] as? [String: Any] {
            guard let current = current, expected.allSatisfy({ key, value in
              self.normalizedCloudValue(current[key], key: key) == self.normalizedCloudValue(value, key: key)
            }) else { throw self.failure("本地记忆已更新，请刷新后重试。") }
          } else if current != nil { throw self.failure("本地记忆已存在，请刷新后重试。") }
          let allowed = Set(["id", "createdAt", "updatedAt", "version", "deletedAt", "imageSha256",
            "sourcePackage", "sourceLabel", "visibleText", "sharedText", "urls", "title", "summary",
            "note", "notes", "analysisStatus", "analysisError", "analysisRequestId", "analysisConversationId",
            "analysisMessageId", "category", "sourceUrl", "videoStatus", "videoSummary", "videoError",
            "cloudVersion", "cloudRecordHash", "cloudImageSha256", "cloudDeletedAt", "cloudSyncError"])
          guard incoming.keys.allSatisfy({ allowed.contains($0) }) else { throw self.failure("云端字段无效。") }
          var record = current ?? [:]
          record.merge(incoming) { _, new in new }
          guard try JSONSerialization.data(withJSONObject: record).count <= 512 * 1024 else {
            throw self.failure("云端记忆过大。")
          }
          try self.write(record, id: id)
          result(record)
        case "storeCloudImage":
          let id = try self.identifier(arguments)
          var record = try self.read(id)
          let data = (arguments["bytes"] as? FlutterStandardTypedData)?.data ??
            (arguments["bytes"] as? String).flatMap { Data(base64Encoded: $0) }
          guard let bytes = data, !bytes.isEmpty, bytes.count <= 32 * 1024 * 1024,
                let sha = arguments["sha256"] as? String,
                let mime = arguments["mimeType"] as? String, ["image/png", "image/jpeg"].contains(mime),
                SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha.lowercased(),
                let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0 else {
            throw self.failure("云端图片校验失败。")
          }
          if let expectedHash = record["cloudImageSha256"] as? String, !expectedHash.isEmpty,
             expectedHash.lowercased() != sha.lowercased() { throw self.failure("云端图片版本已更新，请重试。") }
          let existing = try self.file(id, extension: "png")
          if self.manager.fileExists(atPath: existing.path) {
            // Keep the local original; cloud bytes are the compressed upload copy.
            result(existing.path)
          } else {
            try bytes.write(to: existing, options: .atomic)
            try self.manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path)
            record["imagePath"] = existing.path
            record["cloudImageSha256"] = sha.lowercased()
            try self.write(record, id: id)
            result(existing.path)
          }
        case "delete":
          let id = try self.identifier(arguments)
          let file = try self.file(id, extension: "json")
          try self.manager.removeItem(at: file)
          let image = try self.file(id, extension: "png")
          if self.manager.fileExists(atPath: image.path) { try self.manager.removeItem(at: image) }
          result(nil)
        case "prepareUpload":
          let id = try self.identifier(arguments)
          let image = try self.file(id, extension: "png")
          guard self.manager.fileExists(atPath: image.path) else { throw self.failure("截图文件已不存在。") }
          result(try DesktopMemoryImage.uploadCopy(of: image).path)
        case "capture", "captureSelection": self.capture(selection: call.method == "captureSelection", result: result)
        case "openCaptureSettings":
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
          result(nil)
        case "takePendingRoute": result(nil)
        case "requestAddTile": result(false)
        default: result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "memory_failed", message: error.localizedDescription, details: nil))
      }
    }
    do { try registerHotKeys() }
    catch {
      DispatchQueue.main.async { [weak self] in self?.showCaptureAlert(error.localizedDescription) }
    }
  }

  deinit { unregisterHotKeys() }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "OrialisMemory", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func normalizedCloudValue(_ value: Any?, key: String) -> Data {
    var item = value ?? NSNull()
    if let text = item as? String {
      if text.isEmpty { item = NSNull() }
      else if key == "createdAt" {
        item = text.replacingOccurrences(of: "(\\.\\d*?[1-9])0+Z$", with: "$1Z", options: .regularExpression)
          .replacingOccurrences(of: "\\.0+Z$", with: "Z", options: .regularExpression)
      }
    }
    return (try? JSONSerialization.data(withJSONObject: [item], options: [.sortedKeys])) ?? Data()
  }

  private func identifier(_ arguments: [String: Any]) throws -> String {
    guard let id = arguments["id"] as? String, UUID(uuidString: id) != nil else {
      throw failure("记忆编号不正确。")
    }
    return id
  }

  private func file(_ id: String, extension suffix: String) throws -> URL {
    guard UUID(uuidString: id) != nil, let directory = directory else {
      throw failure("请先登录，再记录记忆。")
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    return directory.appendingPathComponent("\(id).\(suffix)")
  }

  private func readURL(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
      throw failure("记忆文件格式不正确。")
    }
    return object
  }

  private func read(_ id: String) throws -> [String: Any] { try readURL(file(id, extension: "json")) }

  private func write(_ record: [String: Any], id: String) throws {
    let url = try file(id, extension: "json")
    try JSONSerialization.data(withJSONObject: record).write(to: url, options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func selectedText() throws -> String {
    guard AXIsProcessTrusted() else {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      throw failure("请在系统设置的“辅助功能”中允许 Orialis 读取选中文字，然后重试快捷键。")
    }
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused = focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
      throw failure("当前应用没有可读取的选中文字。")
    }
    let element = unsafeBitCast(focused, to: AXUIElement.self)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
          let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw failure("请先选中文字；当前应用也可能不支持读取选择内容。")
    }
    return text
  }

  private func capture(selection: Bool, result: FlutterResult? = nil) {
    guard !capturing else { result?(FlutterError(code: "capture_busy", message: "正在记录，请稍候。", details: nil)); return }
    guard let capturedScope = scope else {
      report(failure("请先登录，再记录记忆。"), result: result); return
    }
    let id = UUID().uuidString
    let source = NSWorkspace.shared.frontmostApplication
    do {
      var record: [String: Any] = ["id": id, "createdAt": ISO8601DateFormatter().string(from: Date()),
        "sourcePackage": source?.bundleIdentifier ?? "macos", "sourceLabel": source?.localizedName ?? "Mac",
        "visibleText": "", "urls": [], "title": selection ? "选中文字记忆" : "屏幕记忆", "notes": "", "analysisStatus": "pending"]
      if selection {
        let text = try selectedText()
        record["visibleText"] = text
        record["sharedText"] = text
        try write(record, id: id)
        channel.invokeMethod("memoryChanged", arguments: ["id": id])
        result?(nil)
        return
      }
      guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        throw failure("请在系统设置的“屏幕与系统音频录制”中允许 Orialis，然后重试快捷键。")
      }
      let image = try file(id, extension: "png")
      capturing = true
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-D", "1", image.path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { [weak self] process in
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.capturing = false
          guard self.scope == capturedScope else {
            try? self.manager.removeItem(at: image)
            result?(FlutterError(code: "scope_changed", message: "账号已切换，截图未保存。", details: nil)); return
          }
          do {
            guard process.terminationStatus == 0, self.manager.fileExists(atPath: image.path) else {
              throw self.failure("屏幕记录未完成，请检查屏幕录制权限。")
            }
            record["imagePath"] = image.path
            try self.manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
            try self.write(record, id: id)
            self.channel.invokeMethod("memoryChanged", arguments: ["id": id])
            result?(nil)
          } catch {
            try? self.manager.removeItem(at: image)
            self.report(error, result: result)
          }
        }
      }
      do { try process.run() } catch { capturing = false; throw error }
    } catch { report(error, result: result) }
  }

  private func report(_ error: Error, result: FlutterResult?) {
    let message = error.localizedDescription
    if let result = result { result(FlutterError(code: "capture_failed", message: message, details: nil)) }
    else {
      channel.invokeMethod("captureError", arguments: ["code": "capture_failed", "message": message])
      showCaptureAlert(message)
    }
  }

  private func showCaptureAlert(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Orialis 记忆"
    alert.informativeText = message
    alert.alertStyle = .informational
    alert.addButton(withTitle: "知道了")
    alert.runModal()
  }

  private func registerHotKeys() throws {
    var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
      guard let event = event, let pointer = pointer else { return OSStatus(eventNotHandledErr) }
      var identifier = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &identifier)
      let bridge = Unmanaged<DesktopMemoryBridge>.fromOpaque(pointer).takeUnretainedValue()
      NSLog("[OrialisMemory] Received capture shortcut %u", identifier.id)
      bridge.capture(selection: identifier.id == 2)
      return noErr
    }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard handlerStatus == noErr else {
      NSLog("[OrialisMemory] Hotkey event handler installation failed: %d", handlerStatus)
      throw failure("记忆快捷键未能初始化，请重新启动 Orialis。")
    }
    do { try registerKeys(shortcuts) }
    catch { unregisterKeyReferences(); throw error }
  }

  private func registerKeys(_ values: [String: MemoryShortcut]) throws {
    for (name, id) in [("screen", UInt32(1)), ("selection", UInt32(2))] {
      guard let shortcut = values[name] else { throw failure("快捷键配置不完整。") }
      var reference: EventHotKeyRef?
      let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
        EventHotKeyID(signature: 0x4f52494d, id: id), GetApplicationEventTarget(), 0, &reference)
      guard status == noErr, let reference = reference else {
        NSLog("[OrialisMemory] Capture shortcut %u registration failed: %d", id, status)
        throw failure("记忆快捷键注册失败，可能已被其他应用占用。可在记忆页更改快捷键。")
      }
      hotKeys.append(reference)
      NSLog("[OrialisMemory] Capture shortcut %u registered", id)
    }
  }

  private func unregisterKeyReferences() {
    for reference in hotKeys { UnregisterEventHotKey(reference) }
    hotKeys.removeAll()
  }

  private func unregisterHotKeys() {
    unregisterKeyReferences()
    if let handler = handler { RemoveEventHandler(handler) }
    handler = nil
  }
}


private enum DesktopMemoryImage {
  static func uploadCopy(of original: URL) throws -> URL {
    guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else {
      throw error("截图文件无法读取。")
    }
    // Keep the original intact; only the temporary upload must fit the server limit.
    for dimension in [1600, 1280, 1024, 800, 640, 480] {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: dimension,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw error("截图压缩未能完成。")
      }
      let bitmap = NSBitmapImageRep(cgImage: thumbnail)
      for quality in [0.75, 0.60, 0.45, 0.30] {
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
              !data.isEmpty, data.count < 900 * 1024,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else { continue }
        let upload = FileManager.default.temporaryDirectory
          .appendingPathComponent("orialis-upload-\(UUID().uuidString).jpg")
        try data.write(to: upload, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: upload.path)
        return upload
      }
    }
    throw error("截图压缩后仍超过上传限制，请重新记录较小的画面。")
  }

  private static func error(_ message: String) -> NSError {
    NSError(domain: "OrialisMemory", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
  }
}


private struct MemoryShortcut: Equatable {
  let key: String
  let command: Bool
  let option: Bool
  let shift: Bool
  let control: Bool

  static let defaults = [
    "screen": MemoryShortcut(key: "M", command: true, option: true, shift: false, control: false),
    "selection": MemoryShortcut(key: "N", command: true, option: true, shift: false, control: false),
  ]
  private static let codes: [String: Int] = [
    "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D,
    "E": kVK_ANSI_E, "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H,
    "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
    "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P,
    "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
    "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
    "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
    "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
    "8": kVK_ANSI_8, "9": kVK_ANSI_9,
  ]
  var keyCode: UInt32 { UInt32(Self.codes[key]!) }
  var modifiers: UInt32 {
    UInt32((command ? cmdKey : 0) | (option ? optionKey : 0) |
           (shift ? shiftKey : 0) | (control ? controlKey : 0))
  }
  var dictionary: [String: Any] {
    ["key": key, "command": command, "option": option, "shift": shift, "control": control]
  }
  static func parsePair(_ arguments: [String: Any]) throws -> [String: MemoryShortcut] {
    var values: [String: MemoryShortcut] = [:]
    for name in ["screen", "selection"] {
      guard let raw = arguments[name] as? [String: Any],
            let key = raw["key"] as? String, codes[key] != nil,
            let command = raw["command"] as? Bool, let option = raw["option"] as? Bool,
            let shift = raw["shift"] as? Bool, let control = raw["control"] as? Bool,
            command || option || control else { throw invalid() }
      values[name] = MemoryShortcut(key: key, command: command, option: option, shift: shift, control: control)
    }
    guard values["screen"] != values["selection"] else { throw invalid() }
    return values
  }
  private static func invalid() -> NSError {
    NSError(domain: "OrialisMemory", code: 3, userInfo: [NSLocalizedDescriptionKey:
      "请选择 A–Z 或 0–9，并至少搭配 Command、Option、Control 中的一项；两个快捷键不能相同。"])
  }
}
