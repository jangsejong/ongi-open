import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/llm_runtime.dart';
import '../../core/config.dart';
import '../apps/app_repository.dart';
import '../apps/category_refiner.dart';
import '../coaching/coaching_controller.dart';
import '../coaching/coaching_signaling.dart';
import '../coaching/device_identity.dart';
import '../coaching/guardian_repository.dart';
import '../coaching/help_screen.dart';
import '../model/model_manager.dart';
import '../model/model_screen.dart';
import '../routine/routine_engine.dart';
import '../routine/routine_phrase.dart';
import '../routine/usage_permission_screen.dart';
import '../routine/usage_repository.dart';
import '../settings/settings_screen.dart';
import '../spike/spike_screen.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_screen.dart';
import 'category_apps_screen.dart';

/// 큰글씨 간편 런처 홈(M1 v1) — 앱 스캔·분류 결과를 카테고리 타일로 보여준다.
/// 첫 실행 즉시 규칙 분류로 동작하고(§8 [2]), 모델 준비 후 LLM 보정이 백그라운드로
/// 한 번 실행된다(§4.2).
class LauncherScreen extends StatefulWidget {
  const LauncherScreen({
    super.key,
    required this.apps,
    required this.model,
    required this.llm,
    required this.voice,
    required this.usage,
    required this.guardians,
    required this.coaching,
    required this.signaling,
    required this.identity,
  });

  final AppRepository apps;
  final ModelManager model;
  final LlmRuntime llm;
  final VoiceController voice;
  final UsageRepository usage;
  final GuardianRepository guardians;
  final CoachingController coaching;
  final CoachingSignaling signaling;
  final DeviceIdentity identity;

  @override
  State<LauncherScreen> createState() => _LauncherScreenState();
}

class _LauncherScreenState extends State<LauncherScreen> {
  Map<LifeCategory, List<AppEntry>> _byCategory = {
    for (final category in LifeCategory.values) category: [],
  };
  bool _refineTriggered = false;
  bool _refineDone = false;
  bool _voiceOpen = false;
  bool _usageGranted = false;
  bool _routineLearning = false;
  List<AppEntry> _routineApps = [];
  String? _routinePhrase;
  String _routinePhraseKey = '';
  bool _phraseBusy = false;

