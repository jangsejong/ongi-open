import 'usage_repository.dart';

/// 루틴 추천 후보 하나 — "지금 이 시간대에 자주 쓰는 앱".
class RoutineSuggestion {
  const RoutineSuggestion({
    required this.packageName,
    required this.activeDays,
    required this.totalMinutes,
  });

  final String packageName;

  /// 해당 시간대 창에서 사용한 서로 다른 날짜 수(습관 강도).
  final int activeDays;
  final int totalMinutes;
}

/// hour-of-day × day-of-week 규칙 엔진(§4.2 루틴) — 순수 함수, 단위 테스트 대상.
/// LLM은 (있다면) 안내 문구 생성만 담당하고 후보 선정은 항상 이 규칙이 한다.
class RoutineEngine {
  RoutineEngine._();

  /// 현재 시각 ±[windowHours] 시간대(요일 무관 + 같은 요일 가중은 단순화 — 대회 범위)에
  /// [minActiveDays]일 이상 등장한 앱을 사용 시간 순으로 최대 [limit]개 추천.
  static List<RoutineSuggestion> suggest(
    List<UsageSession> sessions, {
    required DateTime now,
    int windowHours = 1,
    int minActiveDays = 3,
    int limit = 2,
    Set<String> exclude = const {},
  }) {
    final activeDaysByPkg = <String, Set<String>>{};
    final minutesByPkg = <String, int>{};

    for (final session in sessions) {
      if (exclude.contains(session.packageName)) continue;
      final start = DateTime.fromMillisecondsSinceEpoch(session.startMs);
      if (_hourDistance(start.hour, now.hour) > windowHours) continue;
      final dayKey = '${start.year}-${start.month}-${start.day}';
      activeDaysByPkg.putIfAbsent(session.packageName, () => {}).add(dayKey);
      minutesByPkg[session.packageName] =
          (minutesByPkg[session.packageName] ?? 0) +
              ((session.endMs - session.startMs) ~/ 60000);
    }

    final candidates = [
      for (final entry in activeDaysByPkg.entries)
        if (entry.value.length >= minActiveDays)
          RoutineSuggestion(
            packageName: entry.key,
            activeDays: entry.value.length,
            totalMinutes: minutesByPkg[entry.key] ?? 0,
          ),
    ]..sort((a, b) {
        final byDays = b.activeDays.compareTo(a.activeDays);
        return byDays != 0 ? byDays : b.totalMinutes.compareTo(a.totalMinutes);
      });
    return candidates.take(limit).toList();
  }

  /// 세션이 기록된 서로 다른 날짜 수 — 학습 진행 판단(3일 미만 = 배우는 중).
  static int distinctActiveDays(List<UsageSession> sessions) {
    final days = <String>{};
    for (final session in sessions) {
      final start = DateTime.fromMillisecondsSinceEpoch(session.startMs);
      days.add('${start.year}-${start.month}-${start.day}');
    }
    return days.length;
  }

  /// 시(hour) 원형 거리 — 23시와 0시는 1시간 차.
  static int _hourDistance(int a, int b) {
    final diff = (a - b).abs();
    return diff > 12 ? 24 - diff : diff;
  }
}
