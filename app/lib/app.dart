import 'dart:async';

import 'package:flutter/material.dart';

import 'ai/intent_router.dart';
import 'ai/llm_runtime.dart';
import 'core/config.dart';
import 'core/db.dart';
import 'core/theme.dart';
import 'features/apps/app_repository.dart';
import 'features/coaching/coaching_controller.dart';
import 'features/coaching/device_identity.dart';
import 'features/coaching/guardian_controller.dart';
import 'features/coaching/guardian_home_screen.dart';
import 'features/coaching/role_screen.dart';
import 'features/coaching/coaching_signaling.dart';
import 'features/coaching/guardian_repository.dart';
import 'features/launcher/launcher_screen.dart';
import 'features/model/model_manager.dart';
import 'features/onboarding/welcome_screen.dart';
import 'features/routine/usage_repository.dart';
import 'features/voice/voice_controller.dart';

/// 앱 전역 의존성 — main에서 1회 조립해 화면 계층에 주입한다.
class OngiDeps {
  OngiDeps._({
    required this.apps,
    required this.llm,
    required this.model,
    required this.voice,
    required this.usage,
    required this.guardians,
    required this.coaching,
    required this.signaling,
    required this.identity,
    required this.guardianMode,
  });

  factory OngiDeps() {
    final apps = AppRepository();
    final llm = LlmRuntime();
    final voice = VoiceController(
      // llm.ask는 미설치·경량 모드에서 즉시 실패 → 라우터가 규칙 폴백 처리.
      // 타임아웃을 라우터 SLA(12s)와 정렬 — 기본 30s면 라우터가 폴백한 뒤에도
      // 생성이 최대 18초 슬롯을 점유해 후속 발화가 전부 규칙 폴백으로 밀린다.
      router: IntentRouter(
        llmAsk: (prompt) =>
            llm.ask(prompt, timeout: const Duration(seconds: 12)),
      ),
      getApps: () async => [
        for (final entry in await apps.allApps())
          VoiceApp(
            packageName: entry.packageName,
            label: entry.label,
            aliases: entry.aliases,
          ),
      ],
      launchApp: apps.launch,
    );
    // 저장된 말 빠르기 복원 — 비차단(실패·미설정이면 기본 0.75).
    unawaited(OngiDatabase.instance
        .getSetting(OngiConfig.ttsRateSettingKey)
        .then((value) async {
      final rate = double.tryParse(value ?? '');
      if (rate != null) await voice.setSpeechRate(rate);
    }).catchError((_) {}));
    // 보호자 통화 코칭(docs/50_guardian_coaching.md) — 릴레이는 전달만 하고
    // 세션 판정은 기기가 한다. deviceKey는 부트스트랩에서 채운다.
    final guardians = GuardianRepository();
    final identity = DeviceIdentity();
    // 주소는 기기 설정에서만 온다 — 코드에 박힌 기본 주소가 없다.
    final signaling = WebSocketSignaling(() => identity.relayUrl);
    return OngiDeps._(
      apps: apps,
      llm: llm,
      model: ModelManager(),
      voice: voice,
      usage: UsageRepository(),
      guardians: guardians,
      coaching: CoachingController(
        guardians: guardians,
        signaling: signaling,
        deviceKey: '',
      ),
      signaling: signaling,
      identity: identity,
      guardianMode: GuardianController(signaling: signaling),
    );
  }

  final AppRepository apps;
  final LlmRuntime llm;
  final ModelManager model;
  final VoiceController voice;
  final UsageRepository usage;
  final GuardianRepository guardians;
  final CoachingController coaching;
  final CoachingSignaling signaling;
  final DeviceIdentity identity;
  final GuardianController guardianMode;
}

class OngiApp extends StatelessWidget {
  const OngiApp({super.key, required this.deps});

  final OngiDeps deps;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '온기',
      theme: ongiTheme(),
      home: _RootGate(deps: deps),
    );
  }
}

/// 온보딩 게이트 — 최초 실행이면 환영 화면(§8 [1]), 이후에는 바로 런처.
class _RootGate extends StatefulWidget {
  const _RootGate({required this.deps});

  final OngiDeps deps;

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  static const _onboardedKey = 'onboarded';

  bool? _onboarded;
  bool _roleChosen = false;

  /// 마지막으로 연결을 세워 둔 역할·주소 — 같은 값으로 중복 연결하지 않기 위해 둔다.
  String _wiredRole = '';
  String _wiredRelay = '';

  @override
  void initState() {
    super.initState();
    widget.deps.identity.addListener(_onIdentityChanged);
    unawaited(_check());
  }

  @override
  void dispose() {
    widget.deps.identity.removeListener(_onIdentityChanged);
    super.dispose();
  }

