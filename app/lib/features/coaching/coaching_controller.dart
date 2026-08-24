import 'dart:async';

import 'package:flutter/foundation.dart';

import 'coaching_signaling.dart';
import 'guardian_repository.dart';
import 'share_policy.dart';

/// 코칭 세션 단계(50_guardian_coaching.md §7).
///
/// `idle → requested → talking → sharing(선택) → ended`
/// 화면 공유는 항상 별개의 선택이라 [talking]에서 끝나도 정상이다.
enum CoachingPhase {
  idle,
  requested,
  talking,
  sharing,
  ended,
}

/// 세션 종료 사유 — 감사 로그(§7)와 종료 화면 문구에 함께 쓴다.
enum CoachingEndReason {
  elderEnded('어르신이 끝냈어요'),
  guardianEnded('보호자가 끝냈어요'),
  declined('보호자가 지금 받을 수 없어요'),
  disconnected('연결이 끊겼어요'),
  failed('연결하지 못했어요');

  const CoachingEndReason(this.label);

  final String label;
}

/// 어르신 기기의 코칭 세션 상태기계.
///
/// 설계상 반드시 지키는 것:
/// - **세션을 여는 것은 어르신뿐**이다(ADR-17). 서버·보호자가 보낸 어떤 메시지도
///   [requestHelp] 없이 [phase]를 진행시키지 못한다.
/// - **기기로 들어오는 쓰기 경로가 없다**(ADR-16). 이 클래스에는 보호자가 기기
///   상태를 바꾸도록 하는 메서드가 없으며, 그 부재를 테스트로 고정한다.
/// - **신뢰 앵커는 전화번호가 아니라 등록 앱 인스턴스 키**다(ADR-21). 수락 응답의
///   `guardianDeviceKey`가 어르신이 지목한 보호자의 것과 다르면 세션을 버린다.
class CoachingController extends ChangeNotifier {
  CoachingController({
    required GuardianRepository guardians,
    required CoachingSignaling signaling,
    required this.deviceKey,
    DateTime Function()? now,
  })  : _guardians = guardians,
        _signaling = signaling,
        _now = now ?? DateTime.now;

  final GuardianRepository _guardians;
  final CoachingSignaling _signaling;
  final DateTime Function() _now;

  /// 이 기기(어르신)의 인스턴스 키 — 등록 시 보호자와 교환한다(ADR-21).
  /// 최초 실행 때 생성해 DB에 넣으므로 부트스트랩에서 한 번 채워진다.
  String deviceKey;

  StreamSubscription<SignalMessage>? _sub;

  CoachingPhase _phase = CoachingPhase.idle;
  CoachingPhase get phase => _phase;

  Guardian? _target;

  /// 지금 연결된(또는 연결하려는) 보호자.
  Guardian? get target => _target;

  String? _sessionId;

  /// 릴레이가 발급한 세션 ID — 화면 공유 시그널·서버 로그가 이 값으로 묶인다.
  String? get sessionId => _sessionId;

  String? _logId;
  CoachingEndReason? _endReason;
  CoachingEndReason? get endReason => _endReason;

  bool _sharedThisSession = false;
  bool _sensitiveSeen = false;

  /// 세션 중 한 번이라도 화면을 공유했는가 — 종료 요약에 쓴다.
  bool get sharedThisSession => _sharedThisSession;
  bool get sensitiveSeen => _sensitiveSeen;

  SharePolicy _screenPolicy = SharePolicy.allowed;

  /// 지금 앞에 있는 앱에 대한 공유 정책(§6). [SharePolicy.allowed]가 아니면 가려진다.
  SharePolicy get screenPolicy => _screenPolicy;

  /// 어르신이 재동의해 일시적으로 공유를 허용한 상태인가.
  bool _reconsented = false;

  /// 어르신이 "가리기"를 눌러 잠시 감춘 상태인가.
  ///
  /// 세션을 끝내지 않는다 — 연결과 통화는 유지하고 프레임만 멈춘다. Android는
  /// 캡처 세션마다 동의를 강제하므로, 여기서 세션을 끊으면 다시 보여줄 때마다
  /// 어르신이 OS 다이얼로그를 다시 통과해야 한다.
  bool _hiddenByElder = false;
  bool get hiddenByElder => _hiddenByElder;

