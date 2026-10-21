import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:naive_system_call/main.dart';
import 'package:naive_system_call/native_system_api.dart';

class FakeNativeSystemApi implements NativeSystemApi {
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  List<Uint8List> cameraImages = [];
  List<Uint8List> pickedImages = [];
  Object? cameraError;
  Completer<bool>? speechPreparation;
  Completer<bool>? speechStart;
  int cameraCalls = 0;
  int photoCalls = 0;
  int prepareCalls = 0;
  int settingsCalls = 0;
  final notificationRequests = <DateTime>[];
  final startedSessions = <int>[];
  final stoppedSessions = <int>[];

  @override
  Stream<Map<String, dynamic>> get speechEvents => events.stream;

  @override
  Future<List<Uint8List>> openCamera() async {
    cameraCalls++;
    if (cameraError case final error?) throw error;
    return cameraImages;
  }

  @override
  Future<List<Uint8List>> pickPhotos() async {
    photoCalls++;
    return pickedImages;
  }

  @override
  Future<DateTime> scheduleNotification(DateTime requestedAt) async {
    notificationRequests.add(requestedAt);
    return requestedAt.add(const Duration(seconds: 10));
  }

  @override
  Future<bool> prepareSpeech() async {
    prepareCalls++;
    return speechPreparation?.future ?? true;
  }

  @override
  Future<bool> startSpeech(int sessionId) async {
    startedSessions.add(sessionId);
    return speechStart?.future ?? true;
  }

  @override
  Future<void> stopSpeech(int sessionId) async {
    stoppedSessions.add(sessionId);
  }

  @override
  Future<void> openSettings() async {
    settingsCalls++;
  }

  void result(int sessionId, String text) {
    events.add({'type': 'result', 'sessionId': sessionId, 'text': text});
  }
}

Uint8List tinyPng() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQaPj/HwAFAgKfdqhGyQAAAABJRU5ErkJggg==',
);

