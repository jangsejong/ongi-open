// 보호자 모드 상태기계 — 어르신 쪽과 대칭이 아니라는 점이 핵심이다.
// 보호자는 세션을 열 수 없고(ADR-17), 화면을 받기만 하며 기기로 명령을 보내는
// 경로가 없다(ADR-16). 그 비대칭을 회귀 테스트로 고정한다.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/coaching_tasks.dart';
import 'package:ongi/features/coaching/device_identity.dart';
import 'package:ongi/features/coaching/guardian_controller.dart';

class FakeSignaling implements CoachingSignaling {
  final _controller = StreamController<SignalMessage>.broadcast();
  final sent = <SignalMessage>[];

  /// 실제 [WebSocketSignaling.connect]는 최초 연결이 실패하면 재시도를 예약한
  /// 뒤 다시 던진다 — 그 상황을 재현한다.
  bool failConnect = false;

  @override
  Stream<SignalMessage> get messages => _controller.stream;

  @override
  bool get connected => true;

  @override
  Future<void> connect({
    required String deviceKey,
    required String role,
  }) async {
    if (failConnect) throw StateError('relay unreachable');
  }

  @override
  Future<void> send(SignalMessage message) async => sent.add(message);

  @override
  Future<void> close() async {}

  void emit(String type, [Map<String, dynamic> data = const {}]) =>
      _controller.add(SignalMessage(type, {'type': type, ...data}));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSignaling signaling;
  late GuardianController controller;

