// 보호자 통화 코칭 상태기계의 행위 테스트 — 50_guardian_coaching.md의 ADR을 코드로
// 잠근다. 특히 ADR-16(쓰기 경로 0)·ADR-17(개시 주체)·ADR-19(민감 화면)·ADR-21(신뢰
// 앵커)은 깨지면 곧바로 법적·정책적 리스크가 되므로 회귀 테스트로 고정한다.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/coaching/coaching_controller.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/guardian_repository.dart';
import 'package:ongi/features/coaching/share_policy.dart';

class FakeSignaling implements CoachingSignaling {
  final _controller = StreamController<SignalMessage>.broadcast();
  final sent = <SignalMessage>[];
  bool failSend = false;

  @override
  Stream<SignalMessage> get messages => _controller.stream;

  @override
  bool get connected => true;

  @override
  Future<void> connect({
    required String deviceKey,
    required String role,
  }) async {}

  @override
  Future<void> send(SignalMessage message) async {
    if (failSend) throw StateError('signaling not connected');
    sent.add(message);
  }

  @override
  Future<void> close() async {}

  void emit(String type, [Map<String, dynamic> data = const {}]) =>
      _controller.add(SignalMessage(type, {'type': type, ...data}));
}

/// DB를 건드리지 않고 감사 로그 호출만 기록한다(테스트에서 sqflite 미사용 규약).
class RecordingGuardians extends GuardianRepository {
  int startCalls = 0;
  Map<String, Object?>? finished;

  @override
  Future<String> startSession({
    required Guardian guardian,
    required int nowMs,
  }) async {
    startCalls++;
    return 'log-1';
  }

  @override
  Future<void> finishSession({
    required String sessionId,
    required int nowMs,
    required bool shared,
    required bool sensitiveSeen,
    required String endReason,
  }) async {
    finished = {
      'sessionId': sessionId,
      'shared': shared,
      'sensitiveSeen': sensitiveSeen,
      'endReason': endReason,
    };
  }
}

const _elderKey = 'elder-device-key';

Guardian _guardian({
  String deviceKey = 'guardian-device-key',
  bool approved = true,
  int approvedUntilMs = 0,
}) =>
    Guardian(
      id: 'g1',
      name: '큰딸',
      phone: '01012345678',
      deviceKey: deviceKey,
      approved: approved,
      approvedUntilMs: approvedUntilMs,
      createdMs: 0,
    );

({CoachingController controller, FakeSignaling signaling, RecordingGuardians repo})
    _build() {
  final signaling = FakeSignaling();
  final repo = RecordingGuardians();
  return (
    controller: CoachingController(
      guardians: repo,
      signaling: signaling,
      deviceKey: _elderKey,
      now: () => DateTime.fromMillisecondsSinceEpoch(1000),
    ),
    signaling: signaling,
    repo: repo,
  );
}

