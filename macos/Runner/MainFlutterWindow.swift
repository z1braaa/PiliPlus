import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private func applyOpaqueWindowAppearance() {
    // 恢复系统默认的不透明窗口背景
    self.isOpaque = true
    self.backgroundColor = .windowBackgroundColor

    // 正常显示标题栏时禁用透明效果
    if self.titleVisibility == .visible {
      self.titlebarAppearsTransparent = false
      self.styleMask.remove(.fullSizeContentView)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    // 先不显示窗口
    self.isReleasedWhenClosed = false
    self.contentViewController = flutterViewController
    self.setFrame(self.frame, display: true)

    applyOpaqueWindowAppearance()

    RegisterGeneratedPlugins(registry: flutterViewController)
    LiveIntimacyLifecycleBridge.install(flutterViewController.engine.binaryMessenger)

    // 监听首帧渲染完成再显示窗口
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("io.flutter.embedding.engine.firstFrame"),
      object: flutterViewController.engine, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // window_manager 配置完成后恢复不透明样式
      self.applyOpaqueWindowAppearance()
      self.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    // 不在这里调用 makeKeyAndOrderFront
    super.awakeFromNib()
  }
}

/// Power events are independent from visibility and window minimization.
enum LiveIntimacyLifecycleBridge {
  private static var channel: FlutterMethodChannel?
  private static var observers: [NSObjectProtocol] = []
  private static var terminating = false

  static func install(_ messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    channel = FlutterMethodChannel(name: "piliplus/live_intimacy_lifecycle", binaryMessenger: messenger)
    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
      channel?.invokeMethod("willSleep", arguments: nil)
    })
    observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
      channel?.invokeMethod("didWake", arguments: nil)
    })
  }

  static func requestTermination() -> NSApplication.TerminateReply {
    guard let channel else { return .terminateNow }
    if terminating { return .terminateLater }
    terminating = true
    var replied = false
    func finish() {
      if replied { return }
      replied = true
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    channel.invokeMethod("terminate", arguments: nil) { _ in finish() }
    // OS exit still stops all media if Dart or an HTTP request is unresponsive.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish() }
    return .terminateLater
  }
}