  setUp(() {
    // start()가 RTCVideoRenderer를 만들 때 타는 플랫폼 채널만 대역으로 세운다 —
    // 메시지 구독은 start() 안에서 붙으므로 이걸 건너뛰면 아무것도 수신하지 않는다.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async =>
          call.method == 'createVideoRenderer' ? {'textureId': 1} : null,
    );
    signaling = FakeSignaling();
    controller = GuardianController(signaling: signaling);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Method'), null);
  });

  group('ADR-17 보호자는 세션을 열 수 없다', () {
    test('초기 상태는 대기이며 스스로 통화를 시작하는 메서드가 없다', () {
      expect(controller.phase, GuardianPhase.idle);
      // 수락·거절·종료만 있고 '시작'이 없다 — 개시 권한은 어르신 기기에만 있다.
      expect(controller.pendingPair, isNull);
    });

    test('요청이 오기 전에 수락해도 아무 일도 일어나지 않는다', () async {
      await controller.accept();
      expect(controller.phase, GuardianPhase.idle);
      expect(signaling.sent, isEmpty);
    });
  });

  group('과업 템플릿', () {
    test('송금·결제는 코칭 목록에 없다 — 1차 방어선(ADR-19)', () {
      final titles = coachingTasks.map((t) => t.title).join(' ');
      for (final banned in ['송금', '이체', '결제', '계좌']) {
        expect(titles.contains(banned), isFalse, reason: '$banned 과업이 있으면 안 된다');
      }
      expect(coachingExcluded, contains('돈'));
    });

    test('본인인증이 첫 과업이다 — 세션 조건에서 뺀 것을 여기서 가르친다(§2)', () {
      expect(coachingTasks.first.title, contains('본인인증'));
      expect(coachingTasks.first.pitfall, contains('인증번호'));
    });

    test('모든 과업에 단계가 있고 어르신이 직접 하는 문장으로 쓰였다', () {
      for (final task in coachingTasks) {
        expect(task.steps, isNotEmpty, reason: '${task.title}에 단계가 없다');
        for (final step in task.steps) {
          expect(step.contains('대신 눌러'), isFalse,
              reason: '보호자가 대신 조작하는 문장이 있으면 안 된다(ADR-16)');
        }
      }
    });
  });

  group('페어링 코드', () {
    test('기기 키 앞 6자리를 대문자로 쓴다 — 통화로 불러 주기 위한 길이', () {
      expect(DeviceIdentity.pairingCodeOf('abcdef0123456789'), 'ABCDEF');
      expect(DeviceIdentity.pairingCodeOf(''), '');
    });
  });

  // 릴레이가 아직 안 떠 있는 상태로 보호자 앱을 켜는 것은 예외가 아니라 기본
  // 상황이다(코칭은 v1.2고 릴레이 주소는 시연망을 가리킨다). 이때 구독이 붙지
  // 않으면 백오프가 소켓을 되살려도 앱은 아무것도 듣지 못한다 — 서버에는 등록된
  // 채 무응답이라 어르신 쪽에서는 offline 거절조차 오지 않는다.
  group('최초 연결이 실패해도 수신은 살아 있어야 한다', () {
    test('connect가 던져도 이후 도착한 등록 요청을 받는다', () async {
      signaling.failConnect = true;
      await expectLater(
        controller.start(deviceKey: 'guardian-1'),
        throwsA(isA<StateError>()),
      );

      // 백오프가 소켓을 되살린 뒤 도착하는 메시지.
      signaling.emit('pair_request', {
        'fromDeviceKey': 'elderA',
        'elderName': '할머니',
      });
      await Future<void>.delayed(Duration.zero);

      expect(controller.pendingPair?.elderDeviceKey, 'elderA',
          reason: '구독이 connect보다 먼저 붙어야 한다');
    });

    test('connect가 던져도 이후 도착한 도움 요청을 받는다', () async {
      signaling.failConnect = true;
      await expectLater(
        controller.start(deviceKey: 'guardian-1'),
        throwsA(isA<StateError>()),
      );

      signaling.emit('help_request', {
        'fromDeviceKey': 'elderA',
        'sessionId': 's1',
      });
      await Future<void>.delayed(Duration.zero);

      expect(controller.phase, GuardianPhase.incoming);
    });
  });

  // 확인 창에 보인 사람과 실제로 등록되는 사람이 같아야 한다. 다르면 보호자가
  // A를 보고 수락했는데 B가 앵커를 얻는다(ADR-21 동의 게이트가 무의미해진다).
  group('등록 요청 응답은 화면에 보인 그 요청에만 나간다', () {
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    setUp(() async => controller.start(deviceKey: 'guardian-1'));

    test('창이 떠 있는 사이 새 요청이 와도 원래 대상에게 답한다', () async {
      signaling.emit('pair_request', {
        'fromDeviceKey': 'elderA',
        'elderName': '할머니',
      });
      await settle();
      final shown = controller.pendingPair!;
      expect(shown.elderDeviceKey, 'elderA');

      // 보호자가 다이얼로그를 보고 있는 사이 다른 어르신이 요청.
      signaling.emit('pair_request', {
        'fromDeviceKey': 'elderB',
        'elderName': '할아버지',
      });
      await settle();

      // 화면이 보여 준 요청(A)으로 수락 — B로 나가면 안 된다.
      await controller.acceptPair(shown);

      // 대상이 이미 B로 바뀌었으므로 아무것도 보내지 않는다(잘못 등록보다 실패).
      expect(signaling.sent, isEmpty);
      // B의 요청은 남아 있어 따로 다시 물을 수 있다.
      expect(controller.pendingPair?.elderDeviceKey, 'elderB');
    });

    test('바뀐 것이 없으면 그 대상에게 정상 전달된다', () async {
      signaling.emit('pair_request', {
        'fromDeviceKey': 'elderA',
        'elderName': '할머니',
      });
      await settle();

      await controller.acceptPair(controller.pendingPair!);

      expect(signaling.sent.single.type, 'pair_ok');
      expect(signaling.sent.single.data['toDeviceKey'], 'elderA');
      expect(controller.pendingPair, isNull);
    });

    test('거절도 같은 규칙을 따른다', () async {
      signaling.emit('pair_request', {
        'fromDeviceKey': 'elderA',
        'elderName': '할머니',
      });
      await settle();

      await controller.declinePair(controller.pendingPair!);

      expect(signaling.sent.single.type, 'pair_no');
      expect(signaling.sent.single.data['toDeviceKey'], 'elderA');
    });
  });
}
