import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      let urlString = context.url.absoluteString
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        NotificationCenter.default.post(
          name: NSNotification.Name(rawValue: "CRED_CALLBACK_NOTIFICATION"),
          object: nil,
          userInfo: ["response": urlString]
        )
      }
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