  Future<void> _check() async {
    String? value;
    try {
      value = await OngiDatabase.instance.getSetting(_onboardedKey);
    } catch (_) {
      value = '1'; // DB 문제로 온보딩에 갇히지 않도록 런처로 진행.
    }
    // 부트스트랩과 경쟁하지 않도록 여기서도 기다린다 — 먼저 읽으면 역할을 이미
    // 고른 사용자에게 선택 화면이 다시 뜬다. load()는 멱등이다.
    try {
      await widget.deps.identity.load();
    } catch (_) {}
    _wiredRole = widget.deps.identity.role;
    _wiredRelay = widget.deps.identity.relayUrl;
    if (mounted) {
      setState(() {
        _onboarded = value == '1';
        _roleChosen = widget.deps.identity.roleChosen;
      });
    }
  }

  /// 역할은 최초 선택으로 끝나지 않는다 — 설정에서 되돌릴 수 있어야 하고(역할
  /// 선택 화면이 그렇게 약속한다), 그때 연결도 새 역할에 맞춰 다시 세운다.
  void _onIdentityChanged() {
    final role = widget.deps.identity.role;
    final relay = widget.deps.identity.relayUrl;
    // 릴레이 주소가 바뀌는 것도 "지금 붙어 있는 연결이 틀렸다"는 신호다 — 역할
    // 변경과 같은 경로로 다시 세운다. 안 그러면 주소를 고쳐도 앱을 껐다 켜기
    // 전까지 옛 주소(또는 미연결 상태)에 머문다.
    if (role != _wiredRole || relay != _wiredRelay) {
      _wiredRole = role;
      _wiredRelay = relay;
      unawaited(_wire(role));
    }
    if (mounted) {
      setState(() => _roleChosen = widget.deps.identity.roleChosen);
    }
  }

  /// 보호자 모드는 시그널링에 상시로 붙는다 — 요청을 받으려면 연결이 살아 있어야
  /// 하기 때문(FCM 대신 자체 WebSocket을 쓰는 대가). 어르신도 여기서 붙어야 한다:
  /// 부트스트랩은 역할 선택 전에 돌아 건너뛰므로, 빠뜨리면 설치 직후 페어링·
  /// 도움요청이 재시작 전까지 전부 실패한다.
  Future<void> _wire(String role) async {
    final key = widget.deps.identity.deviceKey;
    // 진행 중이던 어르신 세션을 소켓이 살아 있을 때 정상 종료한다. 그냥 닫으면
    // 보호자는 끊김을 늦게 알고, 감사 로그는 열린 채 남고, 단계가 talking에
    // 고착돼 나중에 어르신으로 돌아와도 새 요청이 막힌다. idle·ended면 no-op이다.
    try {
      await widget.deps.coaching.endByElder();
    } catch (_) {}
    widget.deps.coaching.dismissSummary();
    // 역할을 바꾸면 옛 역할의 연결을 먼저 내린다 — 남겨 두면 서버 레지스트리에서
    // 같은 키로 두 역할이 경쟁한다.
    try {
      await widget.deps.signaling.close();
    } catch (_) {}
    if (role == OngiConfig.roleGuardian) {
      unawaited(
        widget.deps.guardianMode.start(deviceKey: key).catchError((_) {}),
      );
    } else if (role == OngiConfig.roleElder) {
      unawaited(widget.deps.guardianMode.hangUp(notify: true).catchError((_) {}));
      unawaited(
        widget.deps.signaling
            .connect(deviceKey: key, role: OngiConfig.roleElder)
            .catchError((_) {}),
      );
    }
  }

  void _chooseRole(String role) =>
      unawaited(widget.deps.identity.setRole(role).catchError((_) {}));

  Future<void> _start() async {
    try {
      await OngiDatabase.instance.setSetting(_onboardedKey, '1');
    } catch (_) {}
    if (mounted) setState(() => _onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarded != null && !_roleChosen) {
      return RoleScreen(
        identity: widget.deps.identity,
        onChosen: _chooseRole,
      );
    }
    if (_roleChosen && widget.deps.identity.isGuardian) {
      return GuardianHomeScreen(
        controller: widget.deps.guardianMode,
        identity: widget.deps.identity,
      );
    }
    return switch (_onboarded) {
      null => const Scaffold(body: SizedBox.shrink()),
      false => WelcomeScreen(onStart: _start),
      true => LauncherScreen(
          apps: widget.deps.apps,
          model: widget.deps.model,
          llm: widget.deps.llm,
          voice: widget.deps.voice,
          usage: widget.deps.usage,
          guardians: widget.deps.guardians,
          coaching: widget.deps.coaching,
          signaling: widget.deps.signaling,
          identity: widget.deps.identity,
        ),
    };
  }
}
