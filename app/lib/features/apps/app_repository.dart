import 'dart:typed_data';

import '../../core/config.dart';
import '../../core/db.dart';
import '../../native/ongi_native.g.dart';
import 'category_rules.dart';

/// 분류된 설치 앱 한 건 — DB `apps` 행의 도메인 표현.
class AppEntry {
  const AppEntry({
    required this.packageName,
    required this.label,
    required this.category,
    required this.categorySource,
    this.aliases = const [],
    this.pinned = false,
  });

  final String packageName;
  final String label;
  final LifeCategory category;

  /// rule(사전·키워드) | fallback(기타 폴백 — LLM 보정 후보) | llm | user
  final String categorySource;

  /// 음성 별칭(보호자 등록 — §8) — 쉼표 구분 컬럼의 파싱 결과.
  final List<String> aliases;
  final bool pinned;
}

/// 앱 스캔 → 규칙 분류 → sqflite 캐시 → 실행(기획설계서 §4.2).
/// 분류 결과는 캐시가 원본이다 — 매 실행 재분류하지 않고 신규 앱만 분류한다.
class AppRepository {
  AppRepository({AppScanApi? scanApi, OngiDatabase? db})
      : _scan = scanApi ?? AppScanApi(),
        _db = db ?? OngiDatabase.instance;

  static const _selfPackage = 'kr.tsp.ongi';

  final AppScanApi _scan;
  final OngiDatabase _db;
  final Map<String, Uint8List?> _iconCache = {};
  Map<String, int> _installTimes = {};

  /// 패키지별 설치 시각(ms) — 미사용 앱 정리의 기산점(§3 ④).
  /// 마지막 스캔의 캐시를 재사용하고, 스캔 전이면 1회 조회한다.
  Future<Map<String, int>> installTimesByPackage() async {
    if (_installTimes.isEmpty) {
      try {
        _cacheInstallTimes(await _scan.getInstalledApps());
      } catch (_) {} // 실패 시 빈 맵 — 호출자는 사용 기록 기준으로 폴백.
    }
    return _installTimes;
  }

  void _cacheInstallTimes(List<NativeAppInfo> apps) {
    _installTimes = {
      for (final app in apps)
        if (app.firstInstallMs > 0) app.packageName: app.firstInstallMs,
    };
  }

