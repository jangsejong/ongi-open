import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../native/ongi_native.g.dart';
import 'coaching_signaling.dart';

/// 어르신 기기 → 보호자 기기 **보기 전용** 화면 송출(50_guardian_coaching.md §10).
///
/// 단방향이다. 보호자 쪽에서 들어오는 미디어·데이터 채널을 열지 않으므로,
/// 이 연결로는 기기 상태를 바꿀 수 없다(ADR-16).
///
/// OS 동의는 flutter_webrtc가 띄우며(공유를 시작할 때마다 [start]가 먼저 받는다),
/// Android 14+는 캡처 세션마다 이를 강제한다 — "그 순간만"을 플랫폼이 보증하는
/// 지점이다(ADR-15).
class ScreenShare {
  ScreenShare({
    required CoachingSignaling signaling,
    CoachingApi? native,
    Future<bool> Function()? requestConsent,
    this.onCaptureEnded,
  })  : _signaling = signaling,
        _native = native ?? CoachingApi(),
        _requestConsent = requestConsent ?? Helper.requestCapturePermission;

  final CoachingSignaling _signaling;
  final CoachingApi _native;

  /// OS 캡처 동의 요청 — 기본값은 flutter_webrtc의 플러그인 호출이다.
  /// 이 호출은 Android/macOS가 아니면 스스로 예외를 던져서(플랫폼 판정이 내부에
  /// 있다) 대역을 세울 수 없다. 순서 검증을 테스트로 고정하려고 주입점을 둔다.
  final Future<bool> Function() _requestConsent;

  /// 앱이 아니라 **OS 쪽에서** 캡처가 끝났을 때 알린다(시스템 공유 중지 배너 등).
  ///
  /// ★ 미해결: flutter_webrtc 1.5.2 Android는 MediaProjection의 onStop을 Dart로
  /// 올려 주지 않는다(GetUserMediaImpl의 콜백이 비어 있다). 그래서 이 콜백은
  /// 현재 Android에서 뜨지 않으며, 시스템 UI로 캡처를 멈춘 어르신에게는 상시
  /// 알림의 "돌아오기"가 유일한 복구 경로다 — docs/50 §14.
  final void Function()? onCaptureEnded;

  RTCPeerConnection? _pc;
  MediaStream? _stream;
  final _senders = <RTCRtpSender>[];

  /// 시작이 진행 중인가 — [isSharing]은 OS 동의가 끝난 뒤에야 참이 된다.
  bool _starting = false;

  bool get isSharing => _stream != null;

  /// 시작 절차가 아직 돌고 있는가. 호출부가 실패 문구를 띄울지 가릴 때 쓴다.
  bool get isStarting => _starting;

  /// 공유 시작. OS 동의 다이얼로그에서 어르신이 취소하면 false를 준다.
  ///
  /// **순서: 동의 → FGS → 캡처.** Android 14+는 캡처 동의를 받은 뒤에야
  /// `mediaProjection` 타입 FGS를 허용하고(그 전에는 startForeground가
  /// SecurityException), 그 FGS가 떠 있어야 MediaProjection 획득이 된다. 동의를
  /// 먼저 받지 않으면 두 요구가 서로를 막아 캡처 획득이 플러그인 안에서
  /// SecurityException으로 터지는데, 그 지점(ResultReceiver 콜백)에는 포획이 없어
  /// 통화 중 앱이 통째로 죽는다. [Helper.requestCapturePermission]이 받아 둔 동의는
  /// 플러그인이 캐시하므로 뒤따르는 getDisplayMedia는 다이얼로그를 다시 띄우지 않는다.
  Future<bool> start(String sessionId) async {
    // isSharing만으로는 부족하다 — _stream은 OS 동의(수 초)가 끝난 뒤에 채워져서,
    // 그 사이의 두 번째 탭이 가드를 통과해 캡처를 중복 시작한다. 그 뒤 어느 한쪽의
    // 실패 정리가 살아 있는 쪽의 FGS를 내려 버린다.
    if (isSharing || _starting) return false;
    _starting = true;
    try {
      if (!await _requestConsent()) return false;
      if (!await _native.startShareService()) return false;

      try {
        _stream = await navigator.mediaDevices.getDisplayMedia({
          // 코칭은 저프레임으로 충분하다 — 어르신 저용량 요금제·중저가 기기의
          // 데이터·발열 부담을 줄인다(리스크 #13).
          'video': {
            'frameRate': {'ideal': 8, 'max': 12},
          },
          // 통화는 PSTN으로 따로 간다(ADR-18) — 여기서 마이크를 잡지 않는다.
          'audio': false,
        });
        // _publish도 같은 정리 규율 안에 둔다. 밖에 두면 여기서 실패했을 때
        // 캡처와 FGS가 고아로 남고, _stream이 남아 isSharing이 참이라 재시도
        // 가드에 걸려 그 세션에서는 다시 시작할 수도 없다.
        return await _publish(sessionId);
      } catch (_) {
        // stop()은 캡처·PeerConnection·FGS를 모두 내린다(널 안전).
        await stop();
        return false;
      }
    } finally {
      _starting = false;
    }
  }

  /// 캡처가 열린 뒤 — 보기 전용 연결을 세우고 offer를 보낸다.
  Future<bool> _publish(String sessionId) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      unawaited(_send('ice', sessionId, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      }));
    };

    for (final track in _stream!.getVideoTracks()) {
      track.onEnded = () => onCaptureEnded?.call();
      _senders.add(await pc.addTrack(track, _stream!));
    }

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await _send('offer', sessionId, {'sdp': offer.sdp, 'type': offer.type});
    return true;
  }

  /// 보호자 기기에서 온 응답·후보 처리. 그 외 타입은 무시한다.
  Future<void> handle(SignalMessage message) async {
    final pc = _pc;
    if (pc == null) return;
    switch (message.type) {
      case 'answer':
        final sdp = message.data['sdp'] as String?;
        final type = message.data['sdpType'] as String? ?? 'answer';
        if (sdp != null) {
          await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
        }
      case 'ice':
        final candidate = message.data['candidate'] as String?;
        if (candidate != null) {
          await pc.addCandidate(RTCIceCandidate(
            candidate,
            message.data['sdpMid'] as String?,
            message.data['sdpMLineIndex'] as int?,
          ));
        }
    }
  }

  /// 어르신이 "가리기"를 누른 동안 프레임을 멈춘다 — 연결은 유지해 재개가 빠르다.
  /// 민감 화면 정책(§6)이 이 경로로 화면을 끊는다.
  Future<void> setVisible(bool visible) async {
    for (final track in _stream?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = visible;
    }
  }

  Future<void> stop() async {
    for (final sender in _senders) {
      try {
        await _pc?.removeTrack(sender);
      } catch (_) {}
    }
    _senders.clear();
    for (final track in _stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      try {
        await track.stop();
      } catch (_) {}
    }
    try {
      await _stream?.dispose();
    } catch (_) {}
    _stream = null;
    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;
    await _native.stopShareService();
  }

  Future<void> _send(
    String type,
    String sessionId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _signaling.send(SignalMessage(type, {
        'sessionId': sessionId,
        ...payload,
      }));
    } catch (_) {}
  }
}
