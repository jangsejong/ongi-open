// 루틴 문구 생성의 순수 부분(프롬프트·정제·시간대)만 검증 — LLM 실호출 금지.
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/routine/routine_phrase.dart';

void main() {
  group('sanitizeRoutinePhrase — LLM 출력 정제(형식 밖=고정 문구 폴백)', () {
    test('따옴표·별표 제거 + 첫 줄만 채택', () {
      expect(
        sanitizeRoutinePhrase('"카카오톡으로 안부를 전해 보세요."\n(다른 문장도 필요하시면…)'),
        '카카오톡으로 안부를 전해 보세요.',
      );
      expect(sanitizeRoutinePhrase('**유튜브 볼 시간이에요**'), '유튜브 볼 시간이에요');
    });

    test('빈 응답·과도하게 긴 응답은 null', () {
      expect(sanitizeRoutinePhrase('   '), isNull);
      expect(sanitizeRoutinePhrase('"”'), isNull);
      expect(sanitizeRoutinePhrase('가' * 61), isNull);
    });

    test('앱 이름 포함 요구 — 서두·메타 문장("네, 알겠습니다") 거절', () {
      expect(
        sanitizeRoutinePhrase('네, 알겠습니다.', mustContainAny: ['유튜브']),
        isNull,
      );
      expect(
        sanitizeRoutinePhrase('다음은 추천 문장입니다:', mustContainAny: ['유튜브']),
        isNull,
      );
      expect(
        sanitizeRoutinePhrase('유튜브에서 즐거운 영상 보실 시간이에요.',
            mustContainAny: ['유튜브', '카카오톡']),
        '유튜브에서 즐거운 영상 보실 시간이에요.',
      );
    });
  });

  test('시간대 라벨 — 경계값', () {
    expect(timeSlotLabel(5), '아침');
    expect(timeSlotLabel(10), '아침');
    expect(timeSlotLabel(11), '낮');
    expect(timeSlotLabel(16), '낮');
    expect(timeSlotLabel(17), '저녁');
    expect(timeSlotLabel(21), '저녁');
    expect(timeSlotLabel(22), '밤');
    expect(timeSlotLabel(2), '밤');
  });

  test('프롬프트에 앱 이름·시간대·형식 지시가 들어간다', () {
    final prompt =
        buildRoutinePhrasePrompt(['유튜브', '카카오톡'], DateTime(2026, 7, 12, 19));
    expect(prompt, contains('유튜브, 카카오톡'));
    expect(prompt, contains('저녁'));
    expect(prompt, contains('존댓말'));
  });
}
