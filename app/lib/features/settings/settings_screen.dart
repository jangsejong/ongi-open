import '../coaching/coaching_signaling.dart';
import '../coaching/device_identity.dart';
import '../coaching/guardian_repository.dart';
import '../coaching/guardian_setup_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/llm_runtime.dart';
import '../../core/config.dart';
import '../../core/db.dart';
import '../apps/app_repository.dart';
import '../cleaner/cleaner_screen.dart';
import '../model/model_manager.dart';
import '../routine/usage_repository.dart';
import '../voice/voice_controller.dart';

/// 설정 화면(§6) — 말 빠르기 슬라이더(놓는 즉시 적용·저장 + 미리듣기),
/// 앱 정리 진입점, 인공지능 상태·복구. 런처 앱바의 아이콘 단독 액션을
/// 줄이면서(GC1·IC1) 앱 정리가 이곳의 텍스트 메뉴로 옮겨 왔다.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.voice,
    required this.apps,
    required this.usage,
    required this.llm,
    required this.model,
    required this.guardians,
    this.signaling,
    this.identity,
  });

  final VoiceController voice;
  final AppRepository apps;
  final UsageRepository usage;
  final LlmRuntime llm;
  final ModelManager model;
  final GuardianRepository guardians;
  final CoachingSignaling? signaling;
  final DeviceIdentity? identity;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late double _rate = widget.voice.speechRate;

  Future<void> _apply(double rate) async {
    await widget.voice.setSpeechRate(rate);
    try {
      await OngiDatabase.instance
          .setSetting(OngiConfig.ttsRateSettingKey, rate.toString());
    } catch (_) {} // 저장 실패해도 이번 실행에는 적용된 상태 유지.
    await widget.voice.previewSpeechRate();
  }

  /// crash 플래그로 LLM이 꺼진 채 갇히는 유일한 복구 경로가 ModelScreen인데,
  /// 경량 모드에서는 런처 배너가 숨어 그 화면에 도달할 수 없다 — 설정에서
  /// 플래그를 지우고 등급을 재산출하는 복구 버튼을 제공한다(§4.3 보완).
  Future<void> _retryAi() async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.llm.gate.clearCrashFlags();
    await widget.llm.init();
    await widget.model.check(widget.llm);
    if (!mounted) return;
    setState(() {});
    final ok = widget.llm.available;
    if (ok) {
      // 워밍업 — 첫 음성 LLM 라우팅의 콜드 로드 타임아웃 방지(§4.2).
      unawaited(widget.llm.ensureReady());
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '인공지능을 다시 켰어요. 준비에 잠시 걸릴 수 있어요.'
              : '이 기기에서는 인공지능을 사용할 수 없어요. 기본 기능은 그대로 쓸 수 있어요.',
        ),
      ),
    );
  }

  /// 역할 선택 화면이 "나중에 설정에서 바꿀 수 있어요"라고 약속한 그 경로다.
  /// 없으면 잘못 고른 어르신이 보호자 화면에 갇힌다(모델도 받지 않는다).
  Future<void> _switchToGuardian() async {
    final identity = widget.identity;
    if (identity == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('도와주는 쪽으로 바꿀까요?'),
        content: Text(
          '이 휴대폰이 가족을 도와주는 화면으로 바뀌어요.\n'
          '언제든 다시 되돌릴 수 있어요.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        actions: [
          SizedBox(
            height: 60,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('그만두기'),
            ),
          ),
          SizedBox(
            height: 60,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('바꾸기'),
            ),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await identity.setRole(OngiConfig.roleGuardian);
    // 루트가 보호자 화면으로 갈아 끼우므로 쌓여 있던 화면을 걷어낸다.
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// 큰 버튼 한 번에 0.1씩 — 드래그가 어려운 손에는 슬라이더보다 버튼(§6).
  Future<void> _step(double delta) async {
    final next = double.parse((_rate + delta)
        .clamp(OngiConfig.ttsRateMin, OngiConfig.ttsRateMax)
        .toStringAsFixed(2));
    if (next == _rate) return;
    setState(() => _rate = next);
    await _apply(next);
  }

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyLarge;
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: SafeArea(
        // 항목이 늘어 작은 화면에서 넘칠 수 있다 — 설정은 탐색 화면이 아니라
        // 세로 스크롤을 허용(불가피한 경우 CF3 예외).
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('말 빠르기', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('온기가 말해 주는 속도를 바꿀 수 있어요.', style: body),
              const SizedBox(height: 24),
              // §6 터치 타깃 60dp — 기본 Slider(48dp)로는 미달이라 확대.
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 12,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 18),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 32),
                ),
                child: SizedBox(
                  height: 64,
                  child: Slider(
                    value: _rate,
                    min: OngiConfig.ttsRateMin,
                    max: OngiConfig.ttsRateMax,
                    divisions: 14,
                    onChanged: (value) => setState(() => _rate = value),
                    onChangeEnd: _apply,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: OutlinedButton.icon(
                        onPressed: () => _step(-0.1),
                        icon: const Icon(Icons.remove, size: 28),
                        label: const Text('천천히'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 64,
                      child: OutlinedButton.icon(
                        onPressed: () => _step(0.1),
                        icon: const Icon(Icons.add, size: 28),
                        label: const Text('빠르게'),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              SizedBox(
                height: 72,
                child: FilledButton.icon(
                  onPressed: widget.voice.previewSpeechRate,
                  icon: const Icon(Icons.volume_up, size: 32),
                  label: const Text('들어보기'),
                ),
              ),
              const SizedBox(height: 40),
              Text('보호자', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('어려울 때 도와주실 분을 미리 정해 두세요.', style: body),
              const SizedBox(height: 12),
              SizedBox(
                height: 64,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          GuardianSetupScreen(
                        guardians: widget.guardians,
                        signaling: widget.signaling,
                        identity: widget.identity,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.people_alt, size: 32),
                  label: const Text('보호자 정하기'),
                ),
              ),
              if (widget.identity != null) ...[
                const SizedBox(height: 32),
                Text('이 휴대폰 역할',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  '지금은 이 휴대폰을 직접 쓰는 분으로 되어 있어요.\n'
                  '가족을 도와주는 쪽으로 바꾸면 인공지능 파일을 쓰지 않아요.',
                  style: body,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 64,
                  child: OutlinedButton.icon(
                    onPressed: _switchToGuardian,
                    icon: const Icon(Icons.swap_horiz, size: 32),
                    label: const Text('도와주는 쪽으로 바꾸기'),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              Text('앱 정리', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text('한 달 넘게 안 쓴 앱을 찾아 지우는 걸 도와드려요.', style: body),
              const SizedBox(height: 16),
              SizedBox(
                height: 72,
                child: FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => CleanerScreen(
                        apps: widget.apps,
                        usage: widget.usage,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.cleaning_services_outlined, size: 32),
                  label: const Text('안 쓰는 앱 정리'),
                ),
              ),
              const SizedBox(height: 40),
              Text('인공지능', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                widget.llm.available
                    ? '인공지능이 켜져 있어요.'
                    : '지금은 인공지능 없이 기본 기능으로 동작하고 있어요.',
                style: body,
              ),
              if (!widget.llm.available) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: 72,
                  child: FilledButton.tonalIcon(
                    onPressed: _retryAi,
                    icon: const Icon(Icons.autorenew, size: 32),
                    label: const Text('인공지능 다시 켜보기'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
