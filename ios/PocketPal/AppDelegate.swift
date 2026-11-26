import UIKit
import Metal
import RNFBAppCheck
import FirebaseCore
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    configureGgmlMetal()

    // ANTICHAT: no Firebase at launch. Upstream configured Firebase and App Check
    // here for benchmark uploads; AntiChat has no server and never uploads.
    // (Upstream: RNFBAppCheckModule.sharedInstance(); FirebaseApp.configure())

    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

    // ANTICHAT: the window is created in ios/AntiChat/SceneDelegate.swift; apps built
    // with the iOS 27 SDK trap at launch without the UIScene lifecycle.

    return true
  }

  private func configureGgmlMetal() {
    setenv("WSP_GGML_METAL_TENSOR_DISABLE", "1", 1)
    var iOS18OrLater = false
    if #available(iOS 18.0, *) {
      iOS18OrLater = true
    }
    let supportsApple6 = iOS18OrLater && (MTLCreateSystemDefaultDevice()?.supportsFamily(.apple6) ?? false)
    if disablesGgmlMetal(iOS18OrLater: iOS18OrLater, supportsApple6: supportsApple6) {
      setenv("GGML_METAL_DEVICES", "0", 1)
      setenv("WSP_GGML_METAL_DEVICES", "0", 1)
    }
  }

  // MARK: - Deep Linking Support

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    // Handle deep links from Shortcuts
    if url.scheme == "pocketpal" {
      NotificationCenter.default.post(
        name: NSNotification.Name("RCTOpenURLNotification"),
        object: nil,
        userInfo: ["url": url]
      )
      return true
    }

    // Handle other URL schemes (e.g., Google Sign-In)
    return false
  }

  func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    return false
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
