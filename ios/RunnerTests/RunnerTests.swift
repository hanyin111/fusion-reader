import Flutter
import UIKit
import XCTest
import CFNetwork
@testable import Runner

class RunnerTests: XCTestCase {

  func testSystemHTTPProxyEndpoint() {
    XCTAssertEqual(FusionSystemProxy.endpoint([[
      kCFProxyTypeKey as String: kCFProxyTypeHTTP as String,
      kCFProxyHostNameKey as String: "127.0.0.1",
      kCFProxyPortNumberKey as String: NSNumber(value: 7890)
    ]]), "127.0.0.1:7890")
  }

  func testIPv6ProxyEndpoint() {
    XCTAssertEqual(FusionSystemProxy.endpoint([[
      kCFProxyTypeKey as String: kCFProxyTypeHTTPS as String,
      kCFProxyHostNameKey as String: "::1",
      kCFProxyPortNumberKey as String: NSNumber(value: 7891)
    ]]), "[::1]:7891")
  }

  func testDirectAndUnsupportedRoutesDoNotBecomeHTTPProxies() {
    for type in [kCFProxyTypeNone, kCFProxyTypeSOCKS, kCFProxyTypeAutoConfigurationURL] {
      XCTAssertEqual(FusionSystemProxy.endpoint([[
        kCFProxyTypeKey as String: type as String,
        kCFProxyHostNameKey as String: "127.0.0.1",
        kCFProxyPortNumberKey as String: NSNumber(value: 7890)
      ]]), "")
    }
  }

}
