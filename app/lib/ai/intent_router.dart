// 음성 명령 의도 해석 — 2단계 캐스케이드(기획설계서 §4.2, ADR-5).
//
// [1차] 규칙 매칭(수십 ms): 앱 라벨·별칭 최장일치 + 표준 명령 키워드.
// [2차] 규칙 실패 시에만 LLM — 액션 ID만 고른다. 인텐트 문자열은 절대
//       LLM이 만들지 않는다(네이티브 화이트리스트 IntentActionsApi가 조립).
// LLM 불가(경량 모드)·타임아웃이면 후보 제시/미인식으로 폴백 — 음성 기능은
// LLM 없이도 성립한다(§1 제1원칙).
import 'dart:async';

/// 라우터가 아는 앱 한 건 — features 의존을 피하기 위한 최소 표현.
class VoiceApp {
  const VoiceApp({
    required this.packageName,
    required this.label,
    this.aliases = const [],
  });

  final String packageName;
  final String label;
  final List<String> aliases;
}

/// 표준 기능(무권한 인텐트 화이트리스트와 1:1).
enum StandardIntentKind {
  dial('전화 걸기 화면'),
  sms('문자 보내기 화면'),
  camera('카메라'),
  gallery('사진첩'),
  alarm('알람');

  const StandardIntentKind(this.label);

  final String label;
}

sealed class VoiceAction {
  const VoiceAction();
}

class OpenAppAction extends VoiceAction {
  const OpenAppAction({required this.packageName, required this.label});

  final String packageName;
  final String label;
}

class StandardAction extends VoiceAction {
  const StandardAction(this.kind);

  final StandardIntentKind kind;
}

/// 다의성 — 후보를 큰 버튼으로 제시(§4.2 터치 마무리).
class UndecidedAction extends VoiceAction {
  const UndecidedAction(this.candidates);

  final List<OpenAppAction> candidates;
}

class NoMatchAction extends VoiceAction {
  const NoMatchAction();
}

/// 해석 결과. [source]는 rule|llm — 로그·튜닝용.
class RouteResult {
  const RouteResult(this.action, {required this.source});

  final VoiceAction action;
  final String source;
}

class IntentRouter {
  // 타임아웃 12초 — 워밍업된 모델의 프리필+한 단어 생성이면 충분하고,
  // 저시력 사용자의 무음 대기 상한(§6)을 겸한다. 초과 시 후보 제시 폴백.
  IntentRouter({required this.llmAsk, this.llmTimeout = const Duration(seconds: 12)});

  /// LLM 질의 함수(주입) — 경량 모드면 null 반환하는 래퍼를 넣는다.
  final Future<String> Function(String prompt)? llmAsk;

  final Duration llmTimeout;

  /// LLM 프롬프트에 넣는 앱 수 상한(컨텍스트 2048 tok 보호).
  static const llmAppListLimit = 60;

  /// 표준 명령 키워드 — 검사 순서 중요(카메라의 '사진 찍'이 갤러리 '사진'보다 먼저).
  static const List<(StandardIntentKind, List<String>)> _standardKeywords = [
    (StandardIntentKind.camera, ['카메라', '사진 찍', '사진찍', '셀카']),
    (StandardIntentKind.gallery, ['갤러리', '앨범', '사진첩', '사진 보', '사진보']),
    (StandardIntentKind.dial, ['전화']),
    (StandardIntentKind.sms, ['문자', '메시지 보내', '메세지 보내']),
    (StandardIntentKind.alarm, ['알람']),
  ];

  Future<RouteResult> route(String utterance, List<VoiceApp> apps) async {
    final ruled = matchRule(utterance, apps);
    if (ruled is! NoMatchAction) {
      return RouteResult(ruled, source: 'rule');
    }
    final llm = llmAsk;
    if (llm == null) {
      return RouteResult(_fallback(utterance, apps), source: 'rule');
    }
    try {
      final answer =
          await llm(buildLlmPrompt(utterance, apps)).timeout(llmTimeout);
      return RouteResult(parseLlmAnswer(answer, apps), source: 'llm');
    } on TimeoutException {
      return RouteResult(_fallback(utterance, apps), source: 'llm');
    } catch (_) {
      return RouteResult(_fallback(utterance, apps), source: 'llm');
    }
  }