  /// 홈 복귀 직후는 음성 사용 개연성이 가장 큰 순간 — 문구 질의는 한 박자 늦게.
  static const _phraseDelay = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onModelChanged);
    // 재실행 등으로 모델이 이미 준비된 채 시작하면 phase 변경 알림이 오지 않아
    // 리스너만으로는 보정이 영영 안 돈다 — 초기 상태를 직접 확인한다.
    _maybeTriggerRefine();
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.model.removeListener(_onModelChanged);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await widget.apps.syncInstalledApps();
    } catch (_) {
      // 스캔 실패 시에도 이전 캐시로 표시(오프라인 원칙 — 빈 화면 금지).
    }
    final byCategory = await widget.apps.appsByCategory();
    if (!mounted) return;
    setState(() => _byCategory = byCategory);
    await _loadRoutine();
  }

  /// 루틴 추천(§4.2) — 권한 있으면 스냅샷 동기화 후 시간대 규칙으로 후보 산출.
  Future<void> _loadRoutine() async {
    var granted = false;
    var routineApps = <AppEntry>[];
    var learning = false;
    try {
      granted = await widget.usage.isGranted();
      if (granted) {
        await widget.usage.sync();
        final sessions = await widget.usage.recentSessions(days: 14);
        final byPackage = {
          for (final entries in _byCategory.values)
            for (final entry in entries) entry.packageName: entry,
        };
        // 런처에 보이는 앱의 세션만 후보로 — 온기 자신·홈 런처 같은 시스템
        // 패키지가 매일 등장해 limit 상위를 독점하면, 뒤의 byPackage 대조에서
        // 전부 걸러져 추천이 0개가 되던 문제(습관이 쌓여도 비활성).
        final visible = [
          for (final s in sessions)
            if (byPackage.containsKey(s.packageName)) s,
        ];
        final now = DateTime.now();
        var suggestions = RoutineEngine.suggest(visible, now: now);
        if (suggestions.isEmpty) {
          // 좁은 창(±1h)에 습관이 안 잡히면 ±2h로 한 번 넓혀 활성화율 확보.
          suggestions =
              RoutineEngine.suggest(visible, now: now, windowHours: 2);
        }
        routineApps = [for (final s in suggestions) byPackage[s.packageName]!];
        // 기록이 3일 미만이면 '배우는 중' — 카드가 통째로 사라져 동작 여부를
        // 알 수 없던 것을 안내 문구로 대체(§6 — 빈 화면 금지 원칙).
        learning = routineApps.isEmpty &&
            RoutineEngine.distinctActiveDays(visible) < 3;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _usageGranted = granted;
      _routineApps = routineApps;
      _routineLearning = learning;
    });
    _maybeGeneratePhrase(routineApps);
  }

  /// LLM 루틴 문구(§4.2) — 시간대(4구간)·추천 구성이 바뀔 때 1회 생성, 실패는
  /// 고정 문구. 카드 장식이므로 음성·카테고리 보정 등 다른 LLM 사용에 양보한다.
  void _maybeGeneratePhrase(List<AppEntry> routineApps) {
    if (routineApps.isEmpty) return;
    final key = '${timeSlotLabel(DateTime.now().hour)}:'
        '${[for (final a in routineApps) a.packageName].join(',')}';
    if (key == _routinePhraseKey) return;
    // 키가 바뀐 순간부터 이전 시간대·구성의 문구는 보여주지 않는다(실패=고정 문구).
    if (_routinePhrase != null) setState(() => _routinePhrase = null);
    if (_phraseBusy || _voiceOpen) return; // 음성 우선 — 다음 로드에서 재시도.
    if (_refineTriggered && !_refineDone) return; // 1회성 보정이 슬롯을 먼저 쓰게.
    unawaited(_generatePhrase(key, [for (final a in routineApps) a.label]));
  }

  Future<void> _generatePhrase(String key, List<String> labels) async {
    _phraseBusy = true;
    try {
      await Future<void>.delayed(_phraseDelay);
      if (!mounted || _voiceOpen) return;
      final phrase =
          await generateRoutinePhrase(widget.llm, labels, DateTime.now());
      if (!mounted || phrase == null) return;
      _routinePhraseKey = key; // 성공 시에만 고정 — 실패는 다음 로드에서 재시도.
      setState(() => _routinePhrase = phrase);
    } finally {
      _phraseBusy = false;
    }
  }

  void _onModelChanged() {
    if (!mounted) return;
    setState(() {});
    _maybeTriggerRefine();
  }

  void _maybeTriggerRefine() {
    if (widget.model.phase == ModelPhase.ready && !_refineTriggered) {
      _refineTriggered = true;
      unawaited(_refine());
    }
  }

  Future<void> _refine() async {
    var changed = 0;
    try {
      changed = await refineCategoriesWithLlm(widget.apps, widget.llm);
    } catch (_) {
      // 보정 실패는 치명적이지 않다 — 규칙 분류 상태 유지.
    }
    _refineDone = true; // 이후부터 루틴 문구 생성이 LLM 슬롯을 써도 된다.
    if (changed > 0 && mounted) await _load();
  }

  void _openModelScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ModelScreen(model: widget.model, llm: widget.llm),
      ),
    );
  }

  /// 사람에게 묻는 경로 — 세션은 여기서만 열린다(ADR-17). 인증을 요구하지 않는다.
  Future<void> _openHelpScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HelpScreen(
          controller: widget.coaching,
          guardians: widget.guardians,
          apps: widget.apps,
          signaling: widget.signaling,
        ),
      ),
    );
  }

  Future<void> _openVoiceScreen() async {
    if (_voiceOpen) return; // 이중 탭으로 화면 2장 쌓임 방지(고령자 이중 탭 흔함).
    _voiceOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VoiceScreen(controller: widget.voice),
        ),
      );
    } finally {
      _voiceOpen = false;
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          guardians: widget.guardians,
          signaling: widget.signaling,
          identity: widget.identity,
          voice: widget.voice,
          apps: widget.apps,
          usage: widget.usage,
          llm: widget.llm,
          model: widget.model,
        ),
      ),
    );
    await _load(); // 설정 안의 앱 정리(삭제) 결과 반영
  }

  void _openCategory(LifeCategory category) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => CategoryAppsScreen(
              category: category,
              entries: _byCategory[category] ?? const [],
              apps: widget.apps,
            ),
          ),
        )
        .then((_) => _load()); // 칸 이동·별칭 편집 반영
  }

  Future<void> _askUsagePermission() async {
    final granted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => UsagePermissionScreen(usage: widget.usage),
      ),
    );
    if (granted == true) await _loadRoutine();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('온기'),
        actions: [
          // W1 계측 진입 — 측정 빌드(--dart-define=SPIKE=true)에만 존재.
          // 상수 false면 SpikeScreen까지 트리셰이킹돼 데모/제출 빌드 바이너리가
          // 불변이다. v0.0.20에서 이 아이콘을 무게이트 삭제해 스파이크가 고아
          // 코드가 됐고(릴리스에 미포함 → docs/20 측정 불가), v0.0.34에서 복원.
          if (const bool.fromEnvironment('SPIKE'))
            IconButton(
              icon: const Icon(Icons.science_outlined),
              tooltip: 'W1 스파이크',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SpikeScreen()),
              ),
            ),
          // 아이콘 단독 버튼은 시니어가 기능을 유추하기 어렵다(GC1·toss①)
          // — 텍스트를 병기하고 액션은 설정 하나만 남긴다(IC1). 앱 정리는
          // 설정 화면 안의 텍스트 메뉴로 이관.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                textStyle: Theme.of(context).textTheme.titleMedium,
              ),
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined, size: 28),
              label: const Text('설정'),
            ),
          ),
        ],
      ),
      // Android 15+(targetSdk 35+)는 edge-to-edge 강제 — 하단 SafeArea가 없으면
      // '말로 하기' 버튼이 3버튼 내비게이션 바에 가려진다(상단은 AppBar가 처리).
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _ModelBanner(model: widget.model, onTap: _openModelScreen),
            _RoutineCard(
              granted: _usageGranted,
              learning: _routineLearning,
              routineApps: _routineApps,
              apps: widget.apps,
              title: _routinePhrase ?? routineFallbackPhrase,
              onAskPermission: _askUsagePermission,
            ),
            Expanded(
              child: _CategoryPager(
                byCategory: _byCategory,
                onOpen: _openCategory,
              ),
            ),
            // 초대형 푸시투토크 + 사람에게 묻는 경로. 두 버튼이 홈에 나란히 서므로
            // 색·아이콘·문구를 확실히 갈라 오인지를 막는다(40_ §4.7 ☐, GC1·toss①).
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 88,
                      child: FilledButton.icon(
                        onPressed: _openVoiceScreen,
                        icon: const Icon(Icons.mic, size: 40),
                        label: const Text('말로 하기'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 88,
                      child: FilledButton.tonalIcon(
                        onPressed: _openHelpScreen,
                        icon: const Icon(Icons.support_agent, size: 36),
                        label: const Text('도와주세요'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 카테고리 페이지 방식(2열×3행 고정 6칸) — 시니어는 하단이 안 보이면 스크롤을
/// 시도하지 않아 세로 스크롤 그리드의 하단 카테고리를 발견하지 못한다(가이드라인
/// CF3·toss⑤). 이전/다음 큰 버튼 + 현재 쪽 표시로 전체 카테고리 도달을 보장하고,
/// 익숙한 좌우 스와이프도 함께 허용한다(3-7 인터랙션).
class _CategoryPager extends StatefulWidget {
  const _CategoryPager({required this.byCategory, required this.onOpen});

  final Map<LifeCategory, List<AppEntry>> byCategory;
  final void Function(LifeCategory category) onOpen;

  /// 한 쪽 6칸(2×3) — 모바일 그리드 상한 12(GA401) 안에서 타일을 크게(GA4).
  static const perPage = 6;

  @override
  State<_CategoryPager> createState() => _CategoryPagerState();
}

class _CategoryPagerState extends State<_CategoryPager> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    _controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <List<LifeCategory>>[
      for (var i = 0;
          i < LifeCategory.values.length;
          i += _CategoryPager.perPage)
        LifeCategory.values.sublist(
          i,
          (i + _CategoryPager.perPage).clamp(0, LifeCategory.values.length),
        ),
    ];
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (page) => setState(() => _page = page),
            itemCount: pages.length,
            itemBuilder: (context, index) => _CategoryPage(
              categories: pages[index],
              byCategory: widget.byCategory,
              onOpen: widget.onOpen,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: _PageNavButton(
                  // 끝 쪽에서는 비활성화 — 오조작 자체를 차단(CG2).
                  onPressed: _page == 0 ? null : () => _goTo(_page - 1),
                  icon: Icons.chevron_left,
                  label: '이전',
                  iconLeading: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '${_page + 1} / ${pages.length}쪽',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: _PageNavButton(
                  onPressed: _page == pages.length - 1
                      ? null
                      : () => _goTo(_page + 1),
                  icon: Icons.chevron_right,
                  label: '다음',
                  iconLeading: false,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 이전/다음 쪽 이동 버튼 — 좁은 화면·큰 시스템 글꼴에서도 넘치지 않도록
/// 내용물을 비율 축소한다(정보 잘림 금지).
class _PageNavButton extends StatelessWidget {
  const _PageNavButton({
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.iconLeading,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool iconLeading;

  @override
  Widget build(BuildContext context) {
    final content = <Widget>[
      Icon(icon, size: 28),
      Text(label),
    ];
    return SizedBox(
      height: 56,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: Theme.of(context).textTheme.titleMedium,
        ),
        onPressed: onPressed,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: iconLeading ? content : content.reversed.toList(),
          ),
        ),
      ),
    );
  }
}

/// 한 쪽 분량의 고정 2×3 격자 — Expanded 격자라 기기 높이와 무관하게 항상
/// 전부 화면 안에 들어간다(스크롤 없음). 마지막 쪽의 빈 자리는 여백으로 채워
/// 타일 크기를 쪽마다 동일하게 유지한다(GA3 일관성).
class _CategoryPage extends StatelessWidget {
  const _CategoryPage({
    required this.categories,
    required this.byCategory,
    required this.onOpen,
  });

  final List<LifeCategory> categories;
  final Map<LifeCategory, List<AppEntry>> byCategory;
  final void Function(LifeCategory category) onOpen;

  @override
  Widget build(BuildContext context) {
    final slots = List<LifeCategory?>.filled(_CategoryPager.perPage, null);
    for (var i = 0; i < categories.length; i++) {
      slots[i] = categories[i];
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        children: [
          for (var row = 0; row < 3; row++) ...[
            if (row > 0) const SizedBox(height: 12),
            Expanded(
              child: Row(
                children: [
                  for (var col = 0; col < 2; col++) ...[
                    if (col > 0) const SizedBox(width: 12),
                    Expanded(
                      child: switch (slots[row * 2 + col]) {
                        null => const SizedBox.shrink(),
                        final category => _CategoryTile(
                            category: category,
                            count: byCategory[category]?.length ?? 0,
                            onTap: () => onOpen(category),
                          ),
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 루틴 추천 카드(§4.2) — 권한 전엔 초대 문구, 권한 후엔 시간대 추천 앱 버튼.
class _RoutineCard extends StatelessWidget {
  const _RoutineCard({
    required this.granted,
    required this.learning,
    required this.routineApps,
    required this.apps,
    required this.title,
    required this.onAskPermission,
  });

  final bool granted;

  /// 기록 3일 미만 — 추천 대신 '배우는 중' 안내를 보여준다.
  final bool learning;

  final List<AppEntry> routineApps;
  final AppRepository apps;

  /// 카드 제목 — LLM 생성 문구 또는 고정 문구(routineFallbackPhrase).
  final String title;

  final VoidCallback onAskPermission;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!granted) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onAskPermission,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.schedule, size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '자주 쓰는 시간에 앱을 추천해 드릴까요?',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (routineApps.isEmpty) {
      if (!learning) return const SizedBox.shrink();
      // 기록이 쌓이는 중 — 기능이 죽은 게 아니라 배우는 중임을 알려준다.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.schedule, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '사용 습관을 배우는 중이에요 — 사흘쯤 지나면 이 시간에 맞는 앱을 추천해 드려요',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final app in routineApps) ...[
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: FilledButton.icon(
                          onPressed: () => apps.launch(app.packageName),
                          icon: FutureBuilder(
                            future: apps.icon(app.packageName),
                            builder: (context, snapshot) =>
                                snapshot.data == null
                                    ? const Icon(Icons.apps, size: 32)
                                    : Image.memory(snapshot.data!,
                                        width: 32, height: 32),
                          ),
                          label: Text(
                            app.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    if (app != routineApps.last) const SizedBox(width: 12),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 모델 상태 배너 — 미설치·진행·실패일 때만 표시(§8, ADR-11).
class _ModelBanner extends StatelessWidget {
  const _ModelBanner({required this.model, required this.onTap});

  final ModelManager model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, color, onColor) = switch (model.phase) {
      ModelPhase.absent => (
          '온기를 더 똑똑하게 만들 수 있어요 — 눌러서 받기',
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
        ),
      ModelPhase.downloading => (
          '인공지능을 받는 중이에요 (${model.progressPercent}%)',
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
        ),
      ModelPhase.verifying => (
          '받은 파일을 확인하고 있어요…',
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
        ),
      ModelPhase.failed => (
          '받기에 실패했어요 — 눌러서 다시 시도',
          scheme.errorContainer,
          scheme.onErrorContainer,
        ),
      _ => (null, scheme.surface, scheme.onSurface),
    };
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: onColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.count,
    required this.onTap,
  });

  final LifeCategory category;
  final int count;
  final VoidCallback onTap;

  static const _icons = <LifeCategory, IconData>{
    LifeCategory.phone: Icons.call,
    LifeCategory.bank: Icons.account_balance,
    LifeCategory.card: Icons.credit_card,
    LifeCategory.invest: Icons.trending_up,
    LifeCategory.transport: Icons.directions_bus,
    LifeCategory.shopping: Icons.shopping_cart,
    LifeCategory.publicService: Icons.location_city,
    LifeCategory.health: Icons.local_hospital,
    LifeCategory.photo: Icons.photo,
    LifeCategory.media: Icons.live_tv,
    LifeCategory.sns: Icons.groups,
    LifeCategory.game: Icons.sports_esports,
    LifeCategory.tools: Icons.language,
    LifeCategory.etc: Icons.apps,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        // 타일 높이는 기기마다 달라진다(페이지 격자의 Expanded) — 좁은 화면에서는
        // 내용물을 비율 축소해 넘침 없이 항상 온전히 보이게 한다.
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_icons[category],
                    size: 44, color: scheme.onPrimaryContainer),
                const SizedBox(height: 8),
                Text(
                  category.label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(color: scheme.onPrimaryContainer),
                ),
                if (count > 0)
                  Text(
                    '$count개',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onPrimaryContainer),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
