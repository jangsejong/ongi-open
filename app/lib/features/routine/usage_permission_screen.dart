import 'package:flutter/material.dart';

import 'usage_repository.dart';

/// 사용통계 권한 요청 전 전체화면 고지(§5 prominent disclosure — 미비가 Play 흔한
/// 위반 사례). 설정 토글에서 돌아오면 허용 여부를 감지해 결과와 함께 닫힌다.
class UsagePermissionScreen extends StatefulWidget {
  const UsagePermissionScreen({super.key, required this.usage});

  final UsageRepository usage;

  @override
  State<UsagePermissionScreen> createState() => _UsagePermissionScreenState();
}

class _UsagePermissionScreenState extends State<UsagePermissionScreen>
    with WidgetsBindingObserver {
  bool _wentToSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_wentToSettings) return;
    _wentToSettings = false;
    widget.usage.isGranted().then((granted) {
      if (mounted && granted) Navigator.of(context).pop(true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyLarge;
    return Scaffold(
      appBar: AppBar(title: const Text('맞춤 도움 켜기')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('온기가 더 잘 도와드리려면',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 24),
              Text(
                '어떤 앱을 얼마나 쓰시는지\n이 휴대폰 안에서만 살펴봐요.\n밖으로는 절대 보내지 않아요.',
                style: body?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              Text('허용하시면 이런 걸 해드려요:', style: body),
              Text('• 자주 쓰는 시간에 앱을 미리 추천', style: body),
              Text('• 오래 안 쓴 앱 정리 안내', style: body),
              const Spacer(),
              Text(
                '다음 화면에서 "온기"를 찾아 허용해 주세요.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 64,
                child: FilledButton(
                  onPressed: () async {
                    _wentToSettings = true;
                    await widget.usage.openSettings();
                  },
                  child: const Text('허용하러 가기'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 64,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('나중에 할게요'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