  /// [1차] 규칙 매칭 — 순수 함수(단위 테스트 대상).
  /// 앱 라벨·별칭(구체적)이 표준 키워드(일반적)보다 우선한다.
  static VoiceAction matchRule(String utterance, List<VoiceApp> apps) {
    final text = _normalize(utterance);
    if (text.isEmpty) return const NoMatchAction();

    // 앱 라벨·별칭 — 발화에 포함된 것 중 최장일치. 1글자 라벨은 오탐이라 제외.
    final matches = <(int, OpenAppAction)>[];
    for (final app in apps) {
      var best = 0;
      for (final name in [app.label, ...app.aliases]) {
        final normalized = _normalize(name);
        if (normalized.length < 2) continue;
        if (text.contains(normalized) && normalized.length > best) {
          best = normalized.length;
        }
      }
      if (best > 0) {
        matches.add(
          (best, OpenAppAction(packageName: app.packageName, label: app.label)),
        );
      }
    }
    if (matches.isNotEmpty) {
      matches.sort((a, b) => b.$1.compareTo(a.$1));
      final longest = matches.first.$1;
      final top = matches.where((m) => m.$1 == longest).toList();
      if (top.length == 1) return top.first.$2;
      return UndecidedAction([for (final m in top.take(3)) m.$2]);
    }

    for (final (kind, keywords) in _standardKeywords) {
      for (final keyword in keywords) {
        if (text.contains(_normalize(keyword))) return StandardAction(kind);
      }
    }
    return const NoMatchAction();
  }

  /// [2차] LLM 프롬프트 — 액션 ID 카탈로그 + 번호 매긴 앱 목록.
  static String buildLlmPrompt(String utterance, List<VoiceApp> apps) {
    final list = apps.take(llmAppListLimit).toList();
    final numbered = [
      for (var i = 0; i < list.length; i++) '${i + 1}. ${list[i].label}',
    ].join('\n');
    return '사용자가 휴대폰에 말했습니다: "$utterance"\n'
        '사용자가 원하는 것을 하나만 고르세요.\n'
        '- 전화 걸기: dial / 문자 보내기: sms / 사진 찍기: camera / 사진 보기: gallery / 알람: alarm\n'
        '- 아래 앱을 열고 싶어하면: app:번호\n'
        '$numbered\n'
        '해당 없으면: none\n'
        '답은 딱 한 단어(또는 app:번호)만 쓰세요.';
  }

  /// LLM 응답 파싱 — 형식을 벗어나면 전부 미인식 처리(정확도 우선).
  static VoiceAction parseLlmAnswer(String answer, List<VoiceApp> apps) {
    final text = answer.trim().toLowerCase();
    final appMatch = RegExp(r'app\s*[:.]?\s*(\d+)').firstMatch(text);
    if (appMatch != null) {
      final index = int.parse(appMatch.group(1)!) - 1;
      final list = apps.take(llmAppListLimit).toList();
      if (index < 0 || index >= list.length) return const NoMatchAction();
      final app = list[index];
      return OpenAppAction(packageName: app.packageName, label: app.label);
    }
    for (final kind in StandardIntentKind.values) {
      if (text.contains(kind.name)) return StandardAction(kind);
    }
    return const NoMatchAction();
  }

  /// LLM 불가·타임아웃 폴백 — 2-gram 겹침으로 후보 2~3개 제시(§4.2).
  static VoiceAction _fallback(String utterance, List<VoiceApp> apps) {
    final grams = _bigrams(_normalize(utterance));
    if (grams.isEmpty) return const NoMatchAction();
    final scored = <(int, OpenAppAction)>[];
    for (final app in apps) {
      final overlap =
          _bigrams(_normalize(app.label)).intersection(grams).length;
      if (overlap > 0) {
        scored.add((
          overlap,
          OpenAppAction(packageName: app.packageName, label: app.label),
        ));
      }
    }
    if (scored.isEmpty) return const NoMatchAction();
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    return UndecidedAction([for (final s in scored.take(3)) s.$2]);
  }

  static String _normalize(String input) =>
      input.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static Set<String> _bigrams(String text) => {
        for (var i = 0; i + 2 <= text.length; i++) text.substring(i, i + 2),
      };
}
