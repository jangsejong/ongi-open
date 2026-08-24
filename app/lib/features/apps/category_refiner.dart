import '../../core/config.dart';
import '../../ai/llm_runtime.dart';
import 'app_repository.dart';

/// 규칙 사각지대 앱을 LLM으로 보정 분류한다(기획설계서 §4.2).
/// - 모델 준비 후 백그라운드로 1회 배치 실행(상한 [batchLimit] — 발열·배터리 보호).
/// - 파싱 실패 항목은 건너뛴다(잘못 분류하느니 기타 유지 — 정확도 우선).
/// 반환: 실제로 카테고리가 바뀐 앱 수.
Future<int> refineCategoriesWithLlm(
  AppRepository apps,
  LlmRuntime llm, {
  int batchLimit = 20,
  Duration startDelay = const Duration(minutes: 2),
  Duration askTimeout = const Duration(seconds: 90),
}) async {
  if (!llm.available) return 0;
  // 모델 준비 직후는 사용자가 음성부터 써 보는 시점 — ask 슬롯을 바로 점유하면
  // 음성 캐스케이드 2차가 전면 거절된다(ask는 진행 중이면 즉시 거절). 한 박자 늦게.
  if (startDelay > Duration.zero) {
    await Future<void>.delayed(startDelay);
    if (!llm.available) return 0;
  }
  final targets = await apps.unclassified(limit: batchLimit);
  if (targets.isEmpty) return 0;
  if (!await llm.ensureReady()) return 0;

  final ids = LifeCategory.values.map((c) => '${c.name}(${c.label})').join(', ');
  final numbered = [
    for (var i = 0; i < targets.length; i++) '${i + 1}. ${targets[i].label}',
  ].join('\n');
  final prompt = '다음 스마트폰 앱들을 카테고리로 분류하세요.\n'
      '카테고리: $ids\n'
      '반드시 "번호:카테고리ID" 형식으로 한 줄에 하나씩만 답하세요. 다른 말은 하지 마세요.\n'
      '딱 맞는 카테고리가 없는 앱(예: 커피 주문, 요리 레시피)은 억지로 고르지 말고 etc로 답하세요.\n'
      '$numbered';

  final String answer;
  try {
    // 배치 분류는 생성이 길다 — 전용 상한. hang·과점유는 ask가 끊어 준다.
    answer = await llm.ask(prompt, timeout: askTimeout);
  } catch (_) {
    return 0;
  }

  // 소문자 키 매칭 — 카멜케이스 ID(publicService)를 LLM이 소문자로 답해도 수용.
  final byName = {
    for (final c in LifeCategory.values) c.name.toLowerCase(): c,
  };
  final linePattern = RegExp(r'^\s*(\d+)\s*[:.]\s*([A-Za-z]+)');
  var changed = 0;
  for (final line in answer.split('\n')) {
    final match = linePattern.firstMatch(line);
    if (match == null) continue;
    final index = int.parse(match.group(1)!) - 1;
    final category = byName[match.group(2)!.toLowerCase()];
    if (index < 0 || index >= targets.length || category == null) continue;
    if (category == LifeCategory.etc) {
      // 기타 확정 — 재보정 대상에서 제외되도록 출처만 llm으로 승격.
      await apps.setCategory(targets[index].packageName, LifeCategory.etc,
          source: 'llm');
      continue;
    }
    await apps.setCategory(targets[index].packageName, category, source: 'llm');
    changed++;
  }
  return changed;
}
