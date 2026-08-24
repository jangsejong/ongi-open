import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/llm_runtime.dart';
import 'model_manager.dart';

/// 모델 다운로드 동의·진행·실패 화면(기획설계서 §8 [3]) — 전 문구 큰글씨.
class ModelScreen extends StatefulWidget {
  const ModelScreen({super.key, required this.model, required this.llm});

  final ModelManager model;
  final LlmRuntime llm;

  @override
  State<ModelScreen> createState() => _ModelScreenState();
}

class _ModelScreenState extends State<ModelScreen> {
  bool _startedHere = false;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _onChanged() async {
    if (!mounted) return;
    setState(() {});
    // 이 화면에서 시작한 다운로드가 검증까지 통과 → 파일이 온전하다는 뜻이므로
    // 과거 백엔드 crash 플래그를 리셋하고 등급을 다시 산출한다(§4.3).
    if (_startedHere && widget.model.phase == ModelPhase.ready) {
      _startedHere = false;
      await widget.llm.gate.clearCrashFlags();
      await widget.llm.init();
      // 워밍업 — 첫 음성 LLM 라우팅에서 콜드 로드 타임아웃 방지(§4.2).
      unawaited(widget.llm.ensureReady());
    }
  }

  Future<void> _startDownload() async {
    final onWifi = await widget.model.isOnWifi();
    if (!mounted) return;
    if (!onWifi) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Wi-Fi가 아니에요'),
          content: const Text('데이터 요금이 많이 나올 수 있어요.\nWi-Fi에 연결한 뒤 받기를 권해요.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('그래도 받기'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    _startedHere = true;
    await widget.model.download();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('더 똑똑한 온기')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (widget.model.phase) {
            ModelPhase.downloading => _downloading(context),
            ModelPhase.verifying => _verifying(context),
            ModelPhase.ready => _ready(context),
            ModelPhase.failed => _failed(context),
            _ => _consent(context),
          },
        ),
      ),
    );
  }

  Widget _consent(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyLarge;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('온기의 인공지능을 받아올까요?',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 24),
        Text('• 크기가 약 2.6GB로 커요', style: body),
        Text('• Wi-Fi에서 받기를 권해요', style: body),
        Text('• 10~30분쯤 걸릴 수 있어요', style: body),
        Text('• 받는 동안에도 온기를 그대로 쓸 수 있어요', style: body),
        const SizedBox(height: 12),
        Text('받은 뒤에는 인터넷 없이, 모든 것이 이 휴대폰 안에서만 움직여요.',
            style: body?.copyWith(fontWeight: FontWeight.bold)),
        const Spacer(),
        FutureBuilder<bool>(
          future: widget.model.hasEnoughStorage(),
          builder: (context, snapshot) {
            final enough = snapshot.data ?? true;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!enough)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '저장 공간이 부족해요. 사진이나 동영상을 정리한 뒤 다시 열어 주세요. (약 3.6GB 필요)',
                      style: body?.copyWith(
                          color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                SizedBox(
                  height: 64,
                  child: FilledButton(
                    onPressed: enough ? _startDownload : null,
                    child: const Text('지금 받기'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 64,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('나중에 할게요'),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _downloading(BuildContext context) {
    final model = widget.model;
    final minutes = model.elapsedSec ~/ 60;
    final seconds = model.elapsedSec % 60;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('받고 있어요', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 32),
        LinearProgressIndicator(
          value: model.progressPercent / 100,
          minHeight: 16,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(height: 16),
        Text(
          '${model.progressPercent}%  ($minutes분 $seconds초)',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        Text(
          '이 화면을 나가도 계속 받아요.\n단, 앱을 완전히 닫으면 멈춰요.',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      ],
    );
  }

  Widget _verifying(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 24),
        Text(
          '받은 파일이 온전한지 확인하고 있어요.\n1~2분 걸려요.',
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _ready(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.check_circle,
            size: 96, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 24),
        Text(
          '다 받았어요!\n이제 온기가 더 똑똑해져요.',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        SizedBox(
          height: 64,
          child: FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    final message = switch (widget.model.failure) {
      ModelFailure.storage =>
        '저장 공간이 부족해요.\n사진이나 동영상을 정리한 뒤 다시 시도해 주세요. (약 3.6GB 필요)',
      ModelFailure.network => '받는 중에 연결이 끊겼어요.\nWi-Fi 가까이에서 다시 시도해 주세요.',
      ModelFailure.verify => '받은 파일이 온전하지 않아요.\n다시 받아 주세요.',
      _ => '문제가 생겼어요.\n잠시 뒤 다시 시도해 주세요.',
    };
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.error_outline,
            size: 96, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 24),
        Text(message,
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center),
        const SizedBox(height: 32),
        SizedBox(
          height: 64,
          child: FilledButton(
            onPressed: _startDownload,
            child: const Text('다시 시도'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('나중에 할게요'),
          ),
        ),
      ],
    );
  }
}
