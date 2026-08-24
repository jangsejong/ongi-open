// 신뢰 앵커(ADR-21)가 **처음 만들어지는** 페어링 경로의 회귀 테스트.
//
// 세션 수락(accepted)에는 기기 측 키 대조가 있었지만, 앵커를 만드는 pair_ok에는
// 없었다. 어르신 기기 키를 아는 피어가 pair_ok를 먼저 쏘면 그 키가 그대로 "큰딸"의
// 앵커로 저장돼, 이후 도움 요청과 화면 공유가 그 피어에게 열린다.
// 코드는 키 앞 6자의 결정적 파생이므로 기기가 서버 없이 대조할 수 있다.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/elder_auth.dart';
import 'package:ongi/features/coaching/guardian_repository.dart';
import 'package:ongi/features/coaching/guardian_setup_screen.dart';
import 'package:ongi/native/ongi_native.g.dart';

class FakeSignaling implements CoachingSignaling {
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
class MemoryGuardians extends GuardianRepository {
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

class FakeAuth extends ElderAuth {
  @override
  Future<ElderAuthResult> confirm(String reason) async => ElderAuthResult.ok;
}

/// 알림 권한은 허용된 것으로 둔다 — 이 파일의 관심사는 앵커뿐이고, 페어링 성공
/// 직후의 알림 안내는 `notification_permission_test.dart`가 따로 본다.
class GrantedStats extends DeviceStatsApi {
  @override
  Future<bool> isPostNotificationsGranted() async => true;
}

/// 보호자 키 — 앞 6자 'GKEY01'이 어르신이 입력할 코드가 된다.
const _guardianKey = 'gkey01abcdefghijklmnopqrst';
const _attackerKey = 'zzzz99abcdefghijklmnopqrst';

Future<void> _register(WidgetTester tester, String code) async {
  await tester.tap(find.text('보호자 추가하기'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).at(0), '큰딸');
  await tester.enterText(find.byType(TextField).at(1), '01012345678');
  await tester.enterText(find.byType(TextField).at(2), code);
  await tester.tap(find.text('저장'));
  await tester.pumpAndSettle();
}

/// 페어링 한 판을 끝까지 흘려보낸다.
///
/// 브로드캐스트 구독의 `cancel()`은 위젯 테스트의 fake async 펌프만으로는 풀리지
/// 않아 실제 비동기 한 턴이 필요하고, 60초 대기와 4초 토스트 타이머는 남겨 두면
/// 테스트 프레임워크가 pending timer로 실패시킨다.
Future<void> _drainTimers(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 61));
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle(const Duration(seconds: 5));
}

void main() {
  late MemoryGuardians guardians;
  late FakeSignaling signaling;

  Future<void> pump(WidgetTester tester) async {
    guardians = MemoryGuardians();
    signaling = FakeSignaling();
    await tester.pumpWidget(MaterialApp(
      home: GuardianSetupScreen(
        guardians: guardians,
        signaling: signaling,
        auth: FakeAuth(),
        stats: GrantedStats(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('입력한 코드와 맞는 pair_ok만 신뢰 앵커가 된다', (tester) async {
    await pump(tester);
    await _register(tester, 'GKEY01');

    expect(signaling.sent.single.type, 'pair_request');
    expect(signaling.sent.single.data['code'], 'GKEY01');

    signaling.emit('pair_ok', {'guardianDeviceKey': _guardianKey});
    await _drainTimers(tester);

    final saved = (await guardians.all()).single;
    expect(saved.deviceKey, _guardianKey);
    expect(saved.approved, isTrue);
  });

  testWidgets('코드가 다른 pair_ok는 앵커로 저장되지 않는다', (tester) async {
    await pump(tester);
    await _register(tester, 'GKEY01');

    // 어르신 키를 아는 제3자가 자기 키로 먼저 응답하는 상황.
    signaling.emit('pair_ok', {'guardianDeviceKey': _attackerKey});
    await _drainTimers(tester);

    final saved = (await guardians.all()).single;
    expect(saved.deviceKey, isEmpty, reason: '공격자 키가 앵커가 되면 안 된다');
    expect(saved.approved, isFalse);
  });

  testWidgets('위조 응답이 먼저 와도 진짜 보호자의 수락이 살아남는다', (tester) async {
    await pump(tester);
    await _register(tester, 'GKEY01');

    // 선점 시도 — 무시되고 계속 기다려야 한다.
    signaling.emit('pair_ok', {'guardianDeviceKey': _attackerKey});
    await tester.pump();
    signaling.emit('pair_ok', {'guardianDeviceKey': _guardianKey});
    await _drainTimers(tester);

    final saved = (await guardians.all()).single;
    expect(saved.deviceKey, _guardianKey);
    expect(saved.approved, isTrue);
  });

  testWidgets('빈 키를 실은 pair_ok도 앵커가 되지 않는다', (tester) async {
    await pump(tester);
    await _register(tester, 'GKEY01');

    signaling.emit('pair_ok', {'guardianDeviceKey': ''});
    await _drainTimers(tester);

    expect((await guardians.all()).single.approved, isFalse);
  });
}
