import '../../ai/llm_runtime.dart';

/// 루틴 추천 카드 문구 — LLM이 준비돼 있으면 시간대·앱에 맞춘 따뜻한 한 문장,
/// 아니면 고정 문구(§4.2 — LLM은 향상이지 의존이 아니다).
const routineFallbackPhrase = '지금 이 시간에 자주 쓰셨어요';

/// 프롬프트에 넣는 시간대 표현 — 순수 함수(테스트 대상).
String timeSlotLabel(int hour) {
  if (hour >= 5 && hour < 11) return '아침';
  if (hour >= 11 && hour < 17) return '낮';
  if (hour >= 17 && hour < 22) return '저녁';
  return '밤';
}

String buildRoutinePhrasePrompt(List<String> labels, DateTime now) =>
    '고령자 사용자가 ${timeSlotLabel(now.hour)} 이 시간에 자주 쓰는 앱: ${labels.join(', ')}\n'
    '이 앱을 권하는 따뜻한 문장을 하나만 만드세요.\n'
    '존댓말로 25자 안팎, 앱 이름 포함, 인사말·설명 없이 그 문장만 쓰세요.';

/// LLM 출력 정제 — 형식을 벗어나면 null(고정 문구 폴백, 정확도 우선).
/// [mustContainAny]가 있으면 그중 하나를 포함해야 통과 — 프롬프트가 앱 이름
/// 포함을 요구하므로, '네, 알겠습니다.' 같은 서두·메타 문장을 걸러낸다.
String? sanitizeRoutinePhrase(
  String raw, {
  List<String> mustContainAny = const [],
}) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  text = text.split('\n').first.trim();
  text = text
      .replaceAll('*', '')
      .replaceAll('"', '')
      .replaceAll("'", '')
      .replaceAll('“', '')
      .replaceAll('”', '')
      .trim();
  if (text.isEmpty || text.length > 60) return null;
  if (mustContainAny.isNotEmpty && !mustContainAny.any(text.contains)) {
    return null;
  }
  return text;
}

/// 백그라운드 1회 생성 — 모델이 이미 로드된 경우에만(카드 문구 때문에 2.6GB
/// 콜드 로드를 유발하지 않는다). 미로드·거절·실패는 null → 호출자가 고정 문구.
/// 타임아웃은 짧게 잡는다 — 카드 장식 문구가 단일 LLM 슬롯을 오래 점유해
/// 음성 캐스케이드 2차를 거절시키면 안 된다(§4.2 음성 우선).
Future<String?> generateRoutinePhrase(
  LlmRuntime llm,
  List<String> labels,
  DateTime now, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (labels.isEmpty || !llm.available || !llm.loaded) return null;
  try {
    final answer =
        await llm.ask(buildRoutinePhrasePrompt(labels, now), timeout: timeout);
    return sanitizeRoutinePhrase(answer, mustContainAny: labels);
  } catch (_) {
    return null; // ask busy 거절·타임아웃 포함 — 음성 경로가 항상 우선(§4.2).
  }
}
