import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_system_api.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.nativeApi});
  final NativeSystemApi? nativeApi;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'iOS 原生调用 Demo',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF365BDC)),
      scaffoldBackgroundColor: const Color(0xFFF4F6FB),
      useMaterial3: true,
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF4F6FB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: NativeDemoPage(api: nativeApi ?? IOSNativeSystemApi()),
  );
}

class NativeDemoPage extends StatefulWidget {
  const NativeDemoPage({super.key, required this.api});
  final NativeSystemApi api;

  @override
  State<NativeDemoPage> createState() => _NativeDemoPageState();
}

class _NativeDemoPageState extends State<NativeDemoPage>
    with WidgetsBindingObserver {
  final _transcript = TextEditingController();
  final _photos = <({int id, Uint8List bytes})>[];
  StreamSubscription<Map<String, dynamic>>? _speechSubscription;
  int _nextPhotoId = 0;
  int _speechSequence = 0;
  int? _activeSpeechSession;
  bool _mediaBusy = false;
  bool _notificationBusy = false;
  bool _holding = false;
  bool _speechPreparing = false;
  String? _error;
  bool _permissionError = false;
  String _photoStatus = '选择的照片会显示在这里';
  String _notificationStatus = '允许通知后，点击即可安排一次测试提醒';
  String _speechStatus = '长按说话，松手停止，已识别的文字会保留';

  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get _canUseButtons => _isIOS && !_holding;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isIOS) {
      _speechSubscription = widget.api.speechEvents.listen(
        _onSpeechEvent,
        onError: (Object error) {
          if (_holding) {
            unawaited(_endSpeech());
            _showError(error);
          }
        },
      );
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() {
      if (error is PlatformException) {
        _error = error.message ?? '系统调用失败，请稍后重试';
        final code = error.code.toLowerCase();
        _permissionError =
            code.contains('denied') || code.contains('permission');
      } else if (error is MissingPluginException) {
        _error = '原生接口尚未加载，请在 iPhone 上完整重启应用';
        _permissionError = false;
      } else {
        _error = '操作未完成，请重试';
        _permissionError = false;
      }
    });
  }

  void _clearError() => setState(() {
    _error = null;
    _permissionError = false;
  });

  Future<void> _pickImages({required bool camera}) async {
    if (!_canUseButtons || _mediaBusy) return;
    _clearError();
    setState(() => _mediaBusy = true);
    try {
      final images = await (camera
          ? widget.api.openCamera()
          : widget.api.pickPhotos());
      if (!mounted) return;
      setState(() {
        for (final bytes in images) {
          _photos.add((id: _nextPhotoId++, bytes: bytes));
        }
        _photoStatus = images.isEmpty
            ? '已取消选择'
            : '已添加 ${images.length} 张，共 ${_photos.length} 张照片';
      });
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _mediaBusy = false);
    }
  }

  Future<void> _scheduleNotification() async {
    if (!_canUseButtons || _notificationBusy) return;
    final requestedAt = DateTime.now();
    _clearError();
    setState(() => _notificationBusy = true);
    try {
      final deadline = await widget.api.scheduleNotification(requestedAt);
      if (!mounted) return;
      final time = [
        deadline.hour,
        deadline.minute,
        deadline.second,
      ].map((part) => part.toString().padLeft(2, '0')).join(':');
      setState(() {
        _notificationStatus = '通知已安排，预计 $time 提醒；可留在应用或返回桌面';
      });
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _notificationBusy = false);
    }
  }

  Future<void> _beginSpeech() async {
    if (!_isIOS || _holding || _mediaBusy || _notificationBusy) return;
    final session = ++_speechSequence;
    _clearError();
    setState(() {
      _activeSpeechSession = session;
      _holding = true;
      _speechPreparing = true;
      _speechStatus = '正在准备麦克风与语音识别权限…';
    });
    try {
      final ready = await widget.api.prepareSpeech();
      // Permission dialogs may outlive the press. Never record after release.
      if (!mounted || !_holding || _activeSpeechSession != session) return;
      if (!ready) {
        await _endSpeech();
        return;
      }
      setState(() {
        _transcript.clear();
        _speechStatus = '正在启动识别…';
      });
      final started = await widget.api.startSpeech(session);
      if (!mounted || !_holding || _activeSpeechSession != session) return;
      if (!started) {
        await _endSpeech();
        return;
      }
      setState(() {
        _speechPreparing = false;
        _speechStatus = '正在识别普通话，松手即可停止';
      });
    } catch (error) {
      if (!mounted || _speechSequence != session) return;
      if (_activeSpeechSession == session) await _endSpeech();
      _showError(error);
    }
  }

  Future<void> _endSpeech() async {
    final session = _activeSpeechSession;
    if (session == null) return;
    setState(() {
      _activeSpeechSession = null;
      _holding = false;
      _speechStatus = _speechPreparing
          ? '准备已结束；完成权限确认后，请重新按住开始'
          : _transcript.text.isEmpty
          ? '已停止，未识别到文字；请重新按住说话'
          : '已停止，识别文字已保留';
      _speechPreparing = false;
    });
    try {
      await widget.api.stopSpeech(session);
    } catch (error) {
      _showError(error);
    }
  }

  void _onSpeechEvent(Map<String, dynamic> event) {
    if (!mounted || !_holding || event['sessionId'] != _activeSpeechSession) {
      return;
    }
    switch (event['type']) {
      case 'result':
        setState(() => _transcript.text = event['text'] as String? ?? '');
      case 'state':
        if (event['state'] == 'stopped') unawaited(_endSpeech());
      case 'error':
        unawaited(_endSpeech());
        _showError(
          PlatformException(
            code: event['code'] as String? ?? 'speech_failed',
            message: event['message'] as String? ?? '语音识别未完成，请重试',
          ),
        );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _holding) {
      unawaited(_endSpeech());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_speechSubscription?.cancel());
    final session = _activeSpeechSession;
    if (session != null) {
      unawaited(widget.api.stopSpeech(session).catchError((Object _) {}));
    }
    _transcript.dispose();
    super.dispose();
  }

  Widget _card({
    required String number,
    required IconData icon,
    required String title,
    required String description,
    required List<Widget> children,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    elevation: 0,
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: const BorderSide(color: Color(0xFFE7EAF3)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFEEF1FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFF365BDC)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(number, style: const TextStyle(color: Color(0xFF929BB2))),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(color: Color(0xFF69748C), height: 1.5),
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );

  Widget _thumbnails() => Wrap(
    spacing: 10,
    runSpacing: 10,
    children: [
      for (final photo in _photos)
        SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(
                  photo.bytes,
                  fit: BoxFit.cover,
                  cacheWidth: 288,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Color(0xFFEEF1FF),
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: IconButton.filled(
                  key: ValueKey('removePhoto_${photo.id}'),
                  tooltip: '移除照片',
                  onPressed: () => setState(() {
                    _photos.removeWhere((item) => item.id == photo.id);
                    _photoStatus = _photos.isEmpty
                        ? '选择的照片会显示在这里'
                        : '已选择 ${_photos.length} 张照片';
                  }),
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.65),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _speechButton() => Semantics(
    button: true,
    label: '长按开始语音识别，松手停止',
    child: GestureDetector(
      key: const ValueKey('speechButton'),
      behavior: HitTestBehavior.opaque,
      onLongPressStart: _isIOS && !_mediaBusy && !_notificationBusy
          ? (_) => unawaited(_beginSpeech())
          : null,
      onLongPressEnd: (_) => unawaited(_endSpeech()),
      onLongPressCancel: () => unawaited(_endSpeech()),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        constraints: const BoxConstraints(minHeight: 60),
        decoration: BoxDecoration(
          color: _holding
              ? const Color(0xFFD44353)
              : _isIOS && !_mediaBusy && !_notificationBusy
              ? const Color(0xFF365BDC)
              : Colors.grey,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _holding ? Icons.graphic_eq : Icons.mic,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _holding ? '正在聆听，松手结束' : '按住开始识别',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('iOS 原生调用'),
      backgroundColor: const Color(0xFFF4F6FB),
      centerTitle: false,
    ),
    bottomNavigationBar: _error == null
        ? null
        : SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              color: const Color(0xFFFFEDEA),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFA52C28)),
                    ),
                  ),
                  if (_permissionError)
                    TextButton(
                      onPressed: () async {
                        try {
                          await widget.api.openSettings();
                        } catch (error) {
                          _showError(error);
                        }
                      },
                      child: const Text('前往设置'),
                    ),
                  IconButton(
                    onPressed: _clearError,
                    tooltip: '关闭提示',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              const Text(
                '原生系统的四种能力',
                style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text(
                '相机调用、照片选取、通知推送与语音转文字。',
                style: TextStyle(color: Color(0xFF69748C)),
              ),
              const SizedBox(height: 24),
              if (!_isIOS)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text('请在 iPhone 或 iOS 模拟器上运行此 Demo。摄像头与语音建议使用真机。'),
                ),
              _card(
                number: '01',
                icon: Icons.camera_alt_outlined,
                title: '摄像头',
                description: '打开系统相机拍照，拍摄结果会加入下方缩略图。',
                children: [
                  FilledButton.icon(
                    key: const ValueKey('cameraButton'),
                    onPressed: _canUseButtons && !_mediaBusy
                        ? () => _pickImages(camera: true)
                        : null,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('打开摄像头'),
                  ),
                ],
              ),
              _card(
                number: '02',
                icon: Icons.photo_library_outlined,
                title: '照片库',
                description: '每次最多选择 9 张照片；点击右上角 × 移除缩略图。',
                children: [
                  FilledButton.icon(
                    key: const ValueKey('photosButton'),
                    onPressed: _canUseButtons && !_mediaBusy
                        ? () => _pickImages(camera: false)
                        : null,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(_mediaBusy ? '正在读取照片…' : '选择照片'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _photoStatus,
                    style: const TextStyle(color: Color(0xFF69748C)),
                  ),
                  if (_photos.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _thumbnails(),
                  ],
                ],
              ),
              _card(
                number: '03',
                icon: Icons.notifications_active_outlined,
                title: '测试通知',
                description: '点击后 10 秒发送本地通知。首次使用请先允许系统通知。',
                children: [
                  FilledButton.icon(
                    key: const ValueKey('notificationButton'),
                    onPressed: _canUseButtons && !_notificationBusy
                        ? _scheduleNotification
                        : null,
                    icon: const Icon(Icons.timer_outlined),
                    label: Text(_notificationBusy ? '正在安排…' : '10 秒后通知我'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _notificationStatus,
                    style: const TextStyle(
                      color: Color(0xFF69748C),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
              _card(
                number: '04',
                icon: Icons.mic_none_outlined,
                title: '语音识别',
                description: '长按下方按钮识别普通话，松手立即结束收音。',
                children: [
                  _speechButton(),
                  const SizedBox(height: 12),
                  Text(
                    _speechStatus,
                    style: const TextStyle(
                      color: Color(0xFF69748C),
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('transcriptField'),
                    controller: _transcript,
                    readOnly: true,
                    minLines: 4,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      hintText: '识别到的文字会实时显示在这里',
                      labelText: '识别结果',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
