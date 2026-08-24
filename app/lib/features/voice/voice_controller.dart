import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../ai/intent_router.dart';
import '../../core/config.dart';
import '../../native/ongi_native.g.dart';

/// 음성 세션 상태(§6 음성 UX).
enum VoicePhase {
  idle,

  /// 듣는 중 — partial 자막 갱신.
  listening,

  /// 의도 해석 중(LLM 경로 수 초) — "찾고 있어요".
  thinking,

  /// 되묻기 — 액션 확정 대기(큰 버튼).
  confirm,

  /// STT 초기화 실패·권한 거부 — 버튼 경로 안내.
  unavailable,

  error,
}

/// 푸시투토크 음성 파이프라인: STT → 캐스케이드 라우팅 → 되묻기 → 실행 → TTS.
/// - STT 경로는 플랫폼 기본(온라인 후보) — ADR-14 확정 전. onDevice는 강제하지 않는다.
/// - 모든 비동기 단계는 세션 토큰([_session])을 검사한다 — 화면 이탈·재시작 후
///   도착한 낡은 STT 콜백/라우팅 결과/TTS가 새 세션을 오염시키지 않도록.
/// - TTS 중에는 listen하지 않는다(자기 음성 재인식 방지 §6). TalkBack 사용 중이면
///   자체 TTS를 억제한다(이중 발화 충돌).
class VoiceController extends ChangeNotifier {
  VoiceController({
    required this.router,
    required Future<List<VoiceApp>> Function() getApps,
    required Future<bool> Function(String packageName) launchApp,
    SpeechToText? speech,
    FlutterTts? tts,
    IntentActionsApi? intents,
  })  : _getApps = getApps,
        _launchApp = launchApp,
        _speech = speech ?? SpeechToText(),
        _tts = tts ?? FlutterTts(),
        _intents = intents ?? IntentActionsApi();

  final IntentRouter router;
  final Future<List<VoiceApp>> Function() _getApps;
  final Future<bool> Function(String packageName) _launchApp;
  final SpeechToText _speech;
  final FlutterTts _tts;
  final IntentActionsApi _intents;

  VoicePhase phase = VoicePhase.idle;
  String partialText = '';
  String finalText = '';
  VoiceAction? action;
  String errorMessage = '';

  /// TalkBack 등 스크린리더 사용 중 여부 — 화면이 MediaQuery로 갱신해 준다.
  bool suppressTts = false;

  double _speechRate = OngiConfig.ttsSpeechRate;

  /// 현재 말 빠르기 — 설정 화면 슬라이더의 초기값.
  double get speechRate => _speechRate;

  int _session = 0;
  int _listenSession = 0; // 현재 listen()을 소유한 세션.
  int _statusSession = 0; // 엔진 시작('listening') status를 받은 세션.
  int _autoRelistens = 0;
  Timer? _thinkingFeedback;
  bool _initialized = false;
  bool _ttsConfigured = false;

  Future<bool> _ensureInit() async {
    if (_initialized) return true;
    try {
      _initialized = await _speech.initialize(
        onStatus: (status) {
          if (status == 'listening') {
            // 엔진이 실제로 이 listen을 시작했다 — 이후 종료 status의 주인 표식.
            _statusSession = _listenSession;
            return;
          }
          // 이전 listen의 늦은 종료 신호(플러그인 내부 타이머 stop 등)가 새 세션을
          // "아무 말도 못 들었어요"로 즉사시키지 않도록, 현재 세션이 시작 신호를
          // 받은 뒤의 done/notListening만 인정한다.
          if (_statusSession != _session) return;
          // 무음·빈 인식으로 끝나면 final 콜백이 안 온다 — "듣고 있어요" 화면이
          // 죽은 마이크 상태로 고착되는 것을 여기서 끊는다.
          if ((status == 'done' || status == 'notListening') &&
              phase == VoicePhase.listening &&
              finalText.isEmpty) {
            if (partialText.isNotEmpty) {
              // 일부 기기는 final 없이 partial만 주고 끝난다 — partial 채택.
              finalText = partialText;
              unawaited(_route(_session));
            } else {
              _setError('아무 말도 못 들었어요.\n버튼을 누르고 다시 말씀해 주세요.');
            }
          }
        },
        onError: (e) {
          if (_listenSession != _session) return; // 취소된 세션의 늦은 에러 폐기.
          if (phase == VoicePhase.listening && finalText.isEmpty) {
            _setError('잘 못 들었어요.\n다시 한번 말씀해 주세요.');
          }
        },
      );
    } catch (_) {
      _initialized = false;
    }
    if (!_initialized) {
      phase = VoicePhase.unavailable;
      notifyListeners();
    }
    return _initialized;
  }

