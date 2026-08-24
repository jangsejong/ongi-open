import 'dart:async';

import 'package:flutter/material.dart';

import '../../native/ongi_native.g.dart';
import '../../core/config.dart';
import '../apps/app_repository.dart';
import 'coaching_controller.dart';
import 'coaching_signaling.dart';
import 'guardian_repository.dart';
import 'screen_share.dart';
import 'share_policy.dart';

/// "도와주세요" 세션 화면(50_guardian_coaching.md §4).
///
/// 어르신 동작은 최소 3탭이고, 그중 둘은 **보호자가 통화로 안내하는 상태**에서
/// 이루어진다. 어려운 단계를 사람이 도와주는 것이 이 기능의 강점이므로
/// **통화 먼저 → 화면 공유 나중** 순서를 화면 구성으로 강제한다.
class HelpScreen extends StatefulWidget {
  const HelpScreen({
    super.key,
    required this.controller,
    required this.guardians,
    required this.apps,
    required this.signaling,
    this.intents,
    this.native,
    this.usage,
  });

  final CoachingController controller;
  final GuardianRepository guardians;
  final AppRepository apps;
  final CoachingSignaling signaling;
  final IntentActionsApi? intents;
  final CoachingApi? native;

  /// 민감 화면 판정의 전제 — 이 권한이 없으면 화면 공유를 시작하지 않는다.
  final UsageStatsApi? usage;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  late final IntentActionsApi _intents = widget.intents ?? IntentActionsApi();
  late final CoachingApi _native = widget.native ?? CoachingApi();
  late final UsageStatsApi _usage = widget.usage ?? UsageStatsApi();
  late final ScreenShare _share = ScreenShare(
    signaling: widget.signaling,
    native: _native,
    onCaptureEnded: _onCaptureEnded,
  );

  StreamSubscription<SignalMessage>? _sub;
  Timer? _watch;
  Map<String, AppEntry> _appIndex = const {};
  List<Guardian> _usable = const [];
  bool _loading = true;

