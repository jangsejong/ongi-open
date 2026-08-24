// 실기기 없이 음성 파이프라인을 검증하는 행위 테스트 — 플랫폼 계층(STT·TTS·인텐트)을
// 페이크로 주입해 상태기계·세션 토큰·폴백 경로를 재현한다(적대 검증 리뷰 수정분 회귀 방지).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ongi/ai/intent_router.dart';
import 'package:ongi/core/config.dart';
import 'package:ongi/features/voice/voice_controller.dart';
import 'package:ongi/native/ongi_native.g.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class FakeSpeech implements SpeechToText {
  @override
  void Function(String)? statusListener;
  void Function(SpeechRecognitionResult)? resultListener;
  int listenCalls = 0;

  /// 실제 엔진은 listen 성공 시 'listening' status를 보낸다 — 기본 재현.
  /// false면 "엔진 시작 신호가 아직 안 온" 레이스 구간을 재현할 수 있다.
  bool autoEmitListening = true;

  void emitPartial(String words) => resultListener?.call(
        SpeechRecognitionResult.init(
          [SpeechRecognitionWords(words, null, 0.9)],
          ResultType.partial,
        ),
      );

  void emitFinal(String words) => resultListener?.call(
        SpeechRecognitionResult.init(
          [SpeechRecognitionWords(words, null, 0.9)],
          ResultType.finalResult,
        ),
      );

  void emitStatus(String status) => statusListener?.call(status);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #initialize:
        statusListener = invocation.namedArguments[const Symbol('onStatus')]
            as void Function(String)?;
        return Future<bool>.value(true);
      case #listen:
        resultListener = invocation.namedArguments[const Symbol('onResult')]
            as void Function(SpeechRecognitionResult)?;
        listenCalls++;
        if (autoEmitListening) statusListener?.call('listening');
        return Future<void>.value();
      case #stop:
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class FakeTts implements FlutterTts {
  final spoken = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #speak) {
      spoken.add(invocation.positionalArguments.first as String);
    }
    // setLanguage·setSpeechRate·awaitSpeakCompletion·stop 등은 성공 처리.
    return Future<dynamic>.value(1);
  }
}

class FakeIntents extends IntentActionsApi {
  final calls = <String>[];

  @override
  Future<bool> openDialer() async {
    calls.add('dial');
    return true;
  }

  @override
  Future<bool> openSmsComposer() async {
    calls.add('sms');
    return true;
  }

  @override
  Future<bool> openCamera() async {
    calls.add('camera');
    return true;
  }

  @override
  Future<bool> openGallery() async {
    calls.add('gallery');
    return true;
  }

