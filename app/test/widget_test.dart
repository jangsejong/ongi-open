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
import 'package:ongi/features/routine/usage_repository.dart';
import 'package:ongi/features/voice/voice_controller.dart';

/// 플랫폼 채널·DB 없이 런처를 띄우기 위한 페이크(스캔·분류 결과 주입).
class _FakeApps extends AppRepository {
  @override
  Future<void> syncInstalledApps() async {}

  @override
  Future<Map<LifeCategory, List<AppEntry>>> appsByCategory() async => {
        for (final category in LifeCategory.values) category: [],
      };

  @override
  Future<Uint8List?> icon(String packageName) async => null;
}

class _FakeUsage extends UsageRepository {
  @override
  Future<bool> isGranted() async => false;
}

void main() {
  test('모델 상수가 결과보고서 붙임2와 일치하는 형식', () {
    expect(OngiConfig.modelFileName, endsWith('.litertlm'));
    expect(OngiConfig.modelSizeBytes, 2588147712);
    expect(OngiConfig.modelSha256.length, 64);
    expect(OngiConfig.modelUrl, contains(OngiConfig.modelRepo));
    expect(OngiConfig.maxTokens, greaterThanOrEqualTo(1024)); // .litertlm 최소 컨텍스트
  });

  Widget launcher() => MaterialApp(
        theme: ongiTheme(),
        home: LauncherScreen(
          apps: _FakeApps(),
          model: ModelManager(),
          llm: LlmRuntime(),
          voice: VoiceController(
            router: IntentRouter(llmAsk: null),
            getApps: () async => const [],
            launchApp: (_) async => false,
          ),
          usage: _FakeUsage(),
          guardians: GuardianRepository(),
          coaching: _coaching(_SilentSignaling()),
          signaling: _SilentSignaling(),
          identity: DeviceIdentity(),
        ),
      );

  testWidgets('런처 카테고리는 페이지 방식 — 이전/다음으로 전부 도달한다', (tester) async {
    // 일반 폰 크기(360×760 논리) — 페이지 격자는 기기 높이와 무관하게 다 보인다.
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(launcher());
    await tester.pump(); // appsByCategory 결과 반영

    const perPage = 6; // _CategoryPager.perPage — 2열×3행
    final all = LifeCategory.values;
    final pageCount = (all.length + perPage - 1) ~/ perPage;
    for (var page = 0; page < pageCount; page++) {
      final visible = all.sublist(
        page * perPage,
        ((page + 1) * perPage).clamp(0, all.length),
      );
      for (final category in visible) {
        expect(find.text(category.label), findsOneWidget,
            reason: '${page + 1}쪽에 ${category.label} 타일이 보여야 한다');
      }
      expect(find.text('${page + 1} / $pageCount쪽'), findsOneWidget);
      if (page < pageCount - 1) {
        await tester.tap(find.text('다음'));
        await tester.pumpAndSettle(); // 페이지 전환 애니메이션 완료까지
      }
    }
    // 마지막 쪽에서 '다음'은 비활성(CG2), '이전'으로 되돌아갈 수 있다.
    await tester.tap(find.text('이전'));
    await tester.pumpAndSettle();
    expect(find.text(all[(pageCount - 2) * perPage].label), findsOneWidget);
    expect(find.text('말로 하기'), findsOneWidget); // 푸시투토크 버튼(§6)
  });

  testWidgets('앱바 액션은 텍스트 병기 설정 버튼 하나뿐이다(아이콘 단독 금지·스파이크 제거)',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(launcher());
    await tester.pump();

    expect(find.byIcon(Icons.science_outlined), findsNothing); // W1 스파이크
    expect(find.byIcon(Icons.cleaning_services_outlined), findsNothing);
    expect(find.widgetWithText(TextButton, '설정'), findsOneWidget);
    // edge-to-edge(Android 15+) 하단 내비 대비 — 핵심 CTA는 SafeArea 안에 있어야 한다.
    expect(
      find.ancestor(of: find.text('말로 하기'), matching: find.byType(SafeArea)),
      findsWidgets,
    );
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
