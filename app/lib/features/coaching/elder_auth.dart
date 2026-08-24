import 'package:local_auth/local_auth.dart';

/// 어르신 본인 확인 결과 — 실패 사유를 구분해야 안내가 막다른 길이 되지 않는다(CG1).
enum ElderAuthResult {
  ok,

  /// 기기 잠금(생체·PIN·패턴) 자체가 설정되어 있지 않다.
  /// 이 경우 기능을 막되 **설정 화면으로 가는 다음 행동**을 함께 준다(§4 함정 3).
  noLockSet,

  /// 사용자가 취소했거나 인증에 실패했다.
  failed,
}

/// 등록 변경 보호(사전 A′·ADR-21)에 쓰는 본인 확인.
///
/// **세션 개시에는 쓰지 않는다.** 세션은 위임되는 권한이 0이라 인증으로 지킬 대상이
/// 없고, 조건으로 걸면 본인인증조차 어려운 주 타깃이 배제된다(ADR-17). 반면 보호자
/// 목록 변경은 지속적 자격을 부여하는 실제 권한 위임이라 게이트가 정당하다.
///
/// 생체 전용을 강제하지 않는다(`biometricOnly: false`) — 지문을 등록하지 않은
/// 어르신이 많고, 잠금 자격증명(PIN·패턴)도 "이 폰의 주인"을 증명하기 때문이다.
class ElderAuth {
  ElderAuth({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  Future<ElderAuthResult> confirm(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return ElderAuthResult.noLockSet;
      final ok = await _auth.authenticate(
        localizedReason: reason,
        // local_auth 3.x는 옵션이 평탄화돼 있고 stickyAuth가 이 이름으로 바뀌었다.
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      return ok ? ElderAuthResult.ok : ElderAuthResult.failed;
    } catch (_) {
      return ElderAuthResult.failed;
    }
  }
}
