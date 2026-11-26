import UIKit

/// UIScene adoption for the upstream AppDelegate. Apps built with the iOS 27 SDK
/// trap at launch (UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption)
/// when they create their window in the app delegate.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    let window = UIWindow(windowScene: windowScene)
    self.window = window
    appDelegate.window = window
    appDelegate.reactNativeFactory?.startReactNative(
      withModuleName: "PocketPal",
      in: window,
      launchOptions: nil
    )
  }
}
