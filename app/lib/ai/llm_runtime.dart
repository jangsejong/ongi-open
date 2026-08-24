import 'dart:async';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../core/config.dart';
import 'device_gate.dart';

/// 온디바이스 Gemma 4 E2B 런타임 — 앱에서 유일한 LLM 진입점.
///
/// 규칙(기획설계서 §4.3):
/// - 모델·채팅 세션은 앱 수명 동안 재사용(세션 생성 프리필이 동기 FFI → 매번 UI 프리즈 #364).
/// - GPU 초기화 실패는 예외가 아니라 crash로 나타남 → 로드 직전 플래그 기록,
///   성공 시 삭제. 재실행 시 플래그 잔존이면 decideTier가 한 단계 강등.
/// - thinking 비활성(createChat 기본 isThinking:false) + TextResponse만 수집.
class LlmRuntime {
  LlmRuntime({DeviceGate? gate}) : gate = gate ?? DeviceGate();

  final DeviceGate gate;

  LlmTier tier = LlmTier.off;

  InferenceModel? _model;
  InferenceChat? _chat;
  int _asksOnChat = 0;
  int _pending = 0;
  Future<bool>? _readying;
  int _readyingEpoch = -1;
  int _epoch = 0;
  Future<void> _serial = Future.value();

  /// 컨텍스트(2048 tok) 넘침 방지 — 채팅을 주기적으로 새로 만든다.
  /// (모델 로드는 유지되므로 재생성 비용은 프리필 수준.)
  static const _chatRecycleAfter = 8;

  static const _systemPrompt =
      '당신은 고령자용 스마트폰 도우미 "온기"입니다. 항상 짧고 정확하게, 요청된 형식으로만 답하세요.';

  /// RAM·crash 플래그로 등급 산출(모델 로드는 하지 않음 — 저렴).
  /// 진행 중이거나 캐시된 ensureReady 결과는 에포크로 무효화한다 — 다운로드 직후
  /// 재산출한 tier를 낡은 시도의 강등·실패 캐시가 되덮지 않도록.
  Future<void> init() async {
    _epoch++;
    tier = await gate.resolveTier();
  }

  /// 경량 모드 여부 — false면 다운로드·LLM UI 자체를 노출하지 않는다.
  bool get available => tier != LlmTier.off;

  bool get loaded => _chat != null;

  /// 모델 로드 + 채팅 세션 준비. 실패 시 등급 강등 후 재시도(GPU→CPU→off).
  /// 동시 호출은 같은 진행 중 Future를 공유한다(모델 이중 생성 방지).
  /// init()으로 에포크가 바뀐 뒤에는 진행 중 시도의 결과를 버리되, 2.6GB 이중
  /// 로드를 피하기 위해 그 시도가 끝나기를 기다렸다가 새로 시도한다.
  Future<bool> ensureReady() {
    if (_chat != null) return Future.value(true);
    if (_readying != null && _readyingEpoch == _epoch) return _readying!;
    final epoch = _epoch;
    final prior = _readying;
    late final Future<bool> attempt;
    attempt = Future(() async {
      if (prior != null) {
        try {
          await prior;
        } catch (_) {}
      }
      if (_chat != null) return true; // 낡은 시도가 로드 자체는 성공 — 재사용.
      if (epoch != _epoch) return false; // 그 사이 또 init() — 최신 호출에 양보.
      return _doEnsureReady(epoch);
    }).then((ok) {
      // 실패는 다음 호출에서 재시도 가능하게. 단 이미 새 시도가 자리를 차지했으면
      // 그쪽을 지우지 않는다(identical 검사).
      if (!ok && identical(_readying, attempt)) _readying = null;
      return ok;
    });
    _readyingEpoch = epoch;
    return _readying = attempt;
  }

