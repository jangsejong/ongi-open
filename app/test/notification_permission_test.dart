// 상시 알림 권한을 **언제 묻는가**의 회귀 테스트.
//
// 화면 공유 중 상시 알림은 어르신이 "지금 보이고 있다"를 아는 유일한 수단이고,
// 시스템 UI로 캡처가 멈췄을 때 온기로 돌아오는 경로다(50_ §7 가시성). 그런데
// Android는 2회 거부하면 앱에서 다시 물을 수 없어 기회가 사실상 한두 번뿐이다.
// 그래서 "코칭이 실제로 가능해진 순간에만 묻는다"가 안전 속성이 된다 —
// 맥락 없는 이른 요청은 정작 필요한 순간의 기회를 태운다.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/elder_auth.dart';
import 'package:ongi/features/coaching/guardian_repository.dart';
import 'package:ongi/features/coaching/guardian_setup_screen.dart';
import 'package:ongi/native/ongi_native.g.dart';

class _FakeSignaling implements CoachingSignaling {
  final _controller = StreamController<SignalMessage>.broadcast();
  final sent = <SignalMessage>[];

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
  Future<void> send(SignalMessage message) async => sent.add(message);

  @override
  Future<void> close() async {}

  void emit(String type, [Map<String, dynamic> data = const {}]) =>
      _controller.add(SignalMessage(type, {'type': type, ...data}));
}

/// sqflite 없이 도는 메모리 저장소(테스트 규약: DB 미사용).
class _MemoryGuardians extends GuardianRepository {
  final _rows = <Guardian>[];
  int _seq = 0;

  @override
  Future<List<Guardian>> all() async => List.of(_rows);

  @override
  Future<List<AssistSession>> history({int limit = 50}) async => const [];

  @override
  Future<Guardian> add({
    required String name,
    required String phone,
    required int nowMs,
    String deviceKey = '',
    bool approved = false,
    int approvedUntilMs = 0,
  }) async {
    final guardian = Guardian(
      id: 'g${++_seq}',
      name: name,
      phone: phone,
      deviceKey: deviceKey,
      approved: approved,
      approvedUntilMs: approvedUntilMs,
      createdMs: nowMs,
    );
    _rows.add(guardian);
    return guardian;
  }

  @override
  Future<void> update(Guardian guardian) async {
    final index = _rows.indexWhere((g) => g.id == guardian.id);
    if (index >= 0) _rows[index] = guardian;
  }
}

class _FakeAuth extends ElderAuth {
  @override
  Future<ElderAuthResult> confirm(String reason) async => ElderAuthResult.ok;
}

class _FakeStats extends DeviceStatsApi {
  _FakeStats({this.granted = false, this.canRequest = true});

  bool granted;

  /// 시스템 팝업을 실제로 띄울 수 있는가 — 영구 거부·구형 차단·채널 차단이면 false.
  bool canRequest;
  int requests = 0;

  @override
  Future<bool> isPostNotificationsGranted() async => granted;

  @override
  Future<bool> canRequestPostNotifications() async => canRequest;

  @override
  Future<void> requestPostNotifications() async => requests++;
}

class _FakeIntents extends IntentActionsApi {
  int settingsOpened = 0;

  @override
  Future<bool> openNotificationSettings() async {
    settingsOpened++;
    return true;
  }
}

const _guardianKey = 'gkey01abcdefghijklmnopqrst';
const _otherKey = 'zzzz99abcdefghijklmnopqrst';

Future<void> _register(WidgetTester tester, String code) async {
  await tester.tap(find.text('보호자 추가하기'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).at(0), '큰딸');
  await tester.enterText(find.byType(TextField).at(1), '01012345678');
  await tester.enterText(find.byType(TextField).at(2), code);
  await tester.tap(find.text('저장'));
  await tester.pumpAndSettle();
}

/// 페어링 한 판을 끝까지 흘려보낸다(60초 대기·4초 토스트 타이머까지).
Future<void> _drainTimers(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 61));
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

