import 'package:flutter/material.dart';

import '../../ai/intent_router.dart';
import 'voice_controller.dart';

/// 푸시투토크 음성 화면(§6) — 열리면 바로 듣기 시작, 큰 자막·큰 버튼.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.controller});

  final VoiceController controller;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  VoiceController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // reset()이 동기 notifyListeners()를 부른다 — 리스너를 그 뒤에 등록해
    // 트리 빌드(라우트 push 프레임) 중 markNeedsBuild가 걸리지 않게 한다.
    controller.reset();
    controller.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // TalkBack 등 사용 중이면 자체 TTS 억제(§6 이중 발화 충돌 방지).
      controller.suppressTts = MediaQuery.of(context).accessibleNavigation;
      controller.startListening();
    });
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    // 진행 중 청취·라우팅·TTS 전부 무효화 — 화면 이탈 후 유령 발화 방지.
    controller.cancelSession();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _execute(VoiceAction action) async {
    final ok = await controller.execute(action);
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('말로 하기')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (controller.phase) {
            VoicePhase.listening => _listening(context),
            VoicePhase.thinking => _thinking(context),
            VoicePhase.confirm => _confirm(context),
            VoicePhase.unavailable => _unavailable(context),
            VoicePhase.error => _message(context, controller.errorMessage),
            VoicePhase.idle => _idle(context),
          },
        ),
      ),
    );
  }

  Widget _listening(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Icon(Icons.mic, size: 96, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 24),
        Text(
          '듣고 있어요.\n짧게 말씀해 주세요.',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          '예) "카카오톡 열어줘", "사진 찍어줘"',
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        if (controller.partialText.isNotEmpty)
          Text(
            controller.partialText,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
        const Spacer(),
        _bigButton(
          context,
          label: '그만 듣기',
          outlined: true,
          onPressed: () {
            controller.cancelSession();
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  Widget _thinking(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 24),
        Text(
          '"${controller.finalText}"\n찾고 있어요…',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _confirm(BuildContext context) {
    final action = controller.action ?? const NoMatchAction();
    final question = VoiceController.confirmQuestion(action);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Text(
          '"${controller.finalText}"',
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Text(
          question,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        ...switch (action) {
          OpenAppAction() => [
              _bigButton(context, label: '열기', onPressed: () => _execute(action)),
            ],
          StandardAction() => [
              _bigButton(context, label: '열기', onPressed: () => _execute(action)),
            ],
          UndecidedAction(:final candidates) => [
              for (final candidate in candidates) ...[
                _bigButton(
                  context,
                  label: candidate.label,
                  onPressed: () => _execute(candidate),
                ),
                const SizedBox(height: 12),
              ],
            ],
          _ => const <Widget>[],
        },
        const SizedBox(height: 12),
        _bigButton(
          context,
          label: '다시 말하기',
          outlined: true,
          onPressed: controller.startListening,
        ),
      ],
    );
  }

  Widget _unavailable(BuildContext context) {
    return _messageBody(
      context,
      '이 휴대폰에서는 음성 인식을 쓸 수 없어요.\n'
      '마이크 권한을 허용했는지 확인해 주세요.\n\n'
      '화면의 큰 버튼으로도 모든 기능을 쓸 수 있어요.',
    );
  }

  Widget _message(BuildContext context, String message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Text(
          message,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        _bigButton(context, label: '다시 말하기', onPressed: controller.startListening),
      ],
    );
  }

  Widget _messageBody(BuildContext context, String message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Text(
          message,
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        _bigButton(
          context,
          label: '돌아가기',
          outlined: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _idle(BuildContext context) {
    return Center(
      child: _bigButton(
        context,
        label: '다시 말하기',
        onPressed: controller.startListening,
      ),
    );
  }

  Widget _bigButton(
    BuildContext context, {
    required String label,
    required VoidCallback onPressed,
    bool outlined = false,
  }) {
    // 터치 타깃 72dp — §6 최소 60dp 초과.
    return SizedBox(
      height: 72,
      child: outlined
          ? OutlinedButton(onPressed: onPressed, child: Text(label))
          : FilledButton(onPressed: onPressed, child: Text(label)),
    );
  }
}
