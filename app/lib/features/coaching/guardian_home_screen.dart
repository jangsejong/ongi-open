import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/config.dart';
import '../../native/ongi_native.g.dart';
import 'coaching_tasks.dart';
import 'device_identity.dart';
import 'guardian_controller.dart';
import 'relay_field.dart';

/// 보호자 모드 홈(50_guardian_coaching.md §9 · ADR-20).
///
/// 이 화면은 어르신용이 아니므로 시니어 제약(22sp·60dp·7:1)을 따르지 않는다.
/// 대신 통화 중에 한 손으로 볼 것을 전제로 정보 밀도를 높인다.
///
/// 보호자가 할 수 있는 것은 **보는 것과 말하는 것**뿐이다. 어르신 화면을 조작하는
/// 버튼은 이 화면에 없으며, 그것이 이 기능의 정의다(ADR-16).
class GuardianHomeScreen extends StatefulWidget {
  const GuardianHomeScreen({
    super.key,
    required this.controller,
    required this.identity,
    this.intents,
  });

  final GuardianController controller;
  final DeviceIdentity identity;
  final IntentActionsApi? intents;

  @override
  State<GuardianHomeScreen> createState() => _GuardianHomeScreenState();
}

class _GuardianHomeScreenState extends State<GuardianHomeScreen> {
  late final IntentActionsApi _intents = widget.intents ?? IntentActionsApi();
  CoachingTask? _task;

  /// 다이얼로그가 떠 있는 동안 notifyListeners가 또 오면 팝업이 겹친다.
  bool _pairDialogOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  void _onChange() {
    if (!mounted) return;
    final pair = widget.controller.pendingPair;
    if (pair != null && !_pairDialogOpen) unawaited(_askPair(pair));
    setState(() {});
  }

  Future<void> _askPair(PairRequest pair) async {
    _pairDialogOpen = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('등록 요청'),
        content: Text(
          '${pair.elderName} 님이 회원님을 보호자로 등록하려고 합니다.\n'
          '지금 옆에 계시거나 통화 중인지 확인하고 수락하세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('거절'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('수락'),
          ),
        ],
      ),
    );
    _pairDialogOpen = false;
    // 화면에 띄웠던 그 요청에만 응답한다 — 창이 떠 있는 사이 다른 어르신의 요청이
    // 들어와도 수락 대상이 바뀌지 않는다.
    if (ok == true) {
      await widget.controller.acceptPair(pair);
    } else {
      await widget.controller.declinePair(pair);
    }
    // 그 사이 밀려 들어온 요청은 따로 다시 묻는다(조용히 버리지 않는다).
    final next = widget.controller.pendingPair;
    if (mounted && next != null) unawaited(_askPair(next));
  }

  Future<void> _switchToElder() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이 휴대폰을 직접 쓰시나요?'),
        content: const Text(
          '어르신용 화면으로 바뀝니다. 인공지능 파일(2.6GB)을 받게 됩니다.\n'
          '설정에서 다시 되돌릴 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('그만두기'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('바꾸기'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await widget.identity.setRole(OngiConfig.roleElder);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('온기 보호자'),
        actions: [
          // 역할을 되돌리는 유일한 경로. 없으면 잘못 고른 어르신이 이 화면에
          // 갇혀 런처도 모델도 쓰지 못한다.
          if (widget.controller.phase == GuardianPhase.idle)
            TextButton(
              onPressed: _switchToElder,
              child: const Text('내가 쓸래요'),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: switch (widget.controller.phase) {
          GuardianPhase.idle => _waiting(),
          GuardianPhase.incoming => _incoming(),
          GuardianPhase.connected => _session(),
        },
      ),
    );
  }

  Widget _waiting() {
    final code = DeviceIdentity.pairingCodeOf(widget.identity.deviceKey);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '어르신이 "도와주세요"를 누르면 여기로 연결됩니다.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Text('내 등록 코드', style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 8),
                  SelectableText(
                    code,
                    style: const TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '어르신 휴대폰의 설정 → 보호자 정하기에서\n이 코드를 입력하면 등록됩니다.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 보호자 기기는 이 화면에서 다른 곳으로 갈 수 없다 — 여기에 주소 입력이
          // 없으면 넣을 방법 자체가 없어 요청을 영영 받지 못한다(코드에 기본 주소가
          // 없으므로). 어르신 쪽 보호자 등록 화면과 같은 위젯이다.
          RelayField(identity: widget.identity, dense: true),
          if (widget.identity.relayUrl.isEmpty)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '연결 서버가 설정되지 않아 요청을 받을 수 없습니다.\n'
                  '위 "연결 서버 설정"에 주소를 넣어 주세요.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            '코칭할 수 있는 것',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final task in coachingTasks)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.check_circle_outline, size: 20),
                    title: Text(task.title),
                  ),
                const SizedBox(height: 12),
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      coachingExcluded,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _incoming() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.support_agent, size: 72),
          const SizedBox(height: 16),
          const Text(
            '어르신이 도움을 요청했습니다',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 40),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: () async {
                await widget.controller.accept();
                // 통화는 보호자가 건다 — 어르신은 받기만 하면 된다(ADR-18).
                await _intents.openDialer();
              },
              icon: const Icon(Icons.call),
              label: const Text('받고 전화 걸기'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: OutlinedButton(
              onPressed: widget.controller.decline,
              child: const Text('지금은 어려워요'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _session() {
    return Column(
      children: [
        // 어르신 화면 — 보기 전용. 이 위젯에는 터치 전달 경로가 없다.
        Expanded(
          flex: 3,
          child: Container(
            color: Colors.black,
            width: double.infinity,
            child: widget.controller.receiving
                ? RTCVideoView(
                    widget.controller.renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  )
                : const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '어르신이 "화면 보여주기"를 누르면 여기에 보입니다.\n'
                        '통화로 안내해 주세요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 15),
                      ),
                    ),
                  ),
          ),
        ),
        Expanded(
          flex: 2,
          child: _taskPanel(),
        ),
      ],
    );
  }

  Widget _taskPanel() {
    final task = _task;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: task == null
          ? ListView(
              children: [
                const Text(
                  '무엇을 도와드릴까요?',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                for (final t in coachingTasks)
                  ListTile(
                    dense: true,
                    title: Text(t.title),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _task = t),
                  ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: () => widget.controller.hangUp(),
                    child: const Text('끝내기'),
                  ),
                ),
              ],
            )
          : ListView(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => setState(() => _task = null),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Expanded(
                      child: Text(
                        task.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                for (var i = 0; i < task.steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text('${i + 1}. ${task.steps[i]}',
                        style: const TextStyle(fontSize: 15)),
                  ),
                if (task.pitfall.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '⚠ ${task.pitfall}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
