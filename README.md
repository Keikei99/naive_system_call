# iOS 原生系统调用 Demo

在 Flutter 页面中通过 `MethodChannel` / `EventChannel` 调用 Swift 与 Apple 系统框架。测试环境使用 iOS 27，当前使用 Flutter 3.47.5 / Dart 3.13.4。无需额外第三方插件。

## 四个按钮

| 功能 | 体验 | 原生接口 |
| --- | --- | --- |
| 摄像头 | 打开系统相机；拍摄后显示缩略图；取消不添加照片 | `UIImagePickerController`、`AVCaptureDevice` |
| 照片库 | 每次最多多选 9 张照片，追加到预览区；右上角 × 仅移除应用中的缩略图 | `PHPickerViewController`、`ImageIO` |
| 测试通知 | 点击后 10 秒安排一次本地通知；应用在前台或后台均可展示 | `UNUserNotificationCenter` |
| 语音识别 | 长按识别普通话，实时显示文本；松手立即停止并保留已识别内容 | `SFSpeechRecognizer`、`AVAudioEngine` |

照片只保留压缩后的预览数据，不保存到系统照片库；重启应用后清空。PHPicker 只读取用户选中的照片，无需授予整个照片库的访问权限。

## 运行

```sh
cd /Users/keikei/Codes/flutter_learn/naive_system_call
flutter pub get
flutter run
```

摄像头请使用 iPhone 真机。模拟器可检查页面、照片选择和本地通知；麦克风与语音识别也建议在真机确认，语音服务可能需要网络。

首次长按语音按钮会请求麦克风与语音识别权限；授权弹窗会中断当前按住动作，授权完成后重新长按即可。松手、手势取消、进入后台、系统音频中断和页面销毁都会停止录音。拒绝权限后，页面提供“前往设置”。旧会话的结果不会覆盖新会话或松手后的文本。

## 文件

- `lib/main.dart`：四项功能的页面、缩略图和长按会话状态。
- `lib/native_system_api.dart`：Flutter 侧原生接口封装。
- `ios/Runner/NativeSystemPlugin.swift`：Apple API 调用、权限和资源清理。
- `ios/Runner/AppDelegate.swift`：Flutter 隐式引擎注册、前台通知展示。
- `ios/Runner/Info.plist`：相机、麦克风和语音识别用途说明。

## 验证

```sh
flutter analyze
flutter test
flutter build ios --simulator --debug
```

## 参考

- [Flutter：Apple 系统框架与插件对照](https://docs.flutter.dev/platform-integration/ios/apple-frameworks)
- [Flutter：平台通道](https://docs.flutter.dev/platform-integration/platform-channels)
- [Apple：照片选择器](https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios)
- [Apple：本地通知](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
- [Apple：语音识别授权](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
