import 'dart:async';

import 'package:flutter/material.dart';

import '../../native/ongi_native.g.dart';
import 'coaching_signaling.dart';
import 'device_identity.dart';
import 'elder_auth.dart';
import 'guardian_repository.dart';
import 'relay_field.dart';

/// 보호자 등록·관리(50_guardian_coaching.md §3 사전 A / A′).
///
/// **연락처를 미리 특정**하고, 목록을 바꾸려면 어르신 본인 확인을 통과해야 한다.
/// 이 게이트가 사칭 피싱범이 이 기능을 발판으로 삼는 경로를 닫는다(ADR-21).
/// 최초 등록은 보호자가 대신 진행하는 것을 전제로 문구를 쓰되, 확인 화면은
/// 어르신이 보는 것을 상정해 큰글씨로 "누구를" 등록하는지 명시한다.
class GuardianSetupScreen extends StatefulWidget {
  const GuardianSetupScreen({
    super.key,
    required this.guardians,
    this.signaling,
    this.auth,
    this.intents,
    this.stats,
    this.identity,
  });

  final GuardianRepository guardians;

  /// 페어링(사전 A 키 교환)에 쓴다. 없으면 등록만 되고 연결은 되지 않는다.
  final CoachingSignaling? signaling;
  final ElderAuth? auth;
  final IntentActionsApi? intents;

  /// 알림 권한 조회·요청. 화면 공유 중 상시 알림이 이 권한 위에 선다.
  final DeviceStatsApi? stats;

  /// 릴레이 주소를 읽고 바꾼다. 없으면 주소 입력란을 감춘다.
  final DeviceIdentity? identity;

  @override
  State<GuardianSetupScreen> createState() => _GuardianSetupScreenState();
}

