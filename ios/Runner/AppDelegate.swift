import FirebaseCore
import FirebaseMessaging
import Flutter
import UIKit
import PushKit
import UserNotifications
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate {
  private var voipRegistry: PKPushRegistry?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
    GeneratedPluginRegistrant.register(with: self)
    Messaging.messaging().delegate = self

    let registry = PKPushRegistry(queue: DispatchQueue.main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - UNUserNotificationCenter (CallKit missed-call UI)

  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.trigger is UNPushNotificationTrigger {
      let userInfo = notification.request.content.userInfo
      let kind = AppDelegate.classifyNotificationPayload(userInfo)
      let isIncomingCall = kind == .incomingCall

      #if DEBUG
      let type = String(describing: userInfo["type"] ?? "")
      let notificationType = String(describing: userInfo["notificationType"] ?? "")
      print("[fcm-ios] willPresent type=\(type) notificationType=\(notificationType)")
      #endif

      if isIncomingCall {
        // Call pushes should be handled only by PushKit/CallKit path.
        // Suppress normal APNs/FCM foreground banner to avoid duplicates.
        completionHandler([])
      } else {
        // Normal chat/mail/other Firebase pushes should present normally.
        if #available(iOS 14.0, *) {
          completionHandler([.banner, .list, .sound, .badge])
        } else {
          completionHandler([.alert, .sound, .badge])
        }
      }
      return
    }

    CallkitNotificationManager.shared.userNotificationCenter(
      center,
      willPresent: notification,
      withCompletionHandler: completionHandler
    )
  }

  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == CallkitNotificationManager.CALLBACK_ACTION {
      let data = response.notification.request.content.userInfo as? [String: Any]
      SwiftFlutterCallkitIncomingPlugin.sharedInstance?.sendCallbackEvent(data)
    }
    #if DEBUG
    let userInfo = response.notification.request.content.userInfo
    let kind = AppDelegate.classifyNotificationPayload(userInfo)
    print("[fcm-ios] didReceive response action=\(response.actionIdentifier) kind=\(kind.rawValue) userInfo=\(userInfo)")
    #endif
    completionHandler()
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    #if DEBUG
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    print("[fcm-ios] APNs token registered: \(token)")
    #endif
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    #if DEBUG
    print("[fcm-ios] APNs registration failed: \(error.localizedDescription)")
    #endif
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // MARK: - PushKit (VoIP) — required for CallKit when app is killed/background

  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    #if DEBUG
    print("[voip-ios] pushRegistry didReceiveIncomingPush type=\(type.rawValue) payload=\(payload.dictionaryPayload)")
    #endif
    guard type == .voIP else {
      completion()
      return
    }
    guard let data = AppDelegate.buildCallData(fromVoipPayload: payload.dictionaryPayload) else {
      completion()
      return
    }
    var completed = false
    let finishOnce: () -> Void = {
      if completed { return }
      completed = true
      completion()
    }
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true) {
      #if DEBUG
      print("[voip-ios] showCallkitIncoming completed callId=\(String(describing: data.extra?["callId"]))")
      #endif
      finishOnce()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      finishOnce()
    }
  }

  /// Maps server VoIP payload → CallKit `Data`. Expected keys: callId (or id), callerName, channelName, token, uid, …
  private static func buildCallData(fromVoipPayload payload: [AnyHashable: Any]) -> flutter_callkit_incoming.Data? {
    var dict: [String: Any] = [:]
    for (key, value) in payload {
      if let k = key as? String {
        dict[k] = value
      }
    }
    if let nested = dict["data"] as? [String: Any] {
      for (k, v) in nested {
        dict[k] = v
      }
    }

    let callId =
      (dict["callId"] as? String) ??
      (dict["call_id"] as? String) ??
      (dict["id"] as? String) ??
      (dict["channelName"] as? String) ??
      (dict["channelId"] as? String) ??
      ""
    if callId.isEmpty { return nil }
    let callKitIdCandidate = (dict["callKitId"] as? String) ?? (dict["uuid"] as? String) ?? ""
    let callKitId = UUID(uuidString: callKitIdCandidate) != nil ? callKitIdCandidate : UUID().uuidString

    let callTypeRaw = (
      (dict["callType"] as? String) ??
      (dict["mediaType"] as? String) ??
      ""
    ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let isVideo = callTypeRaw == "video" || (dict["isVideo"] as? Bool == true)

    let nameCaller =
      (dict["callerName"] as? String) ?? (dict["nameCaller"] as? String) ?? (isVideo ? "Incoming video call" : "Incoming call")
    let handle =
      (dict["callerId"] as? String) ?? (dict["handle"] as? String) ?? (isVideo ? "Incoming video call" : "LivConnect")

    let data = flutter_callkit_incoming.Data(
      id: callKitId,
      nameCaller: nameCaller,
      handle: handle,
      type: isVideo ? 1 : 0
    )
    data.appName = "LivConnect"
    data.supportsVideo = isVideo
    if let avatar = (dict["callerAvatar"] as? String) ?? (dict["avatar"] as? String) {
      data.avatar = avatar
    }

    var durationMs = 30000
    if let sec = dict["timeoutSeconds"] as? Int {
      durationMs = sec * 1000
    } else if let s = dict["timeoutSeconds"] as? String, let v = Int(s) {
      durationMs = v * 1000
    }
    durationMs = min(120_000, max(15_000, durationMs))
    data.duration = durationMs
    data.iconName = "CallKitLogo"

    var extraStrings: [String: String] = [:]
    for (k, v) in dict {
      extraStrings[k] = "\(v)"
    }
    extraStrings["callId"] = callId
    extraStrings["callKitId"] = callKitId
    extraStrings["callType"] = isVideo ? "video" : "audio"
    extraStrings["type"] = isVideo ? "incoming_video_call" : "incoming_voice_call"
    extraStrings["notificationType"] = "incoming_call"
    data.extra = extraStrings as NSDictionary

    return data
  }

  private enum NotificationKind: String {
    case incomingCall = "incoming_call"
    case normal = "normal"
  }

  private static func classifyNotificationPayload(_ userInfo: [AnyHashable: Any]) -> NotificationKind {
    var root: [String: Any] = [:]
    for (k, v) in userInfo {
      if let ks = k as? String {
        root[ks] = v
      }
    }
    if let nested = root["data"] as? [String: Any] {
      for (k, v) in nested {
        root[k] = v
      }
    }
    if let custom = root["custom"] as? [String: Any] {
      for (k, v) in custom {
        root[k] = v
      }
    }
    let type = String(describing: root["type"] ?? "").lowercased()
    let notificationType = String(describing: root["notificationType"] ?? "").lowercased()
    let event = String(describing: root["event"] ?? "").lowercased()
    let category = String(describing: root["category"] ?? "").lowercased()
    let kindValues = [type, notificationType, event, category]
    if kindValues.contains("incoming_call") ||
      kindValues.contains("incoming_voice_call") ||
      kindValues.contains("incoming_video_call") {
      return .incomingCall
    }
    return .normal
  }
}

extension AppDelegate: MessagingDelegate {
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    #if DEBUG
    print("[fcm-ios] MessagingDelegate FCM token: \(fcmToken ?? "")")
    #endif
  }
}