/// 이벤트 루프를 한 바퀴 돌려 스트림 리스너가 처리되게 한다.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('ADR-17 세션 개시는 어르신만', () {
    test('요청하지 않았는데 서버가 수락을 보내도 세션이 열리지 않는다', () async {
      final t = _build();
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();

      expect(t.controller.phase, CoachingPhase.idle);
      expect(t.repo.startCalls, 0);
    });

    test('어르신이 요청하면 요청 단계로 가고 감사 로그가 시작된다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());

      expect(t.controller.phase, CoachingPhase.requested);
      expect(t.repo.startCalls, 1);
      expect(t.signaling.sent.single.type, 'help_request');
      // 본인인증을 요구하지 않는다 — 위임되는 권한이 0이라 지킬 대상이 없다(§2).
      expect(t.signaling.sent.single.data['fromDeviceKey'], _elderKey);
    });

    test('승인되지 않은 보호자로는 세션이 열리지 않는다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian(approved: false));

      expect(t.controller.phase, CoachingPhase.idle);
      expect(t.repo.startCalls, 0);
    });

    test('승인 유효기간이 지난 보호자로는 세션이 열리지 않는다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian(approvedUntilMs: 500));

      expect(t.controller.phase, CoachingPhase.idle);
    });
  });

  group('ADR-21 신뢰 앵커는 전화번호가 아니라 등록 앱 인스턴스', () {
    test('수락의 기기 키가 지목한 보호자와 다르면 세션을 버린다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());

      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'spoofed-key', // 발신번호는 맞아도 앱 키가 다름
      });
      await _settle();

      expect(t.controller.phase, CoachingPhase.ended);
      expect(t.controller.endReason, CoachingEndReason.failed);
    });

    test('기기 키가 일치해야 통화 단계로 간다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());

      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();

      expect(t.controller.phase, CoachingPhase.talking);
    });

    test('기기 키가 비어 있는 보호자는 수락돼도 세션이 성립하지 않는다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian(deviceKey: ''));

      t.signaling.emit('accepted', {'sessionId': 's1', 'guardianDeviceKey': ''});
      await _settle();

      expect(t.controller.phase, CoachingPhase.ended);
    });
  });

  group('ADR-16 기기로 들어오는 쓰기 경로가 없다', () {
    test('보호자·서버가 보낸 조작성 메시지는 전부 무시된다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();

      // 명령 채널을 만들지 않았으므로 어떤 타입도 상태를 바꾸지 못한다.
      for (final hostile in const [
        'set_category',
        'add_alias',
        'launch_app',
        'uninstall_app',
        'change_setting',
        'start_sharing',
        'open_screen',
      ]) {
        t.signaling.emit(hostile, {'sessionId': 's1', 'packageName': 'com.x'});
      }
      await _settle();

      expect(t.controller.phase, CoachingPhase.talking);
      expect(t.controller.screenPolicy, SharePolicy.allowed);
      expect(t.controller.sharedThisSession, isFalse);
    });

    test('보호자는 화면 공유를 시작시킬 수 없다 — 어르신 기기에서만 시작된다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();

      t.signaling.emit('request_share', {'sessionId': 's1'});
      await _settle();
      expect(t.controller.phase, CoachingPhase.talking);

      // OS 동의를 통과한 뒤 기기가 직접 호출했을 때만 공유가 시작된다.
      t.controller.onSharingStarted();
      expect(t.controller.phase, CoachingPhase.sharing);
    });
  });

  group('ADR-19 민감 화면 3단 정책', () {
    Future<CoachingController> sharing() async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();
      t.controller.onSharingStarted();
      return t.controller;
    }

    test('일반 화면은 그대로 보인다', () async {
      final c = await sharing();
      c.onForegroundPolicy(SharePolicy.allowed);
      expect(c.screenVisible, isTrue);
    });

    test('송금·결제는 가려지고 재동의해도 열리지 않는다', () async {
      final c = await sharing();
      c.onForegroundPolicy(SharePolicy.blocked);
      expect(c.screenVisible, isFalse);

      c.reconsentCurrentScreen(); // 재동의 경로 자체가 없어야 한다
      expect(c.screenVisible, isFalse);
    });

    test('인증·공공·의료는 어르신 재동의로 다시 보인다', () async {
      final c = await sharing();
      c.onForegroundPolicy(SharePolicy.reconsent);
      expect(c.screenVisible, isFalse);

      c.reconsentCurrentScreen();
      expect(c.screenVisible, isTrue);
    });

    test('다른 민감 화면으로 넘어가면 재동의가 초기화된다', () async {
      final c = await sharing();
      c.onForegroundPolicy(SharePolicy.reconsent);
      c.reconsentCurrentScreen();
      expect(c.screenVisible, isTrue);

      c.onForegroundPolicy(SharePolicy.allowed);
      c.onForegroundPolicy(SharePolicy.reconsent);
      expect(c.screenVisible, isFalse, reason: '한 번 허용이 다음 화면까지 이어지면 안 된다');
    });

    test('민감 화면 접촉은 감사 로그에 남는다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();
      t.controller.onSharingStarted();
      t.controller.onForegroundPolicy(SharePolicy.reconsent);
      await t.controller.endByElder();

      expect(t.repo.finished?['sensitiveSeen'], isTrue);
      expect(t.repo.finished?['shared'], isTrue);
    });
  });

  group('코드 리뷰 회귀 — 가리기·판정불능·세션ID', () {
    Future<CoachingController> sharing(FakeSignaling sig, RecordingGuardians r) async {
      final c = CoachingController(
        guardians: r,
        signaling: sig,
        deviceKey: _elderKey,
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await c.requestHelp(_guardian());
      sig.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();
      c.onSharingStarted();
      return c;
    }

    test('가리기는 세션을 끝내지 않는다 — 프레임만 멈춘다', () async {
      final t = _build();
      final c = await sharing(t.signaling, t.repo);

      c.setHidden(true);
      expect(c.screenVisible, isFalse);
      expect(c.phase, CoachingPhase.sharing, reason: '연결이 유지돼야 재개가 즉시 된다');

      c.setHidden(false);
      expect(c.screenVisible, isTrue);
    });

    test('사용통계 권한이 없으면 화면이 나가지 않는다 — fail-closed', () async {
      final t = _build();
      final c = await sharing(t.signaling, t.repo);
      expect(c.screenVisible, isTrue);

      // 어떤 앱이 앞에 있는지 모르면 은행 화면도 못 거른다 → 가린다.
      c.setPolicyBlind(true);
      expect(c.screenVisible, isFalse);

      c.setPolicyBlind(false);
      expect(c.screenVisible, isTrue);
    });

    test('판정 불능은 재동의로도 뚫리지 않는다', () async {
      final t = _build();
      final c = await sharing(t.signaling, t.repo);
      c.setPolicyBlind(true);
      c.onForegroundPolicy(SharePolicy.reconsent);
      c.reconsentCurrentScreen();
      expect(c.screenVisible, isFalse);
    });

    test('세션 ID가 노출되어 화면 공유 시그널이 세션을 참조할 수 있다', () async {
      final t = _build();
      expect(t.controller.sessionId, isNull);
      final c = await sharing(t.signaling, t.repo);
      expect(c.sessionId, 's1');
    });

    test('종료하면 가림·판정불능 상태가 초기화된다', () async {
      final t = _build();
      final c = await sharing(t.signaling, t.repo);
      c.setHidden(true);
      c.setPolicyBlind(true);
      await c.endByElder();
      expect(c.hiddenByElder, isFalse);
      expect(c.policyBlind, isFalse);
    });
  });

  group('세션 종료', () {
    test('어르신이 끝내면 사유와 함께 감사 로그가 마감된다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();
      await t.controller.endByElder();

      expect(t.controller.phase, CoachingPhase.ended);
      expect(t.repo.finished?['endReason'], 'elderEnded');
      expect(t.signaling.sent.last.type, 'end');
    });

    test('연결이 끊기면 세션이 즉시 끝난다 — 잔존 접근을 남기지 않는다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();

      t.signaling.emit('disconnected');
      await _settle();

      expect(t.controller.phase, CoachingPhase.ended);
      expect(t.controller.endReason, CoachingEndReason.disconnected);
      expect(t.controller.screenVisible, isFalse);
    });

    test('보호자가 거절하면 그 사유로 끝난다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());

      t.signaling.emit('declined', {'sessionId': 's1'});
      await _settle();

      expect(t.controller.endReason, CoachingEndReason.declined);
    });

    test('요청 전송이 실패하면 세션이 열린 채로 남지 않는다', () async {
      final t = _build();
      t.signaling.failSend = true;
      await t.controller.requestHelp(_guardian());

      expect(t.controller.phase, CoachingPhase.ended);
      expect(t.controller.endReason, CoachingEndReason.failed);
    });

    test('요약을 닫으면 초기 상태로 돌아간다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      await t.controller.endByElder();

      t.controller.dismissSummary();
      expect(t.controller.phase, CoachingPhase.idle);
      expect(t.controller.target, isNull);
    });
  });

  // 보호자 앱과 서버가 실제로 쓰는 타입은 'end'다. 'ended'만 처리하면 끊기 버튼
  // 경로가 통째로 죽어 캡처와 "보고 있어요" 표시가 계속 남는다.
  group('프로토콜 정합 — 보호자 끊기', () {
    Future<CoachingController> talking(
      FakeSignaling sig,
      RecordingGuardians repo,
    ) async {
      final c = CoachingController(
        guardians: repo,
        signaling: sig,
        deviceKey: _elderKey,
        now: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await c.requestHelp(_guardian());
      sig.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();
      return c;
    }

    test("보호자가 보내는 'end'로 세션이 끝난다", () async {
      final t = _build();
      final c = await talking(t.signaling, t.repo);

      t.signaling.emit('end', {'sessionId': 's1'});
      await _settle();

      expect(c.phase, CoachingPhase.ended);
      expect(c.endReason, CoachingEndReason.guardianEnded);
      expect(c.screenVisible, isFalse);
    });

    test("과거 타입 'ended'도 계속 받는다", () async {
      final t = _build();
      final c = await talking(t.signaling, t.repo);

      t.signaling.emit('ended', {'sessionId': 's1'});
      await _settle();

      expect(c.phase, CoachingPhase.ended);
      expect(c.endReason, CoachingEndReason.guardianEnded);
    });

    test('공유 중에 보호자가 끊으면 공유 단계도 함께 내려간다', () async {
      final t = _build();
      final c = await talking(t.signaling, t.repo);
      c.onSharingStarted();
      expect(c.phase, CoachingPhase.sharing);

      t.signaling.emit('end', {'sessionId': 's1'});
      await _settle();

      expect(c.phase, CoachingPhase.ended);
      expect(t.repo.finished?['endReason'], 'guardianEnded');
    });
  });

  // 세션 ID는 수락 응답에서야 채워진다. 그 전에 끊었을 때 알리지 않으면 보호자
  // 폰은 계속 울리고, 뒤늦은 수락이 다음 세션까지 망가뜨린다.
  group('수락 전 취소도 보호자에게 통지한다', () {
    test('부르는 중 그만두면 end가 나간다 — 세션 ID가 없어도', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      expect(t.controller.phase, CoachingPhase.requested);
      expect(t.controller.sessionId, isNull);

      await t.controller.endByElder();

      final ends = t.signaling.sent.where((m) => m.type == 'end');
      expect(ends, hasLength(1));
      expect(ends.single.data.containsKey('sessionId'), isFalse);
      expect(ends.single.data['reason'], 'elderEnded');
    });

    test('세션 ID가 있으면 함께 실어 보낸다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian());
      t.signaling.emit('accepted', {
        'sessionId': 's1',
        'guardianDeviceKey': 'guardian-device-key',
      });
      await _settle();
      await t.controller.endByElder();

      final end = t.signaling.sent.lastWhere((m) => m.type == 'end');
      expect(end.data['sessionId'], 's1');
    });

    test('세션을 연 적이 없으면 end를 보내지 않는다', () async {
      final t = _build();
      await t.controller.requestHelp(_guardian(approved: false));

      expect(t.signaling.sent, isEmpty);
    });
  });

  // 재연결은 멈추지 않는다(서버가 늦게 뜨는 시연을 살려야 한다). 대신 간격이
  // 짧으면 릴레이가 없는 대부분의 기기에서 영원한 재시도가 상시 부하가 된다.
  group('재연결 백오프', () {
    test('1초에서 시작해 배로 늘어난다', () {
      expect(WebSocketSignaling.backoffFor(1), const Duration(seconds: 1));
      expect(WebSocketSignaling.backoffFor(2), const Duration(seconds: 2));
      expect(WebSocketSignaling.backoffFor(3), const Duration(seconds: 4));
      expect(WebSocketSignaling.backoffFor(5), const Duration(seconds: 16));
    });

    test('상한 5분에 실제로 도달하고 그 위로는 올라가지 않는다', () {
      // 상한에 닿는 단계를 열어 두지 않으면 선언한 상한이 죽은 코드가 된다 —
      // 지수 단계(…128, 256, 512)가 상한을 넘어서야 비로소 상한이 쓰인다.
      expect(WebSocketSignaling.backoffFor(9), const Duration(seconds: 256));
      expect(WebSocketSignaling.backoffFor(10), const Duration(minutes: 5));
      expect(WebSocketSignaling.backoffFor(50), const Duration(minutes: 5));
    });

    test('첫 시도부터 유효한 값을 준다 — 0·음수도 1초로 접힌다', () {
      expect(WebSocketSignaling.backoffFor(0), const Duration(seconds: 1));
      expect(WebSocketSignaling.backoffFor(-3), const Duration(seconds: 1));
    });
  });
}