class _GuardianSetupScreenState extends State<GuardianSetupScreen>
    with WidgetsBindingObserver {
  late final ElderAuth _auth = widget.auth ?? ElderAuth();
  late final IntentActionsApi _intents = widget.intents ?? IntentActionsApi();
  late final DeviceStatsApi _stats = widget.stats ?? DeviceStatsApi();

  List<Guardian> _list = const [];
  List<AssistSession> _history = const [];
  bool _loading = true;

  /// 알림 권한이 없는 상태 — 화면 공유 중 상시 알림이 뜨지 않는다.
  bool _noticeOff = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 권한 요청과 설정 화면은 **결과를 돌려주지 않는다**(요청은 void, 설정은 딴 앱).
  /// 돌아왔을 때 다시 읽는 것이 상태를 맞추는 유일한 방법이다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshNotice());
  }

  Future<void> _reload() async {
    final list = await widget.guardians.all();
    final history = await widget.guardians.history(limit: 20);
    if (!mounted) return;
    setState(() {
      _list = list;
      _history = history;
      _loading = false;
    });
    // 목록 표시를 권한 조회에 묶지 않는다 — 네이티브 왕복이 늦어지면 보호자
    // 목록까지 함께 늦어진다. 결과가 오면 경고 카드만 뒤늦게 붙으면 된다.
    unawaited(_refreshNotice());
  }

  Future<void> _refreshNotice() async {
    bool granted;
    try {
      granted = await _stats.isPostNotificationsGranted();
    } catch (_) {
      // 판정할 수 없으면 경고를 띄우지 않는다 — 근거 없는 불안을 주지 않는다.
      granted = true;
    }
    if (!mounted || _noticeOff == !granted) return;
    setState(() => _noticeOff = !granted);
  }

  /// 사전 A′ — 목록을 바꾸는 모든 경로가 이 게이트를 지난다.
  Future<bool> _confirmOwner(String what) async {
    final result = await _auth.confirm(what);
    if (!mounted) return false;
    switch (result) {
      case ElderAuthResult.ok:
        return true;
      case ElderAuthResult.failed:
        _toast('확인하지 못했어요. 다시 해 주세요.');
        return false;
      case ElderAuthResult.noLockSet:
        await _showLockGuidance();
        return false;
    }
  }

  /// 잠금 미설정은 막다른 길이 아니라 다음 행동을 준다(CG1).
  Future<void> _showLockGuidance() async {
    final body = Theme.of(context).textTheme.bodyLarge;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('먼저 휴대폰 잠금을 설정해 주세요'),
        content: Text(
          '보호자를 바꾸려면 본인이 맞는지 확인해야 해요.\n'
          '지문이나 비밀번호를 먼저 설정해 주세요.',
          style: body,
        ),
        actions: [
          SizedBox(
            height: 60,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('나중에'),
            ),
          ),
          SizedBox(
            height: 60,
            child: FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                _intents.openSecuritySettings();
              },
              child: const Text('설정하러 가기'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final entered = await _promptGuardian(askCode: true);
    if (entered == null || !mounted) return;
    if (!await _confirmOwner('보호자를 등록하려고 해요')) return;

    final guardian = await widget.guardians.add(
      name: entered.name,
      phone: entered.phone,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _reload();
    if (!mounted) return;

    // 사전 A 키 교환 — 신뢰 앵커는 전화번호가 아니라 이 키다(ADR-21).
    // 코드를 입력하지 않았으면 목록에만 남고 세션 대상이 되지 않는다.
    if (entered.code.isEmpty) {
      _toast('등록했어요. 보호자 코드를 넣어야 연결돼요.');
      return;
    }
    await _pair(guardian, entered.code);
  }

  /// 보호자 앱이 보여 주는 6자리 코드로 키를 교환한다.
  ///
  /// 사전 B(관계 증빙 + 관리자 승인)의 운영 콘솔은 아직 없다. 지금은 **보호자 본인이
  /// 자기 기기에서 수락하는 것**이 그 자리를 대신하며, 이 절충은 50_ §14의 미결
  /// "사전 B 유지 여부 재평가"와 함께 다룬다.
  Future<void> _pair(Guardian guardian, String code) async {
    final signaling = widget.signaling;
    if (signaling == null) {
      _toast('지금은 연결할 수 없어요.');
      return;
    }
    // pair_ok의 guardianDeviceKey는 서버가 보낸 쪽 키로 덮어써 주지만, 그것만으로는
    // "**내가 입력한 코드의 주인**"이라는 보장이 안 된다. 어르신 키를 아는 아무 피어나
    // pair_ok를 쏘면 그 키가 그대로 신뢰 앵커로 저장되기 때문이다. 코드는 키 앞 6자의
    // 결정적 파생이므로 기기가 직접 대조한다 — 서버를 신뢰하지 않는 설계(ADR-21)를
    // 페어링 경로에서도 지킨다.
    final wanted = code.trim().toUpperCase();
    final done = Completer<String?>();
    late final StreamSubscription<SignalMessage> sub;
    sub = signaling.messages.listen((message) {
      if (done.isCompleted) return;
      if (message.type == 'pair_ok') {
        final key = message.data['guardianDeviceKey'] as String? ?? '';
        // 어긋난 응답은 버리고 계속 기다린다. 완료시켜 버리면 먼저 도착한 위조
        // 응답이 진짜 보호자의 수락을 밀어낸다.
        if (DeviceIdentity.pairingCodeOf(key) != wanted) return;
        done.complete(key);
      } else if (message.type == 'pair_no') {
        done.complete(null);
      }
    });

    _toast('${guardian.name} 님 휴대폰에서 수락해 주세요.');
    try {
      await signaling.send(SignalMessage('pair_request', {
        'code': code,
        'elderName': '어르신',
      }));
    } catch (_) {
      await sub.cancel();
      if (mounted) _toast('연결하지 못했어요. 잠시 뒤 다시 해 주세요.');
      return;
    }

    String? resolved;
    try {
      resolved = await done.future.timeout(const Duration(seconds: 60));
    } catch (_) {
      resolved = null;
    }
    await sub.cancel();

    if (resolved == null || resolved.isEmpty) {
      if (mounted) _toast('연결하지 못했어요. 코드를 다시 확인해 주세요.');
      return;
    }

    await widget.guardians.update(
      guardian.copyWith(deviceKey: resolved, approved: true),
    );
    await _reload();
    if (mounted) _toast('연결됐어요. 이제 도움을 요청할 수 있어요.');
    await _askNotice();
  }

  /// 코칭이 실제로 가능해진 **직후**에 한 번만 알림 권한을 묻는다.
  ///
  /// 이 자리를 고른 이유가 있다. 상시 알림은 화면 공유 중 "지금 보이고 있다"를
  /// 알리는 유일한 수단이고, 시스템 UI로 캡처가 멈췄을 때 어르신이 돌아오는
  /// 경로이기도 하다(50_ §7 가시성). 그런데 Android는 **2회 거부하면 앱에서 다시
  /// 물을 수 없으므로** 기회가 사실상 한두 번뿐이다. 역할 선택처럼 맥락 없는
  /// 자리에서 먼저 태우면, 정작 필요한 순간에는 물을 수조차 없다.
  /// 여기는 최초 등록을 대신 해 주는 가족이 폰을 들고 있는 시점이고(이 화면의
  /// 설계 전제), 보호자를 연결하지 않은 사람은 지나가지도 않는다.
  Future<void> _askNotice() async {
    await _refreshNotice();
    if (!mounted || !_noticeOff) return;
    // 시스템 팝업을 맨몸으로 띄우지 않는다 — 무엇에 쓰는지 큰글씨로 먼저 말한다.
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('알림을 켜 주세요'),
        content: Text(
          '화면을 보여드리는 동안\n'
          '"지금 보여드리고 있어요" 알림이 떠 있어요.\n\n'
          '그 알림을 눌러야 온기로 돌아올 수 있어요.',
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
              child: const Text('알림 켜기'),
            ),
          ),
        ],
      ),
    );
    if (go != true) return;
    // 팝업이 뜰 수 없는 상태(영구 거부·Android 12 이하의 앱 단위 차단·채널 차단)
    // 에서 요청만 던지면 아무 일도 일어나지 않는다 — "알림 켜기"를 눌렀는데
    // 무반응인 막다른 탭이 된다(CG1). 그때는 설정 화면이 유일한 길이다.
    var canAsk = false;
    try {
      canAsk = await _stats.canRequestPostNotifications();
    } catch (_) {}
    try {
      if (canAsk) {
        await _stats.requestPostNotifications();
      } else {
        await _intents.openNotificationSettings();
      }
    } catch (_) {}
    // 결과는 오지 않는다 — 사용자가 시스템 팝업(또는 설정)을 닫고 돌아오면
    // didChangeAppLifecycleState가 다시 읽는다.
  }

  Future<void> _edit(Guardian guardian) async {
    final entered = await _promptGuardian(initial: guardian);
    if (entered == null || !mounted) return;
    if (!await _confirmOwner('${guardian.name} 님의 연락처를 바꾸려고 해요')) return;

    await widget.guardians.update(
      guardian.copyWith(name: entered.name, phone: entered.phone),
    );
    await _reload();
    // 보호자에게 알리는 경로는 없다 — 있다고 말하지 않는다.
    if (mounted) _toast('바꿨어요.');
  }

  Future<void> _remove(Guardian guardian) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${guardian.name} 님을 지울까요?'),
        content: Text(
          '앞으로 이분에게는 도움을 요청할 수 없어요.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        actions: [
          // 취소가 기본 위치(좌부정) — 실수로 지우는 것을 막는다(CG2·3-3 관습).
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
              child: const Text('지우기'),
            ),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    if (!await _confirmOwner('${guardian.name} 님을 지우려고 해요')) return;

    await widget.guardians.remove(guardian.id);
    await _reload();
  }

  Future<({String name, String phone, String code})?> _promptGuardian({
    Guardian? initial,
    bool askCode = false,
  }) async {
    final nameCtl = TextEditingController(text: initial?.name ?? '');
    final phoneCtl = TextEditingController(text: initial?.phone ?? '');
    final body = Theme.of(context).textTheme.bodyLarge;

    final codeCtl = TextEditingController();
    return showDialog<({String name, String phone, String code})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(initial == null ? '보호자 등록' : '보호자 정보 바꾸기'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              style: body,
              decoration: const InputDecoration(labelText: '부르는 이름 (예: 큰딸)'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: phoneCtl,
              style: body,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: '전화번호'),
            ),
            if (askCode) ...[
              const SizedBox(height: 16),
              TextField(
                controller: codeCtl,
                style: body,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: '보호자 코드 6자리',
                  helperText: '보호자 휴대폰의 온기 첫 화면에 있어요',
                ),
              ),
            ],
          ],
        ),
        actions: [
          SizedBox(
            height: 60,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('그만두기'),
            ),
          ),
          SizedBox(
            height: 60,
            child: FilledButton(
              onPressed: () {
                final name = nameCtl.text.trim();
                final phone = phoneCtl.text.trim();
                if (name.isEmpty || phone.isEmpty) return;
                Navigator.of(context).pop((
                  name: name,
                  phone: phone,
                  code: codeCtl.text.trim(),
                ));
              },
              child: const Text('저장'),
            ),
          ),
        ],
      ),
    );
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: Theme.of(context).textTheme.bodyLarge),
          duration: const Duration(seconds: 4),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('보호자')),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    '어려울 때 도와주실 분을 미리 정해 두세요.\n'
                    '여기 없는 사람에게는 연결되지 않아요.',
                    style: text.bodyLarge,
                  ),
                  const SizedBox(height: 20),
                  if (_noticeOff && _list.any((g) => g.isBound)) _noticeCard(),
                  if (widget.identity != null) RelayField(identity: widget.identity!),
                  for (final guardian in _list) _guardianTile(guardian),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 64,
                    child: OutlinedButton(
                      onPressed: _add,
                      child: const Text('보호자 추가하기'),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Text('도움받은 기록', style: text.titleLarge),
                  const SizedBox(height: 8),
                  if (_history.isEmpty)
                    Text('아직 없어요.', style: text.bodyLarge)
                  else
                    for (final session in _history) _historyTile(session),
                ],
              ),
      ),
    );
  }

  /// 이미 등록을 마친 어르신은 [_askNotice]를 지나가지 않는다 — 그 사람들에게
  /// 상태와 다음 행동을 주는 자리다. **버튼은 설정으로 보낸다.** 2회 거부한 뒤에는
  /// 앱에서 다시 물어도 아무 일이 없어, 요청 버튼은 막다른 길이 된다(CG1).
  Widget _noticeCard() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '알림이 꺼져 있어요',
              style: text.titleLarge?.copyWith(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '화면을 보여드리는 동안 "지금 보여드리고 있어요"\n'
              '알림이 뜨지 않아요. 그 알림이 온기로 돌아오는 길이에요.',
              style: text.bodyLarge?.copyWith(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 60,
              child: FilledButton(
                onPressed: () => _intents.openNotificationSettings(),
                child: const Text('설정에서 켜기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _guardianTile(Guardian guardian) {
    final text = Theme.of(context).textTheme;
    final status = !guardian.approved
        ? '승인을 기다리는 중이에요'
        : guardian.isBound
            ? '연결 준비가 끝났어요'
            : '보호자 휴대폰에서 온기를 한 번 열어야 해요';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(guardian.name, style: text.titleLarge),
            const SizedBox(height: 4),
            Text(guardian.phone, style: text.bodyLarge),
            const SizedBox(height: 4),
            Text(status, style: text.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 60,
                    child: OutlinedButton(
                      onPressed: () => _edit(guardian),
                      child: const Text('바꾸기'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 60,
                    child: OutlinedButton(
                      onPressed: () => _remove(guardian),
                      child: const Text('지우기'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyTile(AssistSession session) {
    final started = DateTime.fromMillisecondsSinceEpoch(session.startedMs);
    final minutes = session.duration.inMinutes;
    final what = session.shared ? '통화하고 화면도 보여드렸어요' : '통화만 했어요';
    final sensitive = session.sensitiveSeen ? ' (중요한 화면 포함)' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        '${started.month}월 ${started.day}일 · ${session.guardianName} · '
        '$minutes분\n$what$sensitive',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
  }
}
