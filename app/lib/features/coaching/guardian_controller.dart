import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'coaching_signaling.dart';

/// 보호자 모드 단계.
enum GuardianPhase {
  /// 대기 — 요청이 오기를 기다린다. 보호자가 먼저 세션을 열 수는 없다(ADR-17).
  idle,

  /// 어르신이 부르는 중.
  incoming,

  /// 수락함 — 통화를 걸고 코칭을 시작한다.
  connected,
}

/// 어르신이 보낸 등록 요청(사전 A) — 보호자가 확인해야 키가 교환된다.
class PairRequest {
  const PairRequest({required this.elderDeviceKey, required this.elderName});

  final String elderDeviceKey;
  final String elderName;
}

/// 보호자 기기의 코칭 상태기계.
///
/// 어르신 기기와 대칭이 아니다 — **보호자는 세션을 열 수 없고**, 들어온 요청에
/// 응답만 한다. 화면은 받기만 하며(recvonly) 보내는 트랙도, 데이터 채널도 열지
/// 않는다. 이 연결로 어르신 기기 상태를 바꿀 수 없다(ADR-16).
class GuardianController extends ChangeNotifier {
  GuardianController({required CoachingSignaling signaling})
      : _signaling = signaling;

  final CoachingSignaling _signaling;

  StreamSubscription<SignalMessage>? _sub;
  RTCPeerConnection? _pc;

  /// 어르신 화면을 그릴 렌더러 — 화면이 도착하면 붙는다.
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  bool _rendererReady = false;

  GuardianPhase _phase = GuardianPhase.idle;
  GuardianPhase get phase => _phase;

  PairRequest? _pair;

  /// 처리를 기다리는 등록 요청.
  PairRequest? get pendingPair => _pair;

  String _elderKey = '';
  String _sessionId = '';
  bool _receiving = false;

  /// 지금 어르신 화면이 들어오고 있는가.
  bool get receiving => _receiving;

  String get elderKey => _elderKey;

  Future<void> start({required String deviceKey}) async {
    await renderer.initialize();
    _rendererReady = true;
    // **구독을 연결보다 먼저 건다.** connect는 실패 시 재시도를 예약하고 다시
    // 던지는데, 구독이 뒤에 있으면 그 예외로 여기서 빠져나가 리스너가 영영 붙지
    // 않는다. 백오프가 소켓을 되살려 서버에는 보호자로 등록되지만 앱에는 듣는
    // 사람이 없어, 어르신의 페어링·도움요청이 조용히 버려진다.
    await _sub?.cancel();
    _sub = _signaling.messages.listen(_onMessage);
    await _signaling.connect(deviceKey: deviceKey, role: 'guardian');
  }

  void _onMessage(SignalMessage message) {
    switch (message.type) {
      case 'pair_request':
        _pair = PairRequest(
          elderDeviceKey: message.data['fromDeviceKey'] as String? ?? '',
          elderName: message.data['elderName'] as String? ?? '어르신',
        );
        notifyListeners();
      case 'help_request':
        _elderKey = message.data['fromDeviceKey'] as String? ?? '';
        _sessionId = message.sessionId ?? '';
        _set(GuardianPhase.incoming);
      case 'offer':
        unawaited(_onOffer(message));
      case 'ice':
        unawaited(_onIce(message));
      case 'end':
      case 'disconnected':
        unawaited(hangUp(notify: true));
    }
  }

  /// 사전 A — 어르신이 보낸 등록 요청을 보호자가 확인한다.
  ///
  /// **응답 대상을 인자로 받는다.** 현재 [pendingPair]를 다시 읽으면, 확인 창이 떠
  /// 있는 사이 다른 어르신의 요청이 도착했을 때 화면에 보인 사람과 실제 등록되는
  /// 사람이 어긋난다(보호자가 A를 보고 수락했는데 B가 등록된다). 그 사이 대상이
  /// 바뀌었으면 아무것도 보내지 않는다 — 잘못 등록하느니 실패하는 편이 낫다.
  Future<void> acceptPair(PairRequest pair) => _answerPair(pair, 'pair_ok');

  Future<void> declinePair(PairRequest pair) => _answerPair(pair, 'pair_no');

  Future<void> _answerPair(PairRequest pair, String type) async {
    if (_pair?.elderDeviceKey != pair.elderDeviceKey) return;
    _pair = null;
    await _send(type, {'toDeviceKey': pair.elderDeviceKey});
    notifyListeners();
  }

  /// 어르신의 부름을 받는다. 서버가 guardianDeviceKey를 채워 어르신에게 보내고,
  /// 어르신 기기가 그 값을 자기가 등록한 키와 대조한다(ADR-21).
  Future<void> accept() async {
    if (_phase != GuardianPhase.incoming) return;
    await _send('accepted', {'sessionId': _sessionId});
    _set(GuardianPhase.connected);
  }

  Future<void> decline() async {
    if (_phase != GuardianPhase.incoming) return;
    await _send('declined', {'sessionId': _sessionId});
    _set(GuardianPhase.idle);
  }

  Future<void> hangUp({bool notify = false}) async {
    if (!notify && _phase == GuardianPhase.connected) {
      await _send('end', {'sessionId': _sessionId});
    }
    _receiving = false;
    if (_rendererReady) renderer.srcObject = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    _sessionId = '';
    _set(GuardianPhase.idle);
  }

  /// 어르신 기기가 보낸 화면 제안 — **받기만 하는** 연결을 만든다.
  Future<void> _onOffer(SignalMessage message) async {
    final sdp = message.data['sdp'] as String?;
    if (sdp == null) return;

    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      unawaited(_send('ice', {
        'sessionId': _sessionId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }));
    };
    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      if (_rendererReady) renderer.srcObject = event.streams.first;
      _receiving = true;
      notifyListeners();
    };

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await _send('answer', {
      'sessionId': _sessionId,
      'sdp': answer.sdp,
      'sdpType': answer.type,
    });
  }

  Future<void> _onIce(SignalMessage message) async {
    final pc = _pc;
    final candidate = message.data['candidate'] as String?;
    if (pc == null || candidate == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        candidate,
        message.data['sdpMid'] as String?,
        message.data['sdpMLineIndex'] as int?,
      ));
    } catch (_) {}
  }

  Future<void> _send(String type, Map<String, dynamic> data) async {
    try {
      await _signaling.send(SignalMessage(type, data));
    } catch (_) {}
  }

  void _set(GuardianPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_pc?.close());
    if (_rendererReady) renderer.dispose();
    super.dispose();
  }
}
