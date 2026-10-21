import 'package:flutter/services.dart';

/// The small platform boundary keeps the screen independent from iOS callbacks.
abstract interface class NativeSystemApi {
  Stream<Map<String, dynamic>> get speechEvents;
  Future<List<Uint8List>> openCamera();
  Future<List<Uint8List>> pickPhotos();
  Future<DateTime> scheduleNotification(DateTime requestedAt);
  Future<bool> prepareSpeech();
  Future<bool> startSpeech(int sessionId);
  Future<void> stopSpeech(int sessionId);
  Future<void> openSettings();
}

class IOSNativeSystemApi implements NativeSystemApi {
  static const _methods = MethodChannel('naive_system_call/methods');
  static const _events = EventChannel('naive_system_call/speech');

  @override
  late final Stream<Map<String, dynamic>> speechEvents = _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  Future<List<Uint8List>> _images(String method) async {
    final images = await _methods.invokeListMethod<Uint8List>(method);
    return images ?? <Uint8List>[];
  }

  @override
  Future<List<Uint8List>> openCamera() => _images('openCamera');

  @override
  Future<List<Uint8List>> pickPhotos() => _images('pickPhotos');

  @override
  Future<DateTime> scheduleNotification(DateTime requestedAt) async {
    final timestamp = await _methods.invokeMethod<int>('scheduleNotification', {
      'requestedAt': requestedAt.millisecondsSinceEpoch,
    });
    if (timestamp == null) {
      throw PlatformException(code: 'notification_failed', message: '系统未能安排通知');
    }
    return DateTime.fromMillisecondsSinceEpoch(timestamp);
  }

  @override
  Future<bool> prepareSpeech() async =>
      await _methods.invokeMethod<bool>('prepareSpeech') ?? false;

  @override
  Future<bool> startSpeech(int sessionId) async =>
      await _methods.invokeMethod<bool>('startSpeech', {
        'sessionId': sessionId,
        'locale': 'zh-CN',
      }) ??
      false;

  @override
  Future<void> stopSpeech(int sessionId) =>
      _methods.invokeMethod<void>('stopSpeech', {'sessionId': sessionId});

  @override
  Future<void> openSettings() => _methods.invokeMethod<void>('openSettings');
}
