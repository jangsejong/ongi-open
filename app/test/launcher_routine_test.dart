import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/ai/intent_router.dart';
import 'package:ongi/ai/llm_runtime.dart';
import 'package:ongi/core/config.dart';
import 'package:ongi/core/theme.dart';
import 'package:ongi/features/coaching/coaching_controller.dart';
import 'package:ongi/features/coaching/device_identity.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/guardian_repository.dart';
import 'package:ongi/features/apps/app_repository.dart';
import 'package:ongi/features/launcher/launcher_screen.dart';
import 'package:ongi/features/model/model_manager.dart';
import 'package:ongi/features/routine/routine_phrase.dart';
import 'package:ongi/features/routine/usage_repository.dart';
import 'package:ongi/features/voice/voice_controller.dart';

/// 분류 결과 주입용 페이크 — 플랫폼 채널·DB 없이 런처를 띄운다.
class _FakeApps extends AppRepository {
  _FakeApps(this.entries);

  final List<AppEntry> entries;

  @override
  Future<void> syncInstalledApps() async {}

  @override
  Future<Map<LifeCategory, List<AppEntry>>> appsByCategory() async {
    final map = {for (final c in LifeCategory.values) c: <AppEntry>[]};
    for (final e in entries) {
      map[e.category]!.add(e);
    }
    return map;
  }

  @override
  Future<Uint8List?> icon(String packageName) async => null;
}

class _FakeUsage extends UsageRepository {
  _FakeUsage(this.sessions);

  final List<UsageSession> sessions;

  @override
  Future<bool> isGranted() async => true;

  @override
  Future<void> sync() async {}

  @override
  Future<List<UsageSession>> recentSessions({int days = 14}) async => sessions;
}

UsageSession session(String pkg, DateTime start, {int minutes = 10}) =>
    UsageSession(
      packageName: pkg,
      startMs: start.millisecondsSinceEpoch,
      endMs: start.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
    );

Widget launcher({
  required List<AppEntry> entries,
  required List<UsageSession> sessions,
}) {
  return MaterialApp(
    theme: ongiTheme(),
    home: LauncherScreen(
      apps: _FakeApps(entries),
      model: ModelManager(),
      llm: LlmRuntime(),
      voice: VoiceController(
        router: IntentRouter(llmAsk: null),
        getApps: () async => const [],
        launchApp: (_) async => false,
      ),
      usage: _FakeUsage(sessions),
      guardians: GuardianRepository(),
      coaching: _coaching(_SilentSignaling()),
      signaling: _SilentSignaling(),
      identity: DeviceIdentity(),
    ),
  );
}

void main() {
  const youtube = AppEntry(
    packageName: 'com.google.android.youtube',
    label: '유튜브',
    category: LifeCategory.media,
    categorySource: 'rule',
  );

  testWidgets('온기·홈 런처가 사용기록 상위를 독점해도 런처 앱이 추천된다', (tester) async {
    final now = DateTime.now();
    final sessions = [
      // 온기 자신·홈 런처: 매일 같은 시간대 등장(활동일수 최상위) — 후보 제외 대상.
      for (var d = 1; d <= 5; d++) ...[
        session('kr.tsp.ongi', now.subtract(Duration(days: d))),
        session('com.sec.android.app.launcher', now.subtract(Duration(days: d))),
      ],
      // 유튜브: 같은 시간대 3일 — 실제 추천돼야 하는 습관.
      for (var d = 1; d <= 3; d++)
        session('com.google.android.youtube', now.subtract(Duration(days: d))),
    ];
    await tester.pumpWidget(launcher(entries: [youtube], sessions: sessions));
    await tester.pump(); // appsByCategory·루틴 로드 반영
    await tester.pump(const Duration(seconds: 11)); // 루틴 문구 10s 유예 타이머 소진

    expect(find.text('유튜브'), findsOneWidget); // 추천 카드 버튼
    expect(find.text(routineFallbackPhrase), findsOneWidget);
    expect(find.textContaining('배우는 중'), findsNothing);
  });

  testWidgets('기록 3일 미만이면 추천 대신 배우는 중 안내가 보인다', (tester) async {
    final now = DateTime.now();
    final sessions = [
      session('com.google.android.youtube', now.subtract(const Duration(days: 1))),
    ];
    await tester.pumpWidget(launcher(entries: [youtube], sessions: sessions));
    await tester.pump();

    expect(find.textContaining('배우는 중'), findsOneWidget);
    expect(find.text(routineFallbackPhrase), findsNothing);
  });
}

/// 코칭 의존성 — 런처 렌더에만 필요하고 세션을 열지 않으므로 최소 가짜로 채운다.
class _SilentSignaling implements CoachingSignaling {
  @override
  Stream<SignalMessage> get messages => const Stream.empty();
  @override
  bool get connected => false;
  @override
  Future<void> connect({required String deviceKey, required String role}) async {}
  @override
  Future<void> send(SignalMessage message) async {}
  @override
  Future<void> close() async {}
}

CoachingController _coaching(CoachingSignaling signaling) => CoachingController(
      guardians: GuardianRepository(),
      signaling: signaling,
      deviceKey: 'test',
    );