  /// 사용통계 권한이 없어 민감 화면을 판정할 수 없는 상태.
  /// **판정할 수 없으면 보여주지 않는다** — 정책의 fail-closed 지점(ADR-19).
  bool _policyBlind = false;
  bool get policyBlind => _policyBlind;

  /// 지금 실제로 화면이 나가고 있는가 — 가리기·차단이 걸리면 false.
  bool get screenVisible =>
      _phase == CoachingPhase.sharing &&
      !_hiddenByElder &&
      !_policyBlind &&
      (_screenPolicy == SharePolicy.allowed ||
          (_screenPolicy == SharePolicy.reconsent && _reconsented));

  bool get isActive =>
      _phase != CoachingPhase.idle && _phase != CoachingPhase.ended;

  /// 세션 개시 — **어르신의 1탭. 본인인증을 조건으로 두지 않는다**(ADR-17).
  ///
  /// 게이트는 두 개뿐이다: 기기를 물리적으로 쥔 사람이 눌렀다는 것과, 대상이
  /// 사전 A·B를 통과한 보호자라는 것. 위임되는 권한이 0이라 지킬 대상이 없다(§2).
  Future<void> requestHelp(Guardian guardian) async {
    if (isActive) return;
    final nowMs = _now().millisecondsSinceEpoch;
    if (!guardian.isUsableAt(nowMs)) return;

    _target = guardian;
    _sharedThisSession = false;
    _sensitiveSeen = false;
    _reconsented = false;
    _endReason = null;
    _sessionId = null;
    _set(CoachingPhase.requested);

    try {
      _logId = await _guardians.startSession(guardian: guardian, nowMs: nowMs);
      await _listen();
      await _signaling.send(SignalMessage('help_request', {
        'toDeviceKey': guardian.deviceKey,
        'fromDeviceKey': deviceKey,
      }));
    } catch (_) {
      await _finish(CoachingEndReason.failed);
    }
  }

  Future<void> _listen() async {
    await _sub?.cancel();
    _sub = _signaling.messages.listen(_onMessage);
  }

  void _onMessage(SignalMessage message) {
    // 세션을 시작하지 않았는데 도착한 것은 전부 무시한다 — 서버·보호자가 세션을
    // 열 수 있는 경로를 만들지 않기 위한 방어선(ADR-17).
    if (_phase == CoachingPhase.idle || _phase == CoachingPhase.ended) return;

    switch (message.type) {
      case 'accepted':
        _onAccepted(message);
      case 'declined':
        unawaited(_finish(CoachingEndReason.declined));
      // 보호자 앱이 보내는 것은 'end'다. 'ended'만 받으면 끊기 버튼 경로가 통째로
      // 죽어 어르신 화면에는 계속 "보고 있어요"가 떠 있고 캡처도 돌아간다.
      case 'end':
      case 'ended':
        unawaited(_finish(CoachingEndReason.guardianEnded));
      case 'disconnected':
        unawaited(_finish(CoachingEndReason.disconnected));
    }
  }

  void _onAccepted(SignalMessage message) {
    final expected = _target?.deviceKey ?? '';
    final actual = message.data['guardianDeviceKey'] as String? ?? '';
    // ADR-21 — 신뢰 앵커 검증. 서버가 위조 수락을 보내도 여기서 걸린다.
    if (expected.isEmpty || expected != actual) {
      unawaited(_finish(CoachingEndReason.failed));
      return;
    }
    _sessionId = message.sessionId;
    _set(CoachingPhase.talking);
  }

  /// 화면 공유 시작 — 통화가 연결된 뒤 보호자 안내를 받아 어르신이 누른다(§4 [4]).
  /// 실제 OS 동의 다이얼로그는 호출부(네이티브 브리지)가 띄우고, 성공했을 때만
  /// 이 메서드를 부른다. Android 14+는 캡처 세션마다 시스템이 동의를 강제한다.
  void onSharingStarted() {
    if (_phase != CoachingPhase.talking) return;
    _sharedThisSession = true;
    _reconsented = false;
    _hiddenByElder = false;
    _set(CoachingPhase.sharing);
  }