  /// 설치 앱 목록을 DB와 동기화한다 — 신규만 분류, 제거된 앱은 삭제.
  Future<void> syncInstalledApps() async {
    final apps = await _scan.getInstalledApps();
    // 스캔이 빈 결과를 주면(일시적 PM 오류 등) 아래 삭제 경로가 캐시 전체
    // — 사용자 지정 카테고리·별칭 포함 — 를 지운다. 빈 결과는 동기화하지 않는다.
    if (apps.isEmpty) return;
    _cacheInstallTimes(apps);
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final existing = <String, Map<String, Object?>>{
      for (final row in await db.query('apps'))
        row['package_name'] as String: row,
    };

    final batch = db.batch();
    final seen = <String>{};
    for (final app in apps) {
      if (app.packageName == _selfPackage) continue;
      seen.add(app.packageName);
      if (existing.containsKey(app.packageName)) {
        final row = existing[app.packageName]!;
        // 사전이 확장되면 폴백(미매칭) 캐시에도 소급 적용한다 — 규칙에 새로
        // 걸리는 앱만 승격하고, user/llm/rule 확정 분류는 건드리지 않는다.
        final reclassify = row['category_source'] == 'fallback'
            ? CategoryRules.classify(app.packageName, app.label)
            : null;
        batch.update(
          'apps',
          {
            'label': app.label,
            'last_seen_ms': now,
            if (reclassify != null && reclassify.matched) ...{
              'category': reclassify.category.name,
              'category_source': 'rule',
            },
          },
          where: 'package_name = ?',
          whereArgs: [app.packageName],
        );
      } else {
        final result = CategoryRules.classify(app.packageName, app.label);
        batch.insert('apps', {
          'package_name': app.packageName,
          'label': app.label,
          'category': result.category.name,
          'category_source': result.matched ? 'rule' : 'fallback',
          'first_seen_ms': now,
          'last_seen_ms': now,
        });
      }
    }
    for (final packageName in existing.keys) {
      if (!seen.contains(packageName)) {
        batch.delete(
          'apps',
          where: 'package_name = ?',
          whereArgs: [packageName],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  /// 카테고리별 앱 목록 — 고정(pinned) 우선, 라벨순.
  Future<Map<LifeCategory, List<AppEntry>>> appsByCategory() async {
    final db = await _db.database;
    final rows = await db.query('apps', orderBy: 'pinned DESC, label ASC');
    final result = <LifeCategory, List<AppEntry>>{
      for (final category in LifeCategory.values) category: [],
    };
    for (final row in rows) {
      final entry = _fromRow(row);
      result[entry.category]!.add(entry);
    }
    return result;
  }

  /// 규칙 사각지대(기타 폴백) 앱 — LLM 보정 대상(§4.2, 발열 방지 배치 상한).
  Future<List<AppEntry>> unclassified({int limit = 20}) async {
    final db = await _db.database;
    final rows = await db.query(
      'apps',
      where: "category = ? AND category_source = 'fallback'",
      whereArgs: [LifeCategory.etc.name],
      orderBy: 'label ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> setCategory(
    String packageName,
    LifeCategory category, {
    required String source,
  }) async {
    final db = await _db.database;
    await db.update(
      'apps',
      {'category': category.name, 'category_source': source},
      where: 'package_name = ?',
      whereArgs: [packageName],
    );
  }

  /// 음성 별칭 등록(보호자 §8, ADR-12) — 쉼표 구분 누적, 중복 무시.
  Future<void> addAlias(String packageName, String alias) async {
    final trimmed = alias.trim().replaceAll(',', ' ');
    if (trimmed.isEmpty) return;
    final db = await _db.database;
    final rows = await db.query(
      'apps',
      columns: ['aliases'],
      where: 'package_name = ?',
      whereArgs: [packageName],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final aliases = [
      for (final a in (rows.first['aliases'] as String? ?? '').split(','))
        if (a.trim().isNotEmpty) a.trim(),
    ];
    if (aliases.contains(trimmed)) return;
    aliases.add(trimmed);
    await db.update(
      'apps',
      {'aliases': aliases.join(',')},
      where: 'package_name = ?',
      whereArgs: [packageName],
    );
  }

  Future<bool> launch(String packageName) => _scan.launchApp(packageName);

  /// 음성 라우터용 전체 앱 인덱스(라벨·별칭) — 라벨순.
  Future<List<AppEntry>> allApps() async {
    final db = await _db.database;
    final rows = await db.query('apps', orderBy: 'label ASC');
    return rows.map(_fromRow).toList();
  }

  /// 앱 아이콘(PNG) — 세션 캐시. null이면 기본 아이콘으로 표시.
  Future<Uint8List?> icon(String packageName) async {
    if (_iconCache.containsKey(packageName)) return _iconCache[packageName];
    Uint8List? bytes;
    try {
      bytes = await _scan.getAppIcon(packageName);
    } catch (_) {
      bytes = null;
    }
    _iconCache[packageName] = bytes;
    return bytes;
  }

  AppEntry _fromRow(Map<String, Object?> row) {
    final categoryName = row['category'] as String;
    final aliasesRaw = row['aliases'] as String? ?? '';
    return AppEntry(
      packageName: row['package_name'] as String,
      label: row['label'] as String,
      category: LifeCategory.values.firstWhere(
        (c) => c.name == categoryName,
        orElse: () => LifeCategory.etc,
      ),
      categorySource: row['category_source'] as String,
      aliases: [
        for (final alias in aliasesRaw.split(','))
          if (alias.trim().isNotEmpty) alias.trim(),
      ],
      pinned: (row['pinned'] as int? ?? 0) != 0,
    );
  }
}