  Future<void> _ensureTts() async {
    if (_ttsConfigured) return;
    _ttsConfigured = true;
    try {
      await _tts.setLanguage('ko-KR');
      // Android 표준 1.0 — 고령자 시작점 0.75(§6). 설정 화면에서 조절.
      await _tts.setSpeechRate(_speechRate);
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
  }

  /// 말 빠르기 변경(§6 설정) — 즉시 적용. 저장은 호출자(설정 화면) 책임.
  Future<void> setSpeechRate(double rate) async {
    _speechRate =
        rate.clamp(OngiConfig.ttsRateMin, OngiConfig.ttsRateMax).toDouble();
    if (_ttsConfigured) {
      try {
        await _tts.setSpeechRate(_speechRate);
      } catch (_) {}
    }
  }

  /// 설정 화면 미리듣기 — 현재 빠르기로 샘플 한 문장.
  /// 사용자가 명시적으로 요청한 발화이므로 TalkBack 억제(suppressTts)를
  /// 우회한다 — 억제 대상은 음성 플로의 자동 프롬프트다(§6). suppressTts는
  /// 음성 화면 진입 시점 값이 잔존하므로 여기 걸면 버튼이 조용히 죽는다.
  Future<void> previewSpeechRate() async {
    await _ensureTts();
    try {
      await _tts.stop();
      await _tts.speak('이 빠르기로 읽어 드릴게요.');
    } catch (_) {}
  }

  Future<void> _speak(String text) async {
    if (suppressTts) return;
    await _ensureTts();
    try {
      await _tts.stop(); // 진행 중 발화("찾고 있어요" 등) 즉시 교체.
      await _tts.speak(text);
    } catch (_) {}
  }

  /// 마이크 버튼 — 듣기 시작(푸시투토크 1탭 방식, ADR-4).
  /// [auto]=true는 미인식 자동 재청취 경로(연속 1회 제한).
  Future<void> startListening({bool auto = false}) async {
    if (!await _ensureInit()) return;
    if (!auto) _autoRelistens = 0;
    _session++;
    final session = _session;
    _listenSession = session;
    _thinkingFeedback?.cancel();
    try {
      await _tts.stop();
    } catch (_) {}
    partialText = '';
    finalText = '';
    action = null;
    phase = VoicePhase.listening;
    notifyListeners();
    try {
      await _speech.listen(
        onResult: (result) {
          if (session != _session) return; // 취소된 세션의 늦은 콜백 폐기.
          partialText = result.recognizedWords;
          notifyListeners();
          if (result.finalResult &&
              result.recognizedWords.isNotEmpty &&
              finalText.isEmpty) {
            finalText = result.recognizedWords;
            unawaited(_route(session));
          }
        },
        listenOptions: SpeechListenOptions(
          listenFor: const Duration(seconds: OngiConfig.sttListenSeconds),
          pauseFor: const Duration(seconds: OngiConfig.sttPauseSeconds),
          localeId: 'ko_KR',
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } catch (_) {
      if (session == _session) _setError('음성 인식을 시작하지 못했어요.');
    }
  }

  /// 화면 이탈·"그만 듣기" — 진행 중인 청취·라우팅·TTS를 전부 무효화한다.
  void cancelSession() {
    _session++;
    _thinkingFeedback?.cancel();
    unawaited(Future(() => _speech.stop()).catchError((_) {}));
    unawaited(Future(() => _tts.stop()).catchError((_) {}));
    phase = VoicePhase.idle;
    partialText = '';
    finalText = '';
    action = null;
    notifyListeners();
  }

  void reset() {
    cancelSession();
    errorMessage = '';
    _autoRelistens = 0;
  }

  Future<void> _route(int session) async {
    if (session != _session || phase != VoicePhase.listening) return;
    phase = VoicePhase.thinking;
    notifyListeners();
    // 규칙 즉답이면 안 들리고, LLM 경로가 길어질 때만 나오는 음성 피드백(§4.2).
    _thinkingFeedback?.cancel();
    _thinkingFeedback = Timer(const Duration(milliseconds: 700), () {
      if (session == _session && phase == VoicePhase.thinking) {
        unawaited(_speak('찾고 있어요.'));
      }
    });
    List<VoiceApp> apps;
    try {
      apps = await _getApps();
    } catch (_) {
      apps = const [];
    }
    final result = await router.route(finalText, apps);
    _thinkingFeedback?.cancel();
    if (session != _session) return; // 이탈·재시작 후 도착한 낡은 결과 폐기.
    action = result.action;
    phase = VoicePhase.confirm;
    notifyListeners();
    await _speak(confirmQuestion(result.action));
    if (session != _session) return;
    // "다시 말씀해 주세요"라고 말했으면 실제로 다시 들어야 한다(죽은 마이크 방지).
    if (result.action is NoMatchAction && _autoRelistens < 1) {
      _autoRelistens++;
      await startListening(auto: true);
    }
  }

  /// 되묻기 문구(§6 에코+되묻기) — 화면·TTS 공용.
  static String confirmQuestion(VoiceAction action) => switch (action) {
        OpenAppAction(:final label) => '$label을 열까요?',
        StandardAction(:final kind) => '${kind.label}을 열까요?',
        UndecidedAction() => '이 중에 찾으시는 것이 있나요?',
        NoMatchAction() => '잘 못 알아들었어요. 다시 말씀해 주세요.',
      };

  /// 확정 실행 — 되묻기에서 큰 버튼으로만 진입(음성 단독 실행 금지 원칙은
  /// 비가역 행동 기준이지만, M2는 전 액션 터치 확정으로 통일).
  Future<bool> execute(VoiceAction target) async {
    final session = _session;
    var ok = false;
    try {
      ok = switch (target) {
        OpenAppAction(:final packageName) => await _launchApp(packageName),
        StandardAction(:final kind) => await _executeStandard(kind),
        _ => false,
      };
    } catch (_) {
      ok = false;
    }
    // 실행 중 재청취·취소가 시작됐다면 화면 상태는 새 세션 소유 — 덮지 않는다.
    if (session != _session) return ok;
    if (ok) {
      phase = VoicePhase.idle;
      notifyListeners();
    } else {
      _setError('열 수가 없었어요.\n다시 시도해 주세요.');
    }
    return ok;
  }

  Future<bool> _executeStandard(StandardIntentKind kind) => switch (kind) {
        StandardIntentKind.dial => _intents.openDialer(),
        StandardIntentKind.sms => _intents.openSmsComposer(),
        StandardIntentKind.camera => _intents.openCamera(),
        StandardIntentKind.gallery => _intents.openGallery(),
        StandardIntentKind.alarm => _intents.showAlarms(),
      };

  void _setError(String message) {
    errorMessage = message;
    phase = VoicePhase.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _thinkingFeedback?.cancel();
    unawaited(Future(() => _speech.stop()).catchError((_) {}));
    unawaited(Future(() => _tts.stop()).catchError((_) {}));
    super.dispose();
  }
}
