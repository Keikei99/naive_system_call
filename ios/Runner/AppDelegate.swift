import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeSystemPlugin") {
      NativeSystemPlugin.register(with: registrar)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.identifier.hasPrefix("naive_system_call.") {
      completionHandler([.banner, .list, .sound])
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.notification.request.identifier.hasPrefix("naive_system_call.") {
      completionHandler()
    } else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
    }
  }
}