void main() {
  late _MemoryGuardians guardians;
  late _FakeSignaling signaling;
  late _FakeStats stats;
  late _FakeIntents intents;

  /// [bound]면 이미 페어링까지 끝낸 보호자가 있는 상태로 화면을 연다.
  Future<void> pump(
    WidgetTester tester, {
    bool granted = false,
    bool canRequest = true,
    bool bound = false,
  }) async {
    guardians = _MemoryGuardians();
    signaling = _FakeSignaling();
    stats = _FakeStats(granted: granted, canRequest: canRequest);
    intents = _FakeIntents();
    if (bound) {
      await guardians.add(
        name: '큰딸',
        phone: '01012345678',
        nowMs: 0,
        deviceKey: _guardianKey,
        approved: true,
      );
    }
    await tester.pumpWidget(MaterialApp(
      home: GuardianSetupScreen(
        guardians: guardians,
        signaling: signaling,
        auth: _FakeAuth(),
        intents: intents,
        stats: stats,
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('묻는 시점', () {
    testWidgets('페어링이 성공한 직후에 묻는다', (tester) async {
      await pump(tester);
      await _register(tester, 'GKEY01');
      signaling.emit('pair_ok', {'guardianDeviceKey': _guardianKey});
      await _drainTimers(tester);

      expect(find.text('알림을 켜 주세요'), findsOneWidget,
          reason: '시스템 팝업을 맨몸으로 띄우지 않고 무엇에 쓰는지 먼저 말한다');
      await tester.tap(find.text('알림 켜기'));
      await tester.pumpAndSettle();
      expect(stats.requests, 1);
      expect(intents.settingsOpened, 0,
          reason: '팝업이 가능한데 설정으로 보내면 한 탭이 두 탭이 된다');
    });

    testWidgets('팝업을 띄울 수 없으면 "알림 켜기"가 설정 화면을 연다', (tester) async {
      // 영구 거부(2회 거부)·Android 12 이하의 앱 단위 차단·채널 차단 — 이 상태의
      // 요청은 UI 없이 즉시 거부된다. 요청만 던지면 "알림 켜기"를 눌렀는데
      // 아무 일도 없는 막다른 탭이 된다(CG1).
      await pump(tester, canRequest: false);
      await _register(tester, 'GKEY01');
      signaling.emit('pair_ok', {'guardianDeviceKey': _guardianKey});
      await _drainTimers(tester);

      await tester.tap(find.text('알림 켜기'));
      await tester.pumpAndSettle();
      expect(stats.requests, 0, reason: '뜨지도 않을 팝업을 요청하지 않는다');
      expect(intents.settingsOpened, 1,
          reason: '무반응 대신 설정 화면 — 남아 있는 유일한 복구 경로');
    });

    testWidgets('페어링이 실패하면 묻지 않는다', (tester) async {
      await pump(tester);
      await _register(tester, 'GKEY01');
      // 코드가 어긋난 응답 — 앵커가 서지 않으므로 코칭도 불가하다.
      signaling.emit('pair_ok', {'guardianDeviceKey': _otherKey});
      await _drainTimers(tester);

      expect(find.text('알림을 켜 주세요'), findsNothing,
          reason: '쓰지도 못할 기능 때문에 두 번뿐인 기회를 태우면 안 된다');
      expect(stats.requests, 0);
    });

    testWidgets('이미 허용돼 있으면 묻지 않는다', (tester) async {
      await pump(tester, granted: true);
      await _register(tester, 'GKEY01');
      signaling.emit('pair_ok', {'guardianDeviceKey': _guardianKey});
      await _drainTimers(tester);

      expect(find.text('알림을 켜 주세요'), findsNothing);
      expect(stats.requests, 0);
    });

    testWidgets('"나중에"를 고르면 요청하지 않는다', (tester) async {
      await pump(tester);
      await _register(tester, 'GKEY01');
      signaling.emit('pair_ok', {'guardianDeviceKey': _guardianKey});
      await _drainTimers(tester);

      await tester.tap(find.text('나중에'));
      await tester.pumpAndSettle();
      expect(stats.requests, 0);
    });
  });

  group('이미 등록을 마친 어르신', () {
    testWidgets('알림이 꺼져 있으면 상태와 설정 경로를 보여준다', (tester) async {
      // 등록을 이미 마친 사람은 _askNotice를 지나가지 않는다 — 이 카드가 유일한 통로다.
      await pump(tester, bound: true);

      expect(find.text('알림이 꺼져 있어요'), findsOneWidget);
      // 2회 거부 뒤에는 앱에서 다시 물어도 아무 일이 없다 — 설정으로 보낸다(CG1).
      await tester.tap(find.text('설정에서 켜기'));
      await tester.pumpAndSettle();
      expect(intents.settingsOpened, 1);
      expect(stats.requests, 0, reason: '막다른 길이 되는 재요청 버튼을 두지 않는다');
    });

    testWidgets('연결된 보호자가 없으면 경고를 띄우지 않는다', (tester) async {
      await pump(tester);

      expect(find.text('알림이 꺼져 있어요'), findsNothing,
          reason: '코칭이 불가능한 상태에서는 알림이 없어도 잃는 것이 없다');
    });
  });
}