  /// "가리기"/"다시 보여주기" — 세션은 그대로 두고 프레임만 멈춘다.
  void setHidden(bool hidden) {
    if (_phase != CoachingPhase.sharing || _hiddenByElder == hidden) return;
    _hiddenByElder = hidden;
    notifyListeners();
  }

  /// 사용통계 권한 유무를 반영한다. 권한이 없으면 어떤 앱이 앞에 있는지 알 수 없어
  /// 은행 화면도 걸러내지 못하므로, 판정 불능은 곧 비공개로 처리한다.
  void setPolicyBlind(bool blind) {
    if (_policyBlind == blind) return;
    _policyBlind = blind;
    notifyListeners();
  }

  /// 어르신이 "가리기"를 눌렀거나 공유를 멈춘 경우 — 통화는 유지된다.
  void onSharingStopped() {
    if (_phase != CoachingPhase.sharing) return;
    _reconsented = false;
    _hiddenByElder = false;
    _screenPolicy = SharePolicy.allowed;
    _set(CoachingPhase.talking);
  }

  /// 포그라운드 앱이 바뀔 때마다 호출 — 민감 화면 3단 정책(§6·ADR-19).
  ///
  /// 정책이 바뀌면 재동의 상태를 **반드시 초기화**한다. 한 번 허용했다고 다음
  /// 민감 화면까지 열리면 안 되기 때문이다.
  void onForegroundPolicy(SharePolicy policy) {
    if (policy == _screenPolicy) return;
    _screenPolicy = policy;
    _reconsented = false;
    if (policy != SharePolicy.allowed) _sensitiveSeen = true;
    notifyListeners();
  }

  /// 인증·정부·병원 화면을 어르신이 다시 보여주기로 한 경우.
  /// **송금·결제([SharePolicy.blocked])에는 이 경로가 없다** — 재동의 불가.
  void reconsentCurrentScreen() {
    if (_screenPolicy != SharePolicy.reconsent) return;
    _reconsented = true;
    notifyListeners();
  }

  /// 어르신이 세션을 끝냄 — 1탭으로 언제든 가능해야 한다(§3).
  Future<void> endByElder() => _finish(CoachingEndReason.elderEnded);

  Future<void> _finish(CoachingEndReason reason) async {
    if (_phase == CoachingPhase.ended || _phase == CoachingPhase.idle) return;
    _endReason = reason;
    _set(CoachingPhase.ended);

    // 세션 ID는 수락 응답에서야 채워진다. 그 전에 끊어도(취소·실패) 보호자에게
    // 알려야 벨이 멈춘다 — 서버는 help_request 시점에 두 기기를 이미 이어 두었으므로
    // 세션 ID 없이도 상대에게 라우팅된다.
    if (_target != null) {
      final sessionId = _sessionId;
      try {
        await _signaling.send(SignalMessage('end', {
          if (sessionId != null) 'sessionId': sessionId,
          'reason': reason.name,
        }));
      } catch (_) {}
    }
    await _sub?.cancel();
    _sub = null;

    final logId = _logId;
    if (logId != null) {
      try {
        await _guardians.finishSession(
          sessionId: logId,
          nowMs: _now().millisecondsSinceEpoch,
          shared: _sharedThisSession,
          sensitiveSeen: _sensitiveSeen,
          endReason: reason.name,
        );
      } catch (_) {}
    }
    _screenPolicy = SharePolicy.allowed;
    _reconsented = false;
    _hiddenByElder = false;
    _policyBlind = false;
  }

  /// 종료 요약 화면을 닫고 초기 상태로.
  void dismissSummary() {
    if (_phase != CoachingPhase.ended) return;
    _target = null;
    _sessionId = null;
    _logId = null;
    _set(CoachingPhase.idle);
  }

  void _set(CoachingPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
