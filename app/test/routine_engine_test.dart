import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/routine/routine_engine.dart';
import 'package:ongi/features/routine/usage_repository.dart';

UsageSession session(String pkg, DateTime start, {int minutes = 10}) =>
    UsageSession(
      packageName: pkg,
      startMs: start.millisecondsSinceEpoch,
      endMs: start.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
    );

void main() {
  final now = DateTime(2026, 7, 11, 20); // 저녁 8시

  group('RoutineEngine.suggest — hour×dow 규칙(§4.2)', () {
    test('현재 시간대에 3일 이상 쓴 앱만 추천된다', () {
      final sessions = [
        // 유튜브: 저녁 8시대에 4일 — 추천 대상
        for (var d = 1; d <= 4; d++)
          session('youtube', DateTime(2026, 7, d + 6, 20, 10)),
        // 은행: 저녁 8시대 2일뿐 — 임계 미달
        for (var d = 1; d <= 2; d++)
          session('bank', DateTime(2026, 7, d + 6, 20, 30)),
        // 카메라: 아침 9시대 5일 — 시간대 밖
        for (var d = 1; d <= 5; d++)
          session('camera', DateTime(2026, 7, d + 5, 9)),
      ];
      final result = RoutineEngine.suggest(sessions, now: now);
      expect(result.map((s) => s.packageName), ['youtube']);
      expect(result.first.activeDays, 4);
    });

    test('습관 강도(사용 일수) 우선, 동률이면 사용 시간 순', () {
      final sessions = [
        for (var d = 1; d <= 3; d++)
          session('a', DateTime(2026, 7, d + 6, 20), minutes: 5),
        for (var d = 1; d <= 3; d++)
          session('b', DateTime(2026, 7, d + 6, 20), minutes: 60),
        for (var d = 1; d <= 4; d++)
          session('c', DateTime(2026, 7, d + 6, 20), minutes: 1),
      ];
      final result = RoutineEngine.suggest(sessions, now: now, limit: 3);
      expect(result.map((s) => s.packageName), ['c', 'b', 'a']);
    });

    test('자정 경계 — 23시 세션은 0시 기준 ±1시간 창에 포함', () {
      final sessions = [
        for (var d = 1; d <= 3; d++)
          session('night', DateTime(2026, 7, d + 6, 23, 30)),
      ];
      final result = RoutineEngine.suggest(
        sessions,
        now: DateTime(2026, 7, 11, 0, 10),
      );
      expect(result.map((s) => s.packageName), ['night']);
    });

    test('창 확대(windowHours: 2) — ±1h에 없던 습관이 ±2h에서 잡힌다', () {
      final sessions = [
        for (var d = 1; d <= 3; d++)
          session('radio', DateTime(2026, 7, d + 6, 18, 30)), // 저녁 6시대
      ];
      expect(RoutineEngine.suggest(sessions, now: now), isEmpty); // ±1h 밖
      final widened = RoutineEngine.suggest(sessions, now: now, windowHours: 2);
      expect(widened.map((s) => s.packageName), ['radio']);
    });

    test('distinctActiveDays — 세션이 기록된 서로 다른 날짜 수', () {
      final sessions = [
        session('a', DateTime(2026, 7, 9, 9)),
        session('b', DateTime(2026, 7, 9, 20)), // 같은 날
        session('a', DateTime(2026, 7, 10, 9)),
      ];
      expect(RoutineEngine.distinctActiveDays(sessions), 2);
      expect(RoutineEngine.distinctActiveDays(const []), 0);
    });

    test('제외 목록(exclude)은 후보에서 빠진다', () {
      final sessions = [
        for (var d = 1; d <= 5; d++)
          session('youtube', DateTime(2026, 7, d + 6, 20)),
      ];
      final result = RoutineEngine.suggest(
        sessions,
        now: now,
        exclude: {'youtube'},
      );
      expect(result, isEmpty);
    });
  });
}
