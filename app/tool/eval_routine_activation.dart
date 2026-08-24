// ignore_for_file: avoid_print — CLI 평가 하네스(프로덕션 코드 아님)
// 임시 평가 하네스 — 루틴 추천 활성화 시점 검증 (git 미추적, 평가 후 삭제 가능)
// 실행: cd app && flutter test tool/eval_routine_activation.dart
// (엔진이 sqflite 의존 체인에 있어 dart run 불가 — 테스트 러너로 실행)
// 시나리오: 고령자 사용 패턴(지터 포함)을 합성해 1~7일차 저녁 19:30에
// 런처와 동일한 로직(런처 노출 앱 필터 → ±1h → 비면 ±2h)으로 추천을 산출한다.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/routine/routine_engine.dart';
import 'package:ongi/features/routine/usage_repository.dart';

void main() => test('루틴 추천 활성화 시뮬레이션', _run);

void _run() {
  final rng = Random(42); // 고정 시드 — 재현 가능
  final base = DateTime(2026, 7, 1);
  const visiblePkgs = {'kakaotalk', 'youtube', 'bank', 'pedometer'};

  UsageSession s(String pkg, DateTime start, int minutes) => UsageSession(
        packageName: pkg,
        startMs: start.millisecondsSinceEpoch,
        endMs: start
            .add(Duration(minutes: minutes))
            .millisecondsSinceEpoch,
      );

  // day 0부터 누적 생성 — d일차 평가에는 d일치만 사용.
  List<UsageSession> genUpTo(int days) {
    final sessions = <UsageSession>[];
    for (var d = 0; d < days; d++) {
      final day = base.add(Duration(days: d));
      int jit(int range) => rng.nextInt(range * 2 + 1) - range;
      // 온기 자신·홈 런처 — 하루 종일 수시 등장(시스템 노이즈)
      for (final h in [8, 12, 19, 21]) {
        sessions.add(s('kr.tsp.ongi', day.add(Duration(hours: h)), 2));
        sessions.add(s('home.launcher', day.add(Duration(hours: h, minutes: 5)), 1));
      }
      // 카카오톡 — 아침 8시·저녁 19시대 매일(±40분 지터)
      sessions.add(s('kakaotalk', day.add(Duration(hours: 8, minutes: 30 + jit(40))), 15));
      sessions.add(s('kakaotalk', day.add(Duration(hours: 19, minutes: 30 + jit(40))), 20));
      // 유튜브 — 저녁 20시대 매일(±50분 지터)
      sessions.add(s('youtube', day.add(Duration(hours: 20, minutes: jit(50))), 45));
      // 은행 — 주 2회 오전(추천 시간대 밖)
      if (d % 3 == 0) sessions.add(s('bank', day.add(const Duration(hours: 10)), 5));
      // 만보기 — 아침 7시대 매일
      sessions.add(s('pedometer', day.add(Duration(hours: 7, minutes: jit(20))), 10));
    }
    return sessions;
  }

  print('=== 루틴 추천 활성화 시뮬레이션 (평가 시각: 매일 19:30) ===');
  for (var d = 1; d <= 7; d++) {
    final all = genUpTo(d);
    final visible = [
      for (final x in all)
        if (visiblePkgs.contains(x.packageName)) x,
    ];
    final now = base.add(Duration(days: d - 1, hours: 19, minutes: 30));
    var strict = RoutineEngine.suggest(visible, now: now);
    final widened = strict.isEmpty
        ? RoutineEngine.suggest(visible, now: now, windowHours: 2)
        : strict;
    final days = RoutineEngine.distinctActiveDays(visible);
    final label = widened.isEmpty
        ? (days < 3 ? '(배우는 중 카드)' : '(추천 없음)')
        : widened.map((x) => '${x.packageName}[${x.activeDays}일]').join(', ');
    print('$d일차: 기록 $days일, ±1h ${strict.length}건 → 표시: $label');
  }

  // 참고 — 필터 없던 구 동작의 상위 2건(활동일수 동률이면 사용시간 순이라
  // 시드에 따라 습관 앱이 이길 수도, 시스템 패키지가 독점할 수도 있다.
  // 독점 케이스의 확정 회귀는 test/launcher_routine_test.dart가 담당).
  final all7 = genUpTo(7);
  final now7 = base.add(const Duration(days: 6, hours: 19, minutes: 30));
  final unfiltered = RoutineEngine.suggest(all7, now: now7);
  print('---');
  print('(참고) 필터 없이 계산한 상위 2건: '
      '${unfiltered.map((x) => x.packageName).join(', ')}');
}