Future<void> tapFeature(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<TestGesture> holdSpeech(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('speechButton'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  final gesture = await tester.startGesture(tester.getCenter(button));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await tester.pump();
  return gesture;
}

String transcript(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('transcriptField')))
    .controller!
    .text;

void testIOSWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

void main() {
  late FakeNativeSystemApi api;

  setUp(() {
    api = FakeNativeSystemApi();
  });

  tearDown(() async {
    await api.events.close();
  });

  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MyApp(nativeApi: api));
    await tester.pumpAndSettle();
  }

  testIOSWidgets('shows all four native features and a read-only transcript', (
    tester,
  ) async {
    await launch(tester);
    for (final key in [
      'cameraButton',
      'photosButton',
      'notificationButton',
      'speechButton',
      'transcriptField',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('transcriptField')))
          .readOnly,
      isTrue,
    );
  });

  testIOSWidgets('selected photos appear and can be removed independently', (
    tester,
  ) async {
    api.pickedImages = [tinyPng(), tinyPng()];
    await launch(tester);
    await tapFeature(tester, 'photosButton');
    expect(api.photoCalls, 1);
    expect(find.byKey(const ValueKey('removePhoto_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('removePhoto_1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('removePhoto_0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('removePhoto_0')), findsNothing);
    expect(find.byKey(const ValueKey('removePhoto_1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testIOSWidgets('camera captures join the selected-photo preview', (
    tester,
  ) async {
    api.cameraImages = [tinyPng()];
    api.pickedImages = [tinyPng()];
    await launch(tester);
    await tapFeature(tester, 'cameraButton');
    await tapFeature(tester, 'photosButton');
    expect(api.cameraCalls, 1);
    expect(find.byKey(const ValueKey('removePhoto_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('removePhoto_1')), findsOneWidget);
  });

  testIOSWidgets('notification is scheduled from the time of the button tap', (
    tester,
  ) async {
    await launch(tester);
    final beforeTap = DateTime.now();
    await tapFeature(tester, 'notificationButton');
    final afterTap = DateTime.now();
    expect(api.notificationRequests, hasLength(1));
    expect(api.notificationRequests.single.isBefore(beforeTap), isFalse);
    expect(api.notificationRequests.single.isAfter(afterTap), isFalse);
    expect(find.textContaining('通知已安排'), findsOneWidget);
  });

  testIOSWidgets(
    'holding streams recognition and releasing stops but retains text',
    (tester) async {
      await launch(tester);
      final gesture = await holdSpeech(tester);
      expect(api.prepareCalls, 1);
      expect(api.startedSessions, [1]);
      api.result(1, '这是一次语音识别测试');
      await tester.pump();
      expect(transcript(tester), '这是一次语音识别测试');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(api.stoppedSessions, contains(1));
      expect(transcript(tester), '这是一次语音识别测试');
      api.result(1, '松开后的过期结果');
      await tester.pump();
      expect(transcript(tester), '这是一次语音识别测试');
    },
  );

  testIOSWidgets(
    'releasing during permission preparation never starts recording',
    (tester) async {
      api.speechPreparation = Completer<bool>();
      await launch(tester);
      final gesture = await holdSpeech(tester);
      expect(api.prepareCalls, 1);
      await gesture.up();
      await tester.pump();
      api.speechPreparation!.complete(true);
      await tester.pumpAndSettle();
      expect(api.startedSessions, isEmpty);
    },
  );

  testIOSWidgets(
    'releasing during native startup ignores its eventual results',
    (tester) async {
      api.speechStart = Completer<bool>();
      await launch(tester);
      final gesture = await holdSpeech(tester);
      expect(api.startedSessions, [1]);
      await gesture.up();
      await tester.pump();
      expect(api.stoppedSessions, contains(1));

      api.speechStart!.complete(true);
      await tester.pumpAndSettle();
      api.result(1, '录音启动过迟，结果不应显示');
      await tester.pump();
      expect(transcript(tester), isEmpty);
    },
  );

  testIOSWidgets('old recognition sessions cannot overwrite a new hold', (
    tester,
  ) async {
    await launch(tester);
    final firstGesture = await holdSpeech(tester);
    api.result(1, '第一次识别');
    await tester.pump();
    await firstGesture.up();
    await tester.pumpAndSettle();
    final nextGesture = await holdSpeech(tester);
    expect(api.startedSessions, [1, 2]);
    final beforeOldEvent = transcript(tester);
    api.result(1, '旧会话不应覆盖新会话');
    await tester.pump();
    expect(transcript(tester), beforeOldEvent);
    api.result(2, '第二次识别');
    await tester.pump();
    expect(transcript(tester), '第二次识别');
    await nextGesture.up();
    await tester.pumpAndSettle();
  });

  testIOSWidgets('app inactivity stops speech and ignores later results', (
    tester,
  ) async {
    await launch(tester);
    final gesture = await holdSpeech(tester);
    api.result(1, '暂停前的识别');
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(api.stoppedSessions, contains(1));
    api.result(1, '退到后台后的结果');
    await tester.pump();
    expect(transcript(tester), '暂停前的识别');
    await gesture.up();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
  });

  testIOSWidgets(
    'app inactivity invalidates permission requests still in flight',
    (tester) async {
      api.speechPreparation = Completer<bool>();
      await launch(tester);
      final gesture = await holdSpeech(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      api.speechPreparation!.complete(true);
      await tester.pump();
      expect(api.startedSessions, isEmpty);
      await gesture.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    },
  );

  testIOSWidgets(
    'permission rejection after inactivity is reported without starting recording',
    (tester) async {
      api.speechPreparation = Completer<bool>();
      await launch(tester);
      final gesture = await holdSpeech(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();

      api.speechPreparation!.completeError(
        PlatformException(code: 'microphone_denied', message: '麦克风权限被拒绝'),
      );
      await tester.pump();
      expect(api.startedSessions, isEmpty);
      expect(find.text('麦克风权限被拒绝'), findsOneWidget);
      expect(find.text('前往设置'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await gesture.up();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    },
  );

  testIOSWidgets(
    'permission rejection offers a working system-settings action',
    (tester) async {
      api.cameraError = PlatformException(
        code: 'camera_permission_denied',
        message: '摄像头权限被拒绝',
      );
      await launch(tester);
      await tapFeature(tester, 'cameraButton');
      expect(find.textContaining('摄像头权限被拒绝'), findsOneWidget);
      final settingsAction = find.text('前往设置');
      expect(settingsAction, findsOneWidget);
      await tester.tap(settingsAction);
      await tester.pumpAndSettle();
      expect(api.settingsCalls, 1);
    },
  );
}