  @override
  Future<bool> showAlarms() async {
    calls.add('alarm');
    return true;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late FakeSpeech speech;
  late FakeTts tts;
  late FakeIntents intents;
  late List<String> launched;
  Completer<bool>? launchGate; // 설정하면 앱 기동이 완료를 기다린다(레이스 재현).

  VoiceController make({Future<String> Function(String)? llmAsk}) {
    speech = FakeSpeech();
    tts = FakeTts();
    intents = FakeIntents();
    launched = [];
    launchGate = null;
    return VoiceController(
      router: IntentRouter(llmAsk: llmAsk),
      getApps: () async => const [
        VoiceApp(packageName: 'com.kakao.talk', label: '카카오톡', aliases: ['카톡']),
      ],
      launchApp: (packageName) async {
        launched.add(packageName);
        return launchGate == null ? true : await launchGate!.future;
      },
      speech: speech,
      tts: tts,
      intents: intents,
    );
  }

  test('정상 흐름: final → 되묻기(에코 TTS) → 실행', () async {
    final c = make();
    await c.startListening();
    speech.emitFinal('카카오톡 열어줘');
    await settle();
    expect(c.phase, VoicePhase.confirm);
    expect(c.action, isA<OpenAppAction>());
    expect(tts.spoken.last, '카카오톡을 열까요?'); // §6 에코+되묻기
    final ok = await c.execute(c.action!);
    expect(ok, isTrue);
    expect(launched, ['com.kakao.talk']);
    expect(c.phase, VoicePhase.idle);
  });

  test('표준 명령: "사진 찍어줘" → 카메라 인텐트(화이트리스트)', () async {
    final c = make();
    await c.startListening();
    speech.emitFinal('사진 찍어줘');
    await settle();
    expect((c.action as StandardAction).kind, StandardIntentKind.camera);
    await c.execute(c.action!);
    expect(intents.calls, ['camera']);
  });

  test('무음 종료(final 없음) → "듣고 있어요" 고착 없이 안내로 전환', () async {
    final c = make();
    await c.startListening();
    speech.emitStatus('done'); // Android 무음 컷오프 — onResult 없이 종료
    await settle();
    expect(c.phase, VoicePhase.error);
    expect(c.errorMessage, contains('아무 말도'));
  });

  test('final 없이 partial만 주고 끝나는 기기 → partial 채택 후 라우팅', () async {
    final c = make();
    await c.startListening();
    speech.emitPartial('카카오톡');
    speech.emitStatus('done');
    await settle();
    expect(c.phase, VoicePhase.confirm);
    expect((c.action as OpenAppAction).packageName, 'com.kakao.talk');
  });

  test('세션 취소 후 도착한 늦은 final은 무시 — 유령 TTS 없음', () async {
    final c = make();
    await c.startListening();
    c.cancelSession(); // 화면 이탈(dispose)·그만 듣기와 동일 경로
    speech.emitFinal('카카오톡 열어줘');
    await settle();
    expect(c.phase, VoicePhase.idle);
    expect(tts.spoken, isEmpty);
    expect(launched, isEmpty);
  });

  test('미인식 → "다시 말씀해 주세요" TTS 후 자동 재청취(연속 1회 제한)', () async {
    final c = make(); // llmAsk 없음 → 폴백, 겹치는 후보도 없음 → NoMatch
    await c.startListening();
    expect(speech.listenCalls, 1);
    speech.emitFinal('으라차차');
    await settle();
    // 죽은 마이크에 대고 말하게 하지 않는다 — 마이크 자동 재개.
    expect(speech.listenCalls, 2);
    expect(c.phase, VoicePhase.listening);
    speech.emitFinal('으라차차');
    await settle();
    // 두 번째 미인식은 재청취하지 않고 버튼 대기(무한 루프 방지).
    expect(speech.listenCalls, 2);
    expect(c.phase, VoicePhase.confirm);
    expect(c.action, isA<NoMatchAction>());
  });

  test('규칙 실패 → LLM이 액션 ID만 선택 → 되묻기(§4.2 캐스케이드 2차)', () async {
    final c = make(llmAsk: (_) async => 'app:1');
    await c.startListening();
    speech.emitFinal('심심한데 뭐 볼까'); // 라벨·표준 키워드 전부 미매칭
    await settle();
    expect(c.phase, VoicePhase.confirm);
    expect((c.action as OpenAppAction).packageName, 'com.kakao.talk');
    expect(tts.spoken.last, '카카오톡을 열까요?');
  });

  test('이전 청취의 늦은 종료 신호(done)는 새 세션을 죽이지 않는다', () async {
    final c = make();
    await c.startListening();
    speech.emitFinal('으라차차'); // NoMatch → 자동 재청취(세션 2)
    speech.autoEmitListening = false; // 재청취 엔진의 시작 신호가 아직 안 온 구간 재현
    await settle();
    expect(c.phase, VoicePhase.listening);
    expect(speech.listenCalls, 2);
    speech.emitStatus('done'); // 세션 1의 늦은 종료 신호(플러그인 타이머 stop 등)
    await settle();
    expect(c.phase, VoicePhase.listening); // "아무 말도 못 들었어요" 즉사 없음
    // 엔진이 실제로 시작한 뒤의 정상 무음·partial 흐름은 그대로 동작.
    speech.emitStatus('listening');
    speech.emitPartial('카카오톡');
    speech.emitStatus('done');
    await settle();
    expect(c.phase, VoicePhase.confirm);
    expect((c.action as OpenAppAction).packageName, 'com.kakao.talk');
  });

  test('말 빠르기 설정 — 범위 밖 값은 슬라이더 범위로 고정(§6)', () async {
    final c = make();
    expect(c.speechRate, OngiConfig.ttsSpeechRate);
    await c.setSpeechRate(2.0);
    expect(c.speechRate, OngiConfig.ttsRateMax);
    await c.setSpeechRate(0.1);
    expect(c.speechRate, OngiConfig.ttsRateMin);
  });

  test('실행 중 재청취를 시작하면 실행 완료가 새 청취 화면을 덮지 않는다', () async {
    final c = make();
    await c.startListening();
    speech.emitFinal('카카오톡 열어줘');
    await settle();
    expect(c.phase, VoicePhase.confirm);
    // "열기"와 "다시 말하기"를 연달아 탭 — 앱 기동이 끝나기 전에 재청취 시작.
    launchGate = Completer<bool>();
    final exec = c.execute(c.action!);
    await c.startListening();
    expect(c.phase, VoicePhase.listening);
    launchGate!.complete(true);
    expect(await exec, isTrue);
    expect(c.phase, VoicePhase.listening); // idle로 되덮이지 않는다(죽은 마이크 방지)
  });
}
