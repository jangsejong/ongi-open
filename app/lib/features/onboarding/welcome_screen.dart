import 'package:flutter/material.dart';

/// 첫 실행 환영 화면(기획설계서 §8 [1]) — 보호자가 대신 설정하는 경우를 전제로
/// 문구를 쓴다. 글씨·말 빠르기 상세 설정은 M2(음성)와 함께 추가 예정.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyLarge;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Text(
                '온기',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontSize: 56,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
              ),
              const SizedBox(height: 16),
              Text(
                '스마트폰을 쉽게 쓰도록\n온기가 도와드릴게요.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 32),
              Text('• 앱을 생활 카테고리로 정리해 드려요', style: body),
              Text('• 큰 글씨로 보여드려요', style: body),
              Text('• 모든 정보는 이 휴대폰 안에만 있어요', style: body),
              const Spacer(),
              Text(
                '가족이 대신 설정해 주셔도 좋아요.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 72,
                child: FilledButton(
                  onPressed: onStart,
                  child: const Text('시작하기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
