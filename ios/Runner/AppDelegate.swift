import Flutter
import UIKit
import CFNetwork

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FusionSystemProxy") {
      FusionSystemProxy.register(with: registrar)
    }
  }
}

/// Expose the system HTTP proxy to Dart's socket-based HTTP client. This only
/// reads settings; it does not alter VPN settings or certificate validation.
final class FusionSystemProxy: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "fusion_reader/system_proxy", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(FusionSystemProxy(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "settings" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
      result(["http": "", "https": "", "bypass": []] as [String: Any])
      return
    }
    func address(_ scheme: String) -> String {
      // CFNetwork resolves the active system settings; no request is sent.
      let url = URL(string: "\(scheme)://fusion-proxy-probe.invalid/")!
      let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue()
      return FusionSystemProxy.endpoint(proxies as! [[String: Any]])
    }
    let values = settings as NSDictionary
    var bypass = values["ExceptionsList"] as? [String] ?? []
    if (values["ExcludeSimpleHostnames"] as? NSNumber)?.boolValue == true {
      bypass.append("<local>")
    }
    result(["http": address("http"), "https": address("https"), "bypass": bypass])
  }

  static func endpoint(_ proxies: [[String: Any]]) -> String {
    guard let proxy = proxies.first,
          let type = proxy[kCFProxyTypeKey as String] as? String,
          type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String),
          let host = proxy[kCFProxyHostNameKey as String] as? String,
          !host.isEmpty,
          let port = proxy[kCFProxyPortNumberKey as String] as? NSNumber,
          (1...65535).contains(port.intValue) else {
      // DIRECT and VPN/TUN routes stay with the OS. PAC/SOCKS are not
      // misinterpreted as a plain HTTP proxy.
      return ""
    }
    let authority = host.contains(":") ? "[\(host)]" : host
    return "\(authority):\(port.intValue)"
  }
}
