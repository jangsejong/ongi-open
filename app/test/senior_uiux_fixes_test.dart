import 'package:ongi/features/coaching/guardian_repository.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/ai/intent_router.dart';
import 'package:ongi/ai/llm_runtime.dart';
import 'package:ongi/core/config.dart';
import 'package:ongi/core/theme.dart';
import 'package:ongi/features/apps/app_repository.dart';
import 'package:ongi/features/launcher/category_apps_screen.dart';
import 'package:ongi/features/model/model_manager.dart';
import 'package:ongi/features/routine/usage_repository.dart';
import 'package:ongi/features/settings/settings_screen.dart';
import 'package:ongi/features/voice/voice_controller.dart';

/// 시니어 UI/UX P0/P1 반영 회귀 테스트 — 근거: docs/40_senior_uiux_design.md §4,
/// senior-uiux 스킬 원칙 #1(버튼은 버튼처럼)·#2(텍스트 병기).
class _FakeApps extends AppRepository {
  final launched = <String>[];

  @override
  Future<bool> launch(String packageName) async {
    launched.add(packageName);
    return true;
  }

  @override
  Future<Uint8List?> icon(String packageName) async => null;
}

class _FakeUsage extends UsageRepository {
  @override
  Future<bool> isGranted() async => false;
}

void main() {
  const youtube = AppEntry(
    packageName: 'com.google.android.youtube',
    label: '유튜브',
    category: LifeCategory.media,
    categorySource: 'rule',
  );

  testWidgets("앱 목록 '바꾸기' 버튼 — 길게 누르기 없이 싱글 탭으로 편집 시트가 열린다",
      (tester) async {
    final apps = _FakeApps();
    await tester.pumpWidget(
      MaterialApp(
        theme: ongiTheme(),
        home: CategoryAppsScreen(
          category: LifeCategory.media,
          entries: const [youtube],
          apps: apps,
        ),
      ),
    );

    await tester.tap(find.text('바꾸기'));
    await tester.pumpAndSettle();
    expect(find.text('부르는 이름 추가'), findsOneWidget);
    expect(find.text('다른 칸으로 옮기기'), findsOneWidget);
    expect(apps.launched, isEmpty); // 편집 진입이 실행으로 새지 않는다.
  });

  testWidgets('앱 행 탭은 여전히 앱 실행이다(바꾸기 버튼과 분리)', (tester) async {
    final apps = _FakeApps();
    await tester.pumpWidget(
      MaterialApp(
        theme: ongiTheme(),
        home: CategoryAppsScreen(
          category: LifeCategory.media,
          entries: const [youtube],
          apps: apps,
        ),
      ),
    );

    await tester.tap(find.text('유튜브'));
    await tester.pump();
    expect(apps.launched, ['com.google.android.youtube']);
  });

  testWidgets("설정 화면에 '안 쓰는 앱 정리' 텍스트 메뉴가 있다(런처 앱바에서 이관)",
      (tester) async {
    // 항목이 늘어 스크롤 화면이 됐다 — 세로를 넉넉히 잡아 전 항목을 렌더.
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ongiTheme(),
        home: SettingsScreen(
          guardians: GuardianRepository(),
          voice: VoiceController(
            router: IntentRouter(llmAsk: null),
            getApps: () async => const [],
            launchApp: (_) async => false,
          ),
          apps: _FakeApps(),
          usage: _FakeUsage(),
          llm: LlmRuntime(),
          model: ModelManager(),
        ),
      ),
    );

    expect(find.text('안 쓰는 앱 정리'), findsOneWidget);
    expect(find.text('말 빠르기'), findsOneWidget); // 기존 설정 항목 유지
    // LLM off(테스트 기본 tier) — 경량 모드 갇힘 복구 버튼이 노출돼야 한다(§4.3 보완).
    expect(find.text('인공지능 다시 켜보기'), findsOneWidget);
  });
}
