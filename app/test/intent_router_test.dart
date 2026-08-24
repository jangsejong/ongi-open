import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/ai/intent_router.dart';

const _apps = [
  VoiceApp(packageName: 'com.kakao.talk', label: '카카오톡', aliases: ['카톡']),
  VoiceApp(packageName: 'com.nhn.android.search', label: '네이버'),
  VoiceApp(packageName: 'viva.republica.toss', label: '토스'),
  VoiceApp(packageName: 'com.google.android.youtube', label: 'YouTube', aliases: ['유튜브']),
];

void main() {
  group('IntentRouter.matchRule — 1차 규칙(§4.2)', () {
    test('앱 라벨 매칭 — "카카오톡 열어줘"', () {
      final action = IntentRouter.matchRule('카카오톡 열어줘', _apps);
      expect(action, isA<OpenAppAction>());
      expect((action as OpenAppAction).packageName, 'com.kakao.talk');
    });

    test('별칭 매칭 — "카톡 켜줘", "유튜브 틀어줘"', () {
      expect(
        (IntentRouter.matchRule('카톡 켜줘', _apps) as OpenAppAction).packageName,
        'com.kakao.talk',
      );
      expect(
        (IntentRouter.matchRule('유튜브 틀어줘', _apps) as OpenAppAction)
            .packageName,
        'com.google.android.youtube',
      );
    });

    test('표준 명령 — 전화/문자/카메라/갤러리/알람', () {
      expect(
        (IntentRouter.matchRule('전화 걸어줘', _apps) as StandardAction).kind,
        StandardIntentKind.dial,
      );
      expect(
        (IntentRouter.matchRule('문자 보내줘', _apps) as StandardAction).kind,
        StandardIntentKind.sms,
      );
      expect(
        (IntentRouter.matchRule('사진 찍어줘', _apps) as StandardAction).kind,
        StandardIntentKind.camera,
      );
      expect(
        (IntentRouter.matchRule('사진 보여줘', _apps) as StandardAction).kind,
        StandardIntentKind.gallery,
      );
      expect(
        (IntentRouter.matchRule('알람 맞춰줘', _apps) as StandardAction).kind,
        StandardIntentKind.alarm,
      );
    });

    test('앱 라벨이 표준 키워드보다 우선 — 구체적인 것이 이긴다', () {
      const apps = [
        VoiceApp(packageName: 'com.x.phonebook', label: '전화번호부'),
        ..._apps,
      ];
      final action = IntentRouter.matchRule('전화번호부 열어줘', apps);
      expect(action, isA<OpenAppAction>());
      expect((action as OpenAppAction).packageName, 'com.x.phonebook');
    });

    test('미인식 발화는 NoMatch — LLM 폴백 대상', () {
      expect(IntentRouter.matchRule('심심해', _apps), isA<NoMatchAction>());
      expect(IntentRouter.matchRule('', _apps), isA<NoMatchAction>());
    });
  });

  group('IntentRouter — 2차 LLM 경로', () {
    test('규칙 실패 시 LLM이 액션 ID를 고른다 — "app:번호" 파싱', () async {
      final router = IntentRouter(llmAsk: (prompt) async {
        expect(prompt, contains('심심한데 영상'));
        return 'app:4';
      });
      final result = await router.route('심심한데 영상 볼래', _apps);
      expect(result.source, 'llm');
      expect(result.action, isA<OpenAppAction>());
      expect(
        (result.action as OpenAppAction).packageName,
        'com.google.android.youtube',
      );
    });

    test('LLM 표준 액션 단어 응답 파싱', () async {
      final router = IntentRouter(llmAsk: (_) async => 'camera');
      final result = await router.route('멋진 장면 남기고 싶어', _apps);
      expect((result.action as StandardAction).kind, StandardIntentKind.camera);
    });

    test('형식 밖 응답·범위 밖 번호는 미인식 처리(정확도 우선)', () {
      expect(
        IntentRouter.parseLlmAnswer('글쎄요, 잘 모르겠네요', _apps),
        isA<NoMatchAction>(),
      );
      expect(
        IntentRouter.parseLlmAnswer('app:99', _apps),
        isA<NoMatchAction>(),
      );
    });

    test('LLM 예외·타임아웃 시 후보 제시 폴백(2-gram)', () async {
      final router = IntentRouter(
        llmAsk: (_) => throw StateError('LLM 사용 불가(경량 모드)'),
      );
      final result = await router.route('카카오 뭐더라', _apps);
      expect(result.action, isA<UndecidedAction>());
      final candidates = (result.action as UndecidedAction).candidates;
      expect(candidates.first.packageName, 'com.kakao.talk');
    });

    test('타임아웃 폴백 — 늦은 LLM 응답을 기다리지 않는다', () async {
      final router = IntentRouter(
        llmAsk: (_) => Completer<String>().future, // 영원히 미완료
        llmTimeout: const Duration(milliseconds: 50),
      );
      final result = await router.route('카카오 어디 갔지', _apps);
      expect(result.action, isA<UndecidedAction>());
    });
  });
}
