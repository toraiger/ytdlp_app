import Flutter
import UIKit
import Network

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var networkPaths: NetworkPathStream?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let paths = NetworkPathStream()
      FlutterEventChannel(
        name: "jp.toraiger.mixPlayerApp/networkPath",
        binaryMessenger: controller.binaryMessenger
      ).setStreamHandler(paths)
      networkPaths = paths
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// One monitor per subscription. All mutable state and Flutter callbacks are
/// confined to the main queue; the monitor also runs while audio is backgrounded.
private final class NetworkPathStream: NSObject, FlutterStreamHandler {
  private var monitor: NWPathMonitor?
  private var generation = 0
  private var signature: String?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    monitor?.cancel()
    signature = nil
    let nextMonitor = NWPathMonitor()
    monitor = nextMonitor
    nextMonitor.pathUpdateHandler = { [weak self, weak nextMonitor] path in
      DispatchQueue.main.async {
        guard let self = self, let nextMonitor = nextMonitor,
              self.monitor === nextMonitor else { return }
        let interfaces: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        let pathSignature = "\(path.status)-\(interfaces.map { path.usesInterfaceType($0) })-\(path.isExpensive)-\(path.isConstrained)"
        guard self.signature != pathSignature else { return }
        self.signature = pathSignature
        self.generation += 1
        events(["generation": self.generation, "available": path.status == .satisfied])
      }
    }
    nextMonitor.start(queue: DispatchQueue(label: "mix-player.network-path"))
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    monitor?.cancel()
    monitor = nil
    signature = nil
    return nil
  }
}
