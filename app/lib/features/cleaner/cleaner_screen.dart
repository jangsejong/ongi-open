import 'package:flutter/material.dart';

import '../../native/ongi_native.g.dart';
import '../apps/app_repository.dart';
import '../routine/usage_permission_screen.dart';
import '../routine/usage_repository.dart';

/// 미사용 앱 정리 안내(§3 ④) — 삭제는 항상 시스템 확인 다이얼로그 경유.
class CleanerScreen extends StatefulWidget {
  const CleanerScreen({
    super.key,
    required this.apps,
    required this.usage,
    this.intents,
  });

  final AppRepository apps;
  final UsageRepository usage;
  final IntentActionsApi? intents;

  @override
  State<CleanerScreen> createState() => _CleanerScreenState();
}

class _CleanerScreenState extends State<CleanerScreen>
    with WidgetsBindingObserver {
  late final IntentActionsApi _intents = widget.intents ?? IntentActionsApi();
  static const _unusedDays = 30;

  bool? _granted;
  List<(AppEntry, int?)> _unused = []; // (앱, 마지막 사용 ms — null=기록 없음)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 시스템 삭제 화면에서 복귀 — 이미 지운 앱이 목록에 남아 재탭되는 것 방지.
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final granted = await widget.usage.isGranted();
    if (!granted) {
      if (mounted) setState(() => _granted = false);
      return;
    }
    try {
      // 삭제 직후 복귀 경로 — 제거된 앱을 apps 캐시에서도 걷어낸다.
      await widget.apps.syncInstalledApps();
    } catch (_) {}
    await widget.usage.sync();
    final lastUsed = await widget.usage.lastUsedByPackage();
    final installed = await widget.apps.installTimesByPackage();
    final all = await widget.apps.allApps();
    final threshold = DateTime.now().millisecondsSinceEpoch -
        _unusedDays * Duration.millisecondsPerDay;
    // 기산점 = max(마지막 사용, 설치일) — 설치한 지 30일이 안 된 앱은 사용
    // 기록이 없어도 "오래 안 쓴 앱"이 아니다(§3 ④).
    int baseline(AppEntry app) {
      final used = lastUsed[app.packageName] ?? 0;
      final install = installed[app.packageName] ?? 0;
      return used > install ? used : install;
    }

    final unused = <(AppEntry, int?)>[
      for (final app in all)
        if (baseline(app) < threshold) (app, lastUsed[app.packageName]),
    ]..sort((a, b) => (a.$2 ?? 0).compareTo(b.$2 ?? 0));
    if (mounted) {
      setState(() {
        _granted = true;
        _unused = unused;
      });
    }
  }

  Future<void> _askPermission() async {
    final granted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => UsagePermissionScreen(usage: widget.usage),
      ),
    );
    if (granted == true) await _load();
  }

  Future<void> _confirmUninstall(AppEntry app) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${app.label} 정리'),
        content: const Text('삭제 화면으로 이동해요.\n삭제할지는 다음 화면에서 다시 물어봐요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('이동'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _intents.requestUninstall(app.packageName);
    } catch (_) {}
  }

  String _lastUsedText(int? ms) {
    if (ms == null || ms == 0) return '최근 $_unusedDays일 사용 기록 없음';
    final days = (DateTime.now().millisecondsSinceEpoch - ms) ~/
        Duration.millisecondsPerDay;
    return '마지막 사용: $days일 전';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('안 쓰는 앱 정리')),
      // edge-to-edge(Android 15+)에서 하단 버튼·마지막 행이 내비 바에 안 가리게.
      body: SafeArea(
        top: false,
        child: switch (_granted) {
          null => const Center(child: CircularProgressIndicator()),
          false => _permissionInvite(context),
          true => _list(context),
        },
      ),
    );
  }

  Widget _permissionInvite(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Text(
            '어떤 앱을 오래 안 쓰셨는지 알아야\n정리를 도와드릴 수 있어요.',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          SizedBox(
            height: 64,
            child: FilledButton(
              onPressed: _askPermission,
              child: const Text('시작하기'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    if (_unused.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '오래 안 쓴 앱이 없어요.\n깨끗하게 쓰고 계세요!',
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _unused.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final (app, lastUsed) = _unused[index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              FutureBuilder(
                future: widget.apps.icon(app.packageName),
                builder: (context, snapshot) => snapshot.data == null
                    ? const Icon(Icons.android, size: 48)
                    : Image.memory(snapshot.data!, width: 48, height: 48),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(app.label,
                        style: Theme.of(context).textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(_lastUsedText(lastUsed),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 56,
                child: OutlinedButton(
                  onPressed: () => _confirmUninstall(app),
                  child: const Text('정리'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
