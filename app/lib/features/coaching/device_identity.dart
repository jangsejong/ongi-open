import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/db.dart';

/// 이 기기의 인스턴스 신원과 역할(50_guardian_coaching.md §9 · ADR-20/21).
///
/// [deviceKey]는 세션의 **신뢰 앵커**다. 전화번호가 아니라 이 값으로 상대를
/// 확인하므로, 발신번호를 위조해도 화면 공유가 열리지 않는다. 최초 실행 때 한 번
/// 만들어 기기 안에 두고, 등록(사전 A) 때 보호자와 교환한다.
///
/// 역할은 온기 1개 앱에서 어르신/보호자 화면을 가르는 스위치다. 보호자 모드는
/// 2.6GB 모델을 받지 않는다.
/// 역할이 바뀌면 [notifyListeners]로 알린다 — 루트 게이트가 화면과 연결을 다시
/// 세울 수 있어야 역할 선택이 되돌릴 수 있는 결정이 된다.
class DeviceIdentity extends ChangeNotifier {
  DeviceIdentity({OngiDatabase? db, Random? random})
      : _db = db ?? OngiDatabase.instance,
        _random = random ?? Random.secure();

  final OngiDatabase _db;
  final Random _random;

  String _key = '';
  String _role = '';
  String _relay = '';

  /// 등록·세션에 쓰는 이 기기의 인스턴스 키. [load] 전에는 빈 문자열.
  String get deviceKey => _key;

  /// [OngiConfig.roleElder] | [OngiConfig.roleGuardian] | '' (아직 안 고름)
  String get role => _role;

  bool get isGuardian => _role == OngiConfig.roleGuardian;
  bool get roleChosen => _role.isNotEmpty;

  /// 최초 실행이면 키를 만들어 저장하고, 이후에는 읽어 온다.
  Future<void> load() async {
    _key = await _db.getSetting(OngiConfig.deviceKeySettingKey) ?? '';
    if (_key.isEmpty) {
      _key = _newKey();
      await _db.setSetting(OngiConfig.deviceKeySettingKey, _key);
    }
    _role = await _db.getSetting(OngiConfig.roleSettingKey) ?? '';
    _relay = await _db.getSetting(OngiConfig.coachingRelaySettingKey) ?? '';
  }

  /// 저장이 끝난 뒤에 바꾼다 — 먼저 바꿔 두면 DB 쓰기가 실패했을 때 메모리만
  /// 새 역할이 되고, 같은 값이라 중복 가드에 걸려 다시 눌러도 아무 일이 없다.
  /// 역할 선택 화면에서 그대로 갇히는 경로다.
  Future<void> setRole(String role) async {
    if (_role == role) return;
    await _db.setSetting(OngiConfig.roleSettingKey, role);
    _role = role;
    notifyListeners();
  }

  /// 코칭 릴레이 주소 — **기기 설정에만 있고 코드에는 없다.** 비어 있으면 접속하지
  /// 않는다(코칭을 쓰지 않는 기기가 남의 주소로 재시도를 돌리지 않게).
  String get relayUrl => _relay;

  /// 주소를 바꾸면 알린다 — 루트 게이트가 연결을 새 주소로 다시 세운다.
  /// 역할 변경과 같은 취급이다(둘 다 "지금 붙어 있는 연결이 틀렸다"는 신호).
  Future<void> setRelayUrl(String url) async {
    final next = url.trim();
    if (_relay == next) return;
    await _db.setSetting(OngiConfig.coachingRelaySettingKey, next);
    _relay = next;
    notifyListeners();
  }

  /// 26자 — 충돌 확률이 무시할 수준이면서 페어링 코드로 앞자리를 잘라 쓰기 좋다.
  String _newKey() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return [
      for (var i = 0; i < 26; i++) chars[_random.nextInt(chars.length)],
    ].join();
  }

  /// 페어링 코드 — 어르신 화면에 띄우고 보호자가 자기 앱에 입력하는 6자리.
  /// 통화 중에 말로 불러 주는 것을 전제로 짧게 잡는다(시니어 UX).
  static String pairingCodeOf(String deviceKey) =>
      deviceKey.isEmpty ? '' : deviceKey.substring(0, 6).toUpperCase();
}
