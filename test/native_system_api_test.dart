import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:naive_system_call/native_system_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('naive_system_call/methods');
  late IOSNativeSystemApi api;
  late List<MethodCall> calls;

  setUp(() {
    api = IOSNativeSystemApi();
    calls = [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mock(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  test(
    'camera and picker decode typed image bytes and handle cancellation',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      mock((call) async => call.method == 'openCamera' ? [bytes] : null);
      expect(await api.openCamera(), [bytes]);
      expect(await api.pickPhotos(), isEmpty);
      expect(calls.map((call) => call.method), ['openCamera', 'pickPhotos']);
    },
  );

  test(
    'notification passes the original tap timestamp through the channel',
    () async {
      final requestedAt = DateTime(2026, 10, 21, 14, 30, 15, 123);
      final expectedDelivery = requestedAt.add(const Duration(seconds: 10));
      mock((call) async => expectedDelivery.millisecondsSinceEpoch);
      expect(await api.scheduleNotification(requestedAt), expectedDelivery);
      expect(calls.single.method, 'scheduleNotification');
      expect(calls.single.arguments, {
        'requestedAt': requestedAt.millisecondsSinceEpoch,
      });
    },
  );

  test(
    'missing notification delivery time is reported as a platform failure',
    () async {
      mock((call) async => null);
      await expectLater(
        api.scheduleNotification(DateTime(2026, 10, 21)),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'notification_failed',
          ),
        ),
      );
    },
  );

  test(
    'speech methods retain session IDs and request Mandarin recognition',
    () async {
      mock(
        (call) async => switch (call.method) {
          'prepareSpeech' || 'startSpeech' => true,
          _ => null,
        },
      );
      expect(await api.prepareSpeech(), isTrue);
      expect(await api.startSpeech(7), isTrue);
      await api.stopSpeech(7);
      await api.openSettings();
      expect(calls.map((call) => call.method), [
        'prepareSpeech',
        'startSpeech',
        'stopSpeech',
        'openSettings',
      ]);
      expect(calls[1].arguments, {'sessionId': 7, 'locale': 'zh-CN'});
      expect(calls[2].arguments, {'sessionId': 7});
    },
  );
}
