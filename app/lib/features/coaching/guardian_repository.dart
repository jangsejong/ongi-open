import 'dart:math';

import '../../core/db.dart';

/// 사전 등록된 보호자(50_guardian_coaching.md §3 사전 A).
///
/// [deviceKey]는 등록 시 교환한 앱 인스턴스 바인딩 키다. **세션의 신뢰 앵커는
/// 전화번호가 아니라 이 값**이며(ADR-21), 발신번호가 일치해도 이 키로 응답하지
/// 못하면 화면 공유가 열리지 않는다.
class Guardian {
  const Guardian({
    required this.id,
    required this.name,
    required this.phone,
    required this.deviceKey,
    required this.approved,
    required this.approvedUntilMs,
    required this.createdMs,
  });

  final String id;
  final String name;
  final String phone;
  final String deviceKey;

  /// 사전 B(관계 증빙 + 관리자 승인) 통과 여부.
  final bool approved;

  /// 승인 유효기간(0이면 무기한). 만료되면 세션 대상에서 빠진다.
  final int approvedUntilMs;

  final int createdMs;

  /// 앱 인스턴스 바인딩이 끝났는가 — 통화만 가능하고 화면 공유는 불가한 상태 구분.
  bool get isBound => deviceKey.isNotEmpty;

  bool isUsableAt(int nowMs) =>
      approved && (approvedUntilMs == 0 || approvedUntilMs > nowMs);

  Guardian copyWith({
    String? name,
    String? phone,
    String? deviceKey,
    bool? approved,
    int? approvedUntilMs,
  }) =>
      Guardian(
        id: id,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        deviceKey: deviceKey ?? this.deviceKey,
        approved: approved ?? this.approved,
        approvedUntilMs: approvedUntilMs ?? this.approvedUntilMs,
        createdMs: createdMs,
      );

  static Guardian _fromRow(Map<String, Object?> row) => Guardian(
        id: row['id'] as String,
        name: row['name'] as String,
        phone: row['phone'] as String,
        deviceKey: row['device_key'] as String? ?? '',
        approved: (row['approved'] as int? ?? 0) == 1,
        approvedUntilMs: row['approved_until_ms'] as int? ?? 0,
        createdMs: row['created_ms'] as int? ?? 0,
      );

  Map<String, Object?> _toRow() => {
        'id': id,
        'name': name,
        'phone': phone,
        'device_key': deviceKey,
        'approved': approved ? 1 : 0,
        'approved_until_ms': approvedUntilMs,
        'created_ms': createdMs,
      };
}

/// 종료된 코칭 세션 1건(§7 감사 로그). **화면 내용은 담지 않는다.**
class AssistSession {
  const AssistSession({
    required this.id,
    required this.guardianId,
    required this.guardianName,
    required this.startedMs,
    required this.endedMs,
    required this.shared,
    required this.sensitiveSeen,
    required this.endReason,
  });

  final String id;
  final String guardianId;
  final String guardianName;
  final int startedMs;
  final int endedMs;

  /// 화면 공유까지 갔는가(통화만 하고 끝났으면 false).
  final bool shared;

  /// 인증·공공·의료 화면을 재동의 후 공유한 적이 있는가 — 사후 감사용.
  final bool sensitiveSeen;

  final String endReason;

  Duration get duration => endedMs > startedMs
      ? Duration(milliseconds: endedMs - startedMs)
      : Duration.zero;

  static AssistSession _fromRow(Map<String, Object?> row) => AssistSession(
        id: row['id'] as String,
        guardianId: row['guardian_id'] as String,
        guardianName: row['guardian_name'] as String,
        startedMs: row['started_ms'] as int,
        endedMs: row['ended_ms'] as int? ?? 0,
        shared: (row['shared'] as int? ?? 0) == 1,
        sensitiveSeen: (row['sensitive_seen'] as int? ?? 0) == 1,
        endReason: row['end_reason'] as String? ?? '',
      );
}

/// 보호자 등록·세션 이력 저장소 — 전부 기기 내(sqflite).
///
/// **등록 변경 보호(사전 A′·ADR-21)는 이 계층이 아니라 호출부(화면)에서 어르신
/// 본인 확인을 통과한 뒤에만 쓰기 메서드를 부른다.** 저장소는 인증을 알지 못하며,
/// 그 규칙은 위젯 테스트로 고정한다.
class GuardianRepository {
  GuardianRepository({OngiDatabase? db, Random? random})
      : _db = db ?? OngiDatabase.instance,
        _random = random ?? Random.secure();

