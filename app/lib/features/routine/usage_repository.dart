import '../../core/db.dart';
import '../../native/ongi_native.g.dart';

/// 사용 세션 저장소(§4.4 usage_sessions) — 전부 기기 내, 외부 전송 없음.
/// OS의 이벤트 보존기간 한계에 대비해 앱 실행 시 스냅샷을 DB에 누적한다
/// (설계서는 WorkManager 일 1회 — 대회 트랙에서는 앱 실행 시 동기화로 갈음).
class UsageRepository {
  UsageRepository({UsageStatsApi? statsApi, OngiDatabase? db})
      : _stats = statsApi ?? UsageStatsApi(),
        _db = db ?? OngiDatabase.instance;

  static const _syncedUntilKey = 'usage_synced_until_ms';

  /// 패턴 학습 범위 — 최근 14일(루틴 §4.2), 정리 판단은 30일(§3 ④).
  static const historyDays = 30;

  final UsageStatsApi _stats;
  final OngiDatabase _db;

  Future<bool> isGranted() async {
    try {
      return await _stats.isUsageAccessGranted();
    } catch (_) {
      return false;
    }
  }

  Future<void> openSettings() => _stats.openUsageAccessSettings();

  /// 동기화 경계에 걸친 세션의 RESUMED 이벤트는 이전 구간에 있어 짝이 안 맞아
  /// 유실된다 — 이만큼 겹쳐 재조회해 경계 세션을 온전히 다시 파생한다.
  static const _overlapMs = 12 * Duration.millisecondsPerHour;

  /// 권한이 있으면 마지막 동기화 이후 세션을 DB에 누적하고 오래된 행을 정리한다.
  Future<void> sync() async {
    if (!await isGranted()) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final horizon = now - historyDays * Duration.millisecondsPerDay;
    final syncedUntil =
        int.tryParse(await _db.getSetting(_syncedUntilKey) ?? '') ?? horizon;
    final from = syncedUntil < horizon ? horizon : syncedUntil;
    if (now - from < Duration.millisecondsPerMinute) return;
    final queryFrom =
        from - _overlapMs < horizon ? horizon : from - _overlapMs;

    final sessions = await _stats.queryUsageSessions(queryFrom, now);
    final db = await _db.database;
    final batch = db.batch();
    // 재파생 세션과 같은 키(package, start)의 기존 행만 개별 교체(upsert).
    // 범위 삭제는 OS 이벤트 보존기간(수 일)이 지난 구간에서 재조회로 복원할 수
    // 없는 축적분까지 지운다(긴 공백 후 실행 시 이력 소실 — 이 DB의 존재 이유
    // 훼손). 경계 세션은 같은 start로 재파생되므로 잘렸던 끝도 교체로 복원된다.
    for (final s in sessions) {
      batch.delete(
        'usage_sessions',
        where: 'package_name = ? AND start_ms = ?',
        whereArgs: [s.packageName, s.startMs],
      );
      batch.insert('usage_sessions', {
        'package_name': s.packageName,
        'start_ms': s.startMs,
        'end_ms': s.endMs,
      });
    }
    batch.delete('usage_sessions', where: 'end_ms < ?', whereArgs: [horizon]);
    await batch.commit(noResult: true);
    await _db.setSetting(_syncedUntilKey, '$now');
  }

  /// 최근 [days]일 세션 전체 — 루틴 엔진 입력.
  Future<List<UsageSession>> recentSessions({int days = 14}) async {
    final db = await _db.database;
    final from = DateTime.now().millisecondsSinceEpoch -
        days * Duration.millisecondsPerDay;
    final rows = await db.query(
      'usage_sessions',
      where: 'start_ms >= ?',
      whereArgs: [from],
    );
    return [
      for (final row in rows)
        UsageSession(
          packageName: row['package_name'] as String,
          startMs: row['start_ms'] as int,
          endMs: row['end_ms'] as int,
        ),
    ];
  }

  /// 패키지별 마지막 사용 시각 — 미사용 앱 정리 판단(§3 ④).
  Future<Map<String, int>> lastUsedByPackage() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT package_name, MAX(end_ms) AS last_used FROM usage_sessions '
      'GROUP BY package_name',
    );
    return {
      for (final row in rows)
        row['package_name'] as String: row['last_used'] as int,
    };
  }
}

class UsageSession {
  const UsageSession({
    required this.packageName,
    required this.startMs,
    required this.endMs,
  });

  final String packageName;
  final int startMs;
  final int endMs;
}