  Future<bool> _doEnsureReady(int epoch) async {
    // 모델 미설치는 "백엔드 실패"가 아니다 — 강등·플래그 없이 그냥 불가 처리.
    // (다운로드 전 음성 명령이 LLM 폴백을 타는 정상 경로)
    if (!FlutterGemma.hasActiveModel()) return false;
    while (tier != LlmTier.off) {
      if (epoch != _epoch) return false; // init()이 갱신 — 낡은 시도는 종료.
      final flag = await gate.crashFlagFile(tier);
      // 로드 중 프로세스가 죽으면 플래그가 남는다 — 다음 실행에서 강등 신호(§4.3).
      await flag.writeAsString(DateTime.now().toIso8601String());
      try {
        _model = await FlutterGemma.getActiveModel(
          maxTokens: OngiConfig.maxTokens,
          preferredBackend:
              tier == LlmTier.gpu ? PreferredBackend.gpu : PreferredBackend.cpu,
        );
        await _recreateChat();
        if (await flag.exists()) await flag.delete();
        return true;
      } catch (_) {
        // 예외로 잡힌 실패 = 프로세스 생존. 플래그는 crash 감지 전용이므로 지우고
        // 이번 세션만 강등한다(영구 잔존 시 LLM이 조용히 영구 비활성되는 문제).
        try {
          if (await flag.exists()) await flag.delete();
        } catch (_) {}
        // 부분 생성된 싱글턴 리셋 — 다음 루프의 백엔드 변경 재시도를 유효하게 한다.
        try {
          await _model?.close();
        } catch (_) {}
        _model = null;
        _chat = null;
        // init()이 tier를 재산출한 뒤라면 강등으로 되덮지 않는다(다운로드 직후
        // LLM off/CPU 고착 방지).
        if (epoch != _epoch) return false;
        tier = tier == LlmTier.gpu ? LlmTier.cpu : LlmTier.off;
      }
    }
    return false;
  }

  Future<void> _recreateChat() async {
    _chat = await _model!.createChat(
      systemInstruction: _systemPrompt,
      maxOutputTokens: OngiConfig.maxOutputTokens,
    );
    _asksOnChat = 0;
  }

  /// 단발 질의 — 진행 중이면 즉시 거절한다(타임아웃된 질의가 큐를 점유해
  /// 후속 음성 명령이 연쇄 타임아웃되는 것을 방지 — 호출자는 규칙 폴백을 탄다).
  /// [timeout]은 로드+생성의 절대 상한 — 생성이 hang해도 슬롯(_pending)이
  /// 영구 점유되지 않도록 보장한다(초과 시 TimeoutException).
  Future<String> ask(
    String userText, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_pending > 0) {
      return Future.error(StateError('LLM 사용 중'));
    }
    _pending++;
    final completer = Completer<String>();
    _serial = _serial.then((_) async {
      try {
        completer.complete(await _askNow(userText).timeout(timeout));
      } catch (e, st) {
        if (e is TimeoutException) {
          // 타임아웃은 상위 Future만 끊는다 — 네이티브 생성은 계속 돌고 있어,
          // 방치하면 다음 질의의 채팅 재생성과 같은 모델 위에서 겹친다(#364).
          // 생성을 실제로 중단시키고, 다음 질의 전 채팅을 재생성한다.
          try {
            await _chat?.stopGeneration();
          } catch (_) {}
          _asksOnChat = _chatRecycleAfter;
        }
        completer.completeError(e, st);
      } finally {
        _pending--;
      }
    });
    return completer.future;
  }

  Future<String> _askNow(String userText) async {
    if (!await ensureReady()) {
      throw StateError('LLM 사용 불가(경량 모드)');
    }
    if (_asksOnChat >= _chatRecycleAfter) await _recreateChat();
    _asksOnChat++;
    await _chat!.addQueryChunk(Message.text(text: userText, isUser: true));
    final buffer = StringBuffer();
    await for (final response in _chat!.generateChatResponseAsync()) {
      if (response is TextResponse) buffer.write(response.token);
    }
    return buffer.toString().trim();
  }
}