  /// 화면 공유 시작 절차가 도는 중 — 버튼을 잠가 중복 탭을 막는다.
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPhase);
    _sub = widget.signaling.messages.listen(_share.handle);
    _load();
  }

  Future<void> _load() async {
    final list =
        await widget.guardians.usable(DateTime.now().millisecondsSinceEpoch);
    if (!mounted) return;
    setState(() {
      _usable = list;
      _loading = false;
    });
  }

  void _onPhase() {
    if (!mounted) return;
    final phase = widget.controller.phase;
    if (phase != CoachingPhase.sharing) {
      _watch?.cancel();
      _watch = null;
      if (_share.isSharing) unawaited(_share.stop());
    }
    setState(() {});
  }

  /// OS가 캡처를 끝낸 경우 — 통화는 유지하고 공유 단계만 되돌린다.
  /// 이걸 받지 않으면 화면에는 "보고 있어요"가, 알림에는 공유 중이 계속 남는다.
  void _onCaptureEnded() {
    if (!mounted || widget.controller.phase != CoachingPhase.sharing) return;
    unawaited(_share.stop());
    widget.controller.onSharingStopped();
  }

  /// 민감 화면 감시(§6) — 감지 지연이 그대로 노출 시간이 되므로 짧게 돈다.
  ///
  /// 분류 인덱스는 공유를 시작할 때 한 번만 만든다. 700ms마다 DB를 치면 배터리와
  /// 발열이 늘고, 그 비용이 감시 주기를 늘리게 만들어 결국 노출 시간이 길어진다.
  Future<void> _startWatching() async {
    try {
      _appIndex = {
        for (final entry in await widget.apps.allApps())
          entry.packageName: entry,
      };
    } catch (_) {
      // 감시를 세우지 못하면 은행 화면을 걸러낼 수 없다. 공유를 그대로 두는 것은
      // fail-open이다 — 판정할 수 없으면 보여주지 않는다(ADR-19).
      widget.controller.setPolicyBlind(true);
      await _share.setVisible(false);
      return;
    }
    // 인덱스를 만드는 사이에 공유가 끝났으면 타이머를 아예 만들지 않는다 —
    // 만들면 _onPhase의 취소를 놓쳐 dispose까지 헛돈다.
    if (!mounted || widget.controller.phase != CoachingPhase.sharing) return;
    _watch?.cancel();
    _watch = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      if (widget.controller.phase != CoachingPhase.sharing) return;
      // 세션 중 권한이 회수되면 판정 불능이 된다 — 판정할 수 없으면 가린다.
      final granted = await _usage.isUsageAccessGranted();
      widget.controller.setPolicyBlind(!granted);
      if (!granted) {
        await _share.setVisible(false);
        return;
      }
      final pkg = await _native.foregroundPackage();
      if (pkg.isEmpty || !mounted) return;
      final entry = _appIndex[pkg];
      // 인덱스에 없는 앱(세션 중 새로 설치 등)도 패키지명만으로 금융 신호를 본다 —
      // 알 수 없다고 그대로 내보내지 않는다(default-deny).
      final policy = sharePolicyFor(
        category: entry?.category ?? LifeCategory.etc,
        packageName: pkg,
        label: entry?.label ?? '',
      );
      widget.controller.onForegroundPolicy(policy);
      await _share.setVisible(widget.controller.screenVisible);
    });
  }

  Future<void> _request(Guardian guardian) async {
    await widget.controller.requestHelp(guardian);
    // 보호자 폰에서 발신하는 것이 원칙이지만(ADR-18), 수락 전이라도 어르신이
    // 기다리는 동안 전화를 걸 수 있도록 다이얼러 경로를 남겨 둔다.
  }

  /// 민감 화면 정책은 사용정보 접근 권한 위에서만 성립한다. 권한이 없으면 어떤 앱이
  /// 앞에 있는지 알 수 없어 은행 화면도 걸러내지 못하므로, **공유를 아예 시작하지
  /// 않는다.** 막고 끝내지 않고 허용하러 가는 길을 함께 준다(CG1).
  Future<bool> _ensureUsageAccess() async {
    if (await _usage.isUsageAccessGranted()) return true;
    if (!mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('먼저 허용해 주실 것이 있어요'),
        content: Text(
          '어떤 앱을 보고 계신지 온기가 알아야\n'
          '은행 화면 같은 중요한 화면을 가려 드릴 수 있어요.\n\n'
          '허용하지 않으면 화면을 보여드릴 수 없어요.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        actions: [
          SizedBox(
            height: 60,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('나중에'),
            ),
          ),
          SizedBox(
            height: 60,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('허용하러 가기'),
            ),
          ),
        ],
      ),
    );
    if (go == true) await _usage.openUsageAccessSettings();
    return false;
  }

  Future<void> _startSharing() async {
    // 안내·동의 다이얼로그가 뜨는 수 초 동안 버튼을 잠근다. 큰 버튼을 두 번 누르는
    // 것은 시니어 오인지의 전형인데, 잠금이 첫 await 뒤에 걸리면 그 사이의 두 번째
    // 탭이 가드를 통과한다 — 사용정보 안내가 겹으로 뜨거나, 공유가 정상 시작되는
    // 순간에 두 번째 호출이 ScreenShare 가드에 막혀 "시작하지 못했어요"를 띄운다.
    if (_starting) return;
    setState(() => _starting = true);
    try {
      if (!await _ensureUsageAccess()) return;
      final sessionId = widget.controller.sessionId;
      if (sessionId == null) {
        if (mounted) _toast('연결이 아직 준비되지 않았어요.');
        return;
      }
      final ok = await _share.start(sessionId);
      if (!ok) {
        if (mounted) _toast('화면 보여주기를 시작하지 못했어요. 다시 눌러 주세요.');
        return;
      }
      // OS 동의 다이얼로그가 떠 있는 동안 세션이 끝났을 수 있다. 그대로 두면
      // onSharingStarted가 조용히 무시되면서 캡처와 상시 알림만 고아로 남는다.
      if (widget.controller.phase != CoachingPhase.talking) {
        await _share.stop();
        return;
      }
      widget.controller.onSharingStarted();
      unawaited(_startWatching());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _end() async {
    await _share.stop();
    await widget.controller.endByElder();
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: Theme.of(context).textTheme.bodyLarge),
        ),
      );

  @override
  void dispose() {
    _watch?.cancel();
    unawaited(_sub?.cancel());
    unawaited(_share.stop());
    widget.controller.removeListener(_onPhase);
    // 여기서 캡처를 멈추므로 단계도 함께 되돌린다. 안 되돌리면 다시 들어왔을 때
    // 통화만 남은 상태에서 화면은 계속 "보고 있어요"를 띄우고, 공유를 되살릴
    // 버튼(talking 단계에만 있다)에도 닿지 못한다. 리스너를 먼저 뗀 뒤 부른다.
    widget.controller.onSharingStopped();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('도와주세요')),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : switch (widget.controller.phase) {
                  CoachingPhase.idle => _pickGuardian(),
                  CoachingPhase.requested => _waiting(),
                  CoachingPhase.talking => _talking(),
                  CoachingPhase.sharing => _sharing(),
                  CoachingPhase.ended => _summary(),
                },
        ),
      ),
    );
  }

  Widget _pickGuardian() {
    final text = Theme.of(context).textTheme;
    if (_usable.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('아직 도와주실 분이 없어요', style: text.headlineSmall),
          const SizedBox(height: 16),
          Text(
            '설정에서 보호자를 먼저 등록해 주세요.\n'
            '가족이 대신 해 드려도 괜찮아요.',
            style: text.bodyLarge,
          ),
          const Spacer(),
          SizedBox(
            height: 64,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('돌아가기'),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('누구에게 물어볼까요?', style: text.headlineSmall),
        const SizedBox(height: 20),
        for (final guardian in _usable) ...[
          SizedBox(
            height: 80,
            child: FilledButton(
              onPressed: () => _request(guardian),
              child: Text(guardian.name, style: text.titleLarge),
            ),
          ),
          const SizedBox(height: 16),
        ],
        const Spacer(),
        SizedBox(
          height: 64,
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('그만두기'),
          ),
        ),
      ],
    );
  }

  Widget _waiting() {
    final text = Theme.of(context).textTheme;
    final name = widget.controller.target?.name ?? '보호자';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$name 님을 부르고 있어요', style: text.headlineSmall),
        const SizedBox(height: 24),
        Text('잠시만 기다려 주세요.\n곧 전화가 올 거예요.', style: text.bodyLarge),
        const SizedBox(height: 32),
        const Center(child: CircularProgressIndicator()),
        const Spacer(),
        SizedBox(
          height: 64,
          child: OutlinedButton(onPressed: _end, child: const Text('그만두기')),
        ),
      ],
    );
  }

  Widget _talking() {
    final text = Theme.of(context).textTheme;
    final name = widget.controller.target?.name ?? '보호자';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$name 님과 통화 중이에요', style: text.headlineSmall),
        const SizedBox(height: 20),
        Text(
          '$name 님이 화면을 보여 달라고 하면\n아래 큰 버튼을 눌러 주세요.',
          style: text.bodyLarge,
        ),
        const Spacer(),
        SizedBox(
          height: 80,
          child: FilledButton(
            onPressed: _starting ? null : _startSharing,
            child: Text(_starting ? '준비하고 있어요…' : '화면 보여주기'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: OutlinedButton(
            onPressed: () => _intents.openDialer(),
            child: const Text('전화 걸기'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: OutlinedButton(onPressed: _end, child: const Text('끝내기')),
        ),
      ],
    );
  }

  Widget _sharing() {
    final text = Theme.of(context).textTheme;
    final policy = widget.controller.screenPolicy;
    final visible = widget.controller.screenVisible;
    final name = widget.controller.target?.name ?? '보호자';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          visible ? '$name 님이 화면을 보고 있어요' : '지금은 화면이 가려져 있어요',
          style: text.headlineSmall,
        ),
        const SizedBox(height: 16),
        // 상시 경고 — 비밀번호·인증번호는 보호자에게도 보여주지 않는다(§6).
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '비밀번호와 인증번호는\n보호자에게도 보여주지 마세요.',
            style: text.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onErrorContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (policy != SharePolicy.allowed) ...[
          const SizedBox(height: 20),
          Text(policy.reason, style: text.titleLarge),
          const SizedBox(height: 8),
          Text(policy.guidance, style: text.bodyLarge),
          // 송금·결제(blocked)에는 재동의 버튼 자체가 없다 — ADR-19.
          if (policy == SharePolicy.reconsent && !visible) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 64,
              child: OutlinedButton(
                onPressed: () async {
                  widget.controller.reconsentCurrentScreen();
                  await _share.setVisible(widget.controller.screenVisible);
                },
                child: const Text('이 화면은 보여드릴게요'),
              ),
            ),
          ],
        ],
        const Spacer(),
        SizedBox(
          height: 72,
          child: OutlinedButton(
            onPressed: () async {
              // 세션은 그대로 두고 프레임만 멈춘다 — 끊었다 다시 켜면 OS 동의를
              // 처음부터 다시 받아야 해서 어르신에게 부담이 크다.
              widget.controller.setHidden(!widget.controller.hiddenByElder);
              await _share.setVisible(widget.controller.screenVisible);
            },
            child: Text(widget.controller.hiddenByElder ? '다시 보여주기' : '가리기'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 72,
          child: FilledButton(onPressed: _end, child: const Text('끝내기')),
        ),
      ],
    );
  }

  Widget _summary() {
    final text = Theme.of(context).textTheme;
    final reason = widget.controller.endReason?.label ?? '끝났어요';
    final shared = widget.controller.sharedThisSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('도움이 끝났어요', style: text.headlineSmall),
        const SizedBox(height: 20),
        Text(reason, style: text.bodyLarge),
        const SizedBox(height: 12),
        Text(
          shared ? '통화하고 화면도 보여드렸어요.' : '통화만 했어요.',
          style: text.bodyLarge,
        ),
        const SizedBox(height: 12),
        Text('지금은 아무도 화면을 볼 수 없어요.', style: text.bodyLarge),
        const Spacer(),
        SizedBox(
          height: 72,
          child: FilledButton(
            onPressed: () {
              widget.controller.dismissSummary();
              Navigator.of(context).pop();
            },
            child: const Text('확인'),
          ),
        ),
      ],
    );
  }
}
