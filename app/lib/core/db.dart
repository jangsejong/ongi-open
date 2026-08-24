import 'package:sqflite/sqflite.dart';

import 'config.dart';

/// 로컬 DB(sqflite) — 전 데이터 기기 내 보관, 상시 외부 전송 없음(기획설계서 §4.4).
/// v1: apps·settings / v2: usage_sessions(루틴·정리의 패턴 소스) /
/// v3: 카테고리 체계 개편(금융 분리 등 14종) 소급 재분류 마킹 /
/// v4: guardians·assist_sessions(보호자 통화 코칭 — 50_guardian_coaching.md).
///
/// v4 주의: `assist_sessions`는 감사 로그이며 **화면 내용은 저장하지 않는다**.
/// 어르신이 "도움받은 기록"에서 열람하고 보관 90일 후 정리한다(§7).
class OngiDatabase {
  OngiDatabase._();

  static final OngiDatabase instance = OngiDatabase._();

  static const _version = 4;

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = '${await getDatabasesPath()}/ongi.db';
    return openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE apps(
        package_name TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        category TEXT NOT NULL,
        category_source TEXT NOT NULL,
        aliases TEXT NOT NULL DEFAULT '',
        pinned INTEGER NOT NULL DEFAULT 0,
        first_seen_ms INTEGER NOT NULL,
        last_seen_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE settings(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _createV2(db);
    await _createV4(db);
  }

  /// 순차 마이그레이션(§4.4) — 데이터 보존.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) await _createV2(db);
    if (oldVersion < 3) await _upgradeV3(db);
    if (oldVersion < 4) await _createV4(db);
  }

  /// v3: LifeCategory 개편(금융→은행/카드·페이/증권·보험, 동영상·음악 등 신설).
  /// 사용자 지정(user)만 보존하고 나머지는 기타 폴백으로 되돌린다 — 다음
  /// syncInstalledApps가 새 규칙으로 소급 재분류하고, 잔여분은 LLM 보정이 처리.
  Future<void> _upgradeV3(Database db) async {
    await db.update(
      'apps',
      {
        'category': LifeCategory.etc.name,
        'category_source': 'fallback',
      },
      where: "category_source != 'user'",
    );
    // 사용자가 직접 옮긴 앱 중 폐기된 '금융' 칸은 은행으로 승계(가장 근접).
    await db.update(
      'apps',
      {'category': LifeCategory.bank.name},
      where: "category_source = 'user' AND category = 'finance'",
    );
  }

  Future<void> _createV2(Database db) async {
    await db.execute('''
      CREATE TABLE usage_sessions(
        package_name TEXT NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_usage_pkg_start ON usage_sessions(package_name, start_ms)',
    );
  }

  /// v4: 보호자 통화 코칭(50_guardian_coaching.md §3·§7).
  ///
  /// `guardians` — 사전 A로 등록된 보호자. **연락처를 미리 특정**하고, 목록 변경은
  /// 어르신 본인 확인을 거쳐야 한다(사전 A′·ADR-21). `device_key`는 등록 시
  /// 교환한 앱 인스턴스 바인딩 키로, 세션의 신뢰 앵커는 전화번호가 아니라 이것이다.
  Future<void> _createV4(Database db) async {
    await db.execute('''
      CREATE TABLE guardians(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        phone TEXT NOT NULL,
        device_key TEXT NOT NULL DEFAULT '',
        approved INTEGER NOT NULL DEFAULT 0,
        approved_until_ms INTEGER NOT NULL DEFAULT 0,
        created_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE assist_sessions(
        id TEXT PRIMARY KEY,
        guardian_id TEXT NOT NULL,
        guardian_name TEXT NOT NULL,
        started_ms INTEGER NOT NULL,
        ended_ms INTEGER NOT NULL DEFAULT 0,
        shared INTEGER NOT NULL DEFAULT 0,
        sensitive_seen INTEGER NOT NULL DEFAULT 0,
        end_reason TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_assist_started ON assist_sessions(started_ms)',
    );
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