  final OngiDatabase _db;
  final Random _random;

  /// 세션 보관 기간(§7) — 이보다 오래된 이력은 정리한다.
  static const retention = Duration(days: 90);

  Future<List<Guardian>> all() async {
    final db = await _db.database;
    final rows = await db.query('guardians', orderBy: 'created_ms ASC');
    return [for (final row in rows) Guardian._fromRow(row)];
  }

  /// 지금 세션을 열 수 있는 보호자만 — 승인됐고 유효기간이 남은 사람.
  Future<List<Guardian>> usable(int nowMs) async =>
      [for (final g in await all()) if (g.isUsableAt(nowMs)) g];

  Future<Guardian?> byId(String id) async {
    final db = await _db.database;
    final rows =
        await db.query('guardians', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Guardian._fromRow(rows.first);
  }

  /// 사전 A — 보호자 등록. 연락처를 미리 특정하는 것이 이 기능의 전제다.
  Future<Guardian> add({
    required String name,
    required String phone,
    required int nowMs,
    String deviceKey = '',
    bool approved = false,
    int approvedUntilMs = 0,
  }) async {
    final guardian = Guardian(
      id: _newId(),
      name: name.trim(),
      phone: _normalizePhone(phone),
      deviceKey: deviceKey,
      approved: approved,
      approvedUntilMs: approvedUntilMs,
      createdMs: nowMs,
    );
    final db = await _db.database;
    await db.insert('guardians', guardian._toRow());
    return guardian;
  }

  /// 사전 A′ — 연락처 수정. 호출 전에 어르신 본인 확인이 끝나 있어야 한다.
  Future<void> update(Guardian guardian) async {
    final db = await _db.database;
    await db.update(
      'guardians',
      guardian._toRow(),
      where: 'id = ?',
      whereArgs: [guardian.id],
    );
  }

  /// 사전 A′ — 등록 해제. 어르신은 언제든 할 수 있다(§3).
  Future<void> remove(String id) async {
    final db = await _db.database;
    await db.delete('guardians', where: 'id = ?', whereArgs: [id]);
  }

  /// 앱 인스턴스 바인딩 키 저장 — 등록 보호자의 앱이 페어링을 마쳤을 때.
  Future<void> bindDeviceKey(String id, String deviceKey) async {
    final db = await _db.database;
    await db.update(
      'guardians',
      {'device_key': deviceKey},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 세션 시작 기록. 종료 시 [finishSession]으로 마감한다.
  Future<String> startSession({
    required Guardian guardian,
    required int nowMs,
  }) async {
    final id = _newId();
    final db = await _db.database;
    await db.insert('assist_sessions', {
      'id': id,
      'guardian_id': guardian.id,
      'guardian_name': guardian.name,
      'started_ms': nowMs,
      'ended_ms': 0,
      'shared': 0,
      'sensitive_seen': 0,
      'end_reason': '',
    });
    return id;
  }

  Future<void> finishSession({
    required String sessionId,
    required int nowMs,
    required bool shared,
    required bool sensitiveSeen,
    required String endReason,
  }) async {
    final db = await _db.database;
    await db.update(
      'assist_sessions',
      {
        'ended_ms': nowMs,
        'shared': shared ? 1 : 0,
        'sensitive_seen': sensitiveSeen ? 1 : 0,
        'end_reason': endReason,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// 어르신이 보는 "도움받은 기록" — 최신순.
  Future<List<AssistSession>> history({int limit = 50}) async {
    final db = await _db.database;
    final rows = await db.query(
      'assist_sessions',
      orderBy: 'started_ms DESC',
      limit: limit,
    );
    return [for (final row in rows) AssistSession._fromRow(row)];
  }

  /// 보관기간(90일) 지난 이력 정리 — 앱 시작 시 비차단으로 호출한다.
  Future<int> pruneHistory(int nowMs) async {
    final db = await _db.database;
    return db.delete(
      'assist_sessions',
      where: 'started_ms < ?',
      whereArgs: [nowMs - retention.inMilliseconds],
    );
  }

  String _newId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return [
      for (var i = 0; i < 16; i++) chars[_random.nextInt(chars.length)],
    ].join();
  }

  /// 하이픈·공백을 제거해 저장 — 발신·대조 모두 숫자만 쓴다.
  static String _normalizePhone(String raw) =>
      raw.replaceAll(RegExp(r'[^0-9+]'), '');
}
