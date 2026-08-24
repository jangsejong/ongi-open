import 'package:flutter/material.dart';

import '../../core/config.dart';
import 'device_identity.dart';

/// 설치 직후 역할 선택(50_guardian_coaching.md §9 · ADR-20).
///
/// 온기는 앱 하나에 두 모드를 둔다. 별도 보호자 앱을 내지 않는 이유는 repo·SBOM·
/// 배포를 하나로 유지해 팀 2명의 부담을 줄이고, 어르신이 나중에 보호자가 되는
/// 전환도 자연스럽기 때문이다.
///
/// **보호자 모드는 2.6GB 모델을 받지 않는다** — 온보딩 분기의 핵심.
class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key, required this.identity, required this.onChosen});

  final DeviceIdentity identity;
  final void Function(String role) onChosen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text('온기를 누가 쓰시나요?', style: text.headlineSmall),
              const SizedBox(height: 16),
              Text(
                '나중에 설정에서 바꿀 수 있어요.',
                style: text.bodyLarge,
              ),
              const Spacer(),
              SizedBox(
                height: 96,
                child: FilledButton(
                  onPressed: () => onChosen(OngiConfig.roleElder),
                  child: Text('제가 쓸 거예요', style: text.titleLarge),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 96,
                child: FilledButton.tonal(
                  onPressed: () => onChosen(OngiConfig.roleGuardian),
                  child: Text('가족을 도와줄 거예요', style: text.titleLarge),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '도와주는 쪽을 고르면 인공지능 파일(2.6GB)을 받지 않아요.',
                style: text.bodySmall,
                textAlign: TextAlign.center,
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
