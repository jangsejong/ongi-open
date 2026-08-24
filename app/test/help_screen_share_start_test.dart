// "화면 보여주기" 중복 탭 잠금의 **시점** 회귀 테스트.
//
// 잠금(_starting)이 첫 await 뒤에 걸리면 그 사이의 두 번째 탭이 가드를 통과한다 —
// 사용정보 안내 다이얼로그가 겹으로 뜨거나, 권한이 있는 경로에서는 두 번째 호출이
// ScreenShare 가드에 막혀 공유가 정상 시작되는 순간 "시작하지 못했어요"가 함께 뜬다.
// QA 절차가 명시적으로 빠른 두 번 탭을 지시하므로(§6), 잠금은 탭 직후(첫 await 전)에
// 걸리고 절차가 끝나면 풀려야 한다.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/apps/app_repository.dart';
import 'package:ongi/features/coaching/coaching_controller.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/guardian_repository.dart';
import 'package:ongi/features/coaching/help_screen.dart';
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
  _MemoryGuardians(this._rows);

  final List<Guardian> _rows;

  @override
  Future<List<Guardian>> all() async => List.of(_rows);

  @override
  Future<List<AssistSession>> history({int limit = 50}) async => const [];

  @override
  Future<String> startSession({
    required Guardian guardian,
    required int nowMs,
  }) async =>
      'log1';

  @override
  Future<void> finishSession({
    required String sessionId,
    required int nowMs,
    required bool shared,
    required bool sensitiveSeen,
    required String endReason,
  }) async {}
}

class _FakeUsage extends UsageStatsApi {
  _FakeUsage({required this.granted});

  final bool granted;
  int checks = 0;
  int settingsOpened = 0;

  @override
  Future<bool> isUsageAccessGranted() async {
    checks++;
    return granted;
  }

  @override
  Future<void> openUsageAccessSettings() async => settingsOpened++;
}

class _FakeCoachingApi extends CoachingApi {
  @override
  Future<bool> startShareService() async => false;

  @override
  Future<void> stopShareService() async {}

  @override
  Future<String> foregroundPackage() async => '';
}

class _FakeIntents extends IntentActionsApi {
  @override
  Future<bool> openDialer() async => true;
}

const _guardianKey = 'gkey01abcdefghijklmnopqrst';

void main() {
  /// 통화(talking) 단계까지 세운 HelpScreen을 띄운다 — "화면 보여주기"가 보이는 상태.
  Future<_FakeUsage> pumpTalking(WidgetTester tester) async {
    const guardian = Guardian(
      id: 'g1',
      name: '큰딸',
      phone: '01012345678',
      deviceKey: _guardianKey,
      approved: true,
      approvedUntilMs: 0,
      createdMs: 0,
    );
    final guardians = _MemoryGuardians([guardian]);
    final signaling = _FakeSignaling();
    final usage = _FakeUsage(granted: false);
    final controller = CoachingController(
      guardians: guardians,
      signaling: signaling,
      deviceKey: 'elder0abcdefghijklmnopqrst',
    );
    await controller.requestHelp(guardian);
    signaling.emit('accepted', {'guardianDeviceKey': _guardianKey, 'sessionId': 's1'});
    // 브로드캐스트 스트림 전달 — FakeAsync 존에서 Future.delayed는 타이머라 영영
    // 깨어나지 않는다. pump가 마이크로태스크를 흘려보낸다.
    await tester.pump();
    expect(controller.phase, CoachingPhase.talking);

    await tester.pumpWidget(MaterialApp(
      home: HelpScreen(
        controller: controller,
        guardians: guardians,
        apps: AppRepository(),
        signaling: signaling,
        intents: _FakeIntents(),
        native: _FakeCoachingApi(),
        usage: usage,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('화면 보여주기'), findsOneWidget);
    return usage;
  }

  testWidgets('빠른 두 번 탭에도 사용정보 안내는 한 번만 뜨고 버튼이 잠긴다',
      (tester) async {
    final usage = await pumpTalking(tester);

    // 첫 탭의 setState가 반영되기 전(리빌드 전) 두 번째 탭 — 실기기의 빠른 연타.
    await tester.tap(find.text('화면 보여주기'));
    await tester.tap(find.text('화면 보여주기'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('먼저 허용해 주실 것이 있어요'), findsOneWidget);
    expect(usage.checks, 1); // 두 번째 탭은 권한 확인까지도 가면 안 된다
    // 안내가 떠 있는 동안 뒤의 버튼은 잠겨 있어야 한다.
    expect(find.text('준비하고 있어요…'), findsOneWidget);
  });

  testWidgets('"나중에"로 물러나면 잠금이 풀려 다시 시도할 수 있다', (tester) async {
    final usage = await pumpTalking(tester);

    await tester.tap(find.text('화면 보여주기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('나중에'));
    await tester.pumpAndSettle();

    // 잠금이 풀리지 않으면 이 버튼이 영영 "준비하고 있어요…"로 남는다.
    expect(find.text('화면 보여주기'), findsOneWidget);
    expect(find.text('먼저 허용해 주실 것이 있어요'), findsNothing);

    // 다시 누르면 안내가 다시 떠야 한다(막다른 길 아님).
    await tester.tap(find.text('화면 보여주기'));
    await tester.pumpAndSettle();
    expect(find.text('먼저 허용해 주실 것이 있어요'), findsOneWidget);
    expect(usage.checks, 2);
  });
}
