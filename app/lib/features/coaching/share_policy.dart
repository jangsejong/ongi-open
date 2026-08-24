import '../../core/config.dart';

/// 화면 공유 중 민감 화면 3단 정책(50_guardian_coaching.md §6 · ADR-19).
///
/// - [blocked]  은행 이체·송금·결제·증권 — **전면 차단, 재동의 경로를 만들지 않는다.**
/// - [reconsent] 인증(PASS)·정부24·병원·공공 — 자동 가리기 후 어르신 재동의 1탭으로 재개.
///               본인인증 코칭이 이 기능의 첫 과업이므로 여기는 열려 있어야 한다(§2).
/// - [allowed]  그 외 — 코칭 대상 일반 화면.
enum SharePolicy {
  allowed,
  reconsent,
  blocked;

  /// 어르신에게 보여줄 가리기 사유. [allowed]는 가리지 않으므로 빈 문자열.
  String get reason => switch (this) {
        SharePolicy.allowed => '',
        SharePolicy.reconsent => '개인 정보가 있는 화면이에요.',
        SharePolicy.blocked => '돈과 관련된 화면이에요.',
      };

  /// 가린 뒤 어르신에게 제시할 다음 행동(CG1 — 원인+해결).
  String get guidance => switch (this) {
        SharePolicy.allowed => '',
        SharePolicy.reconsent => '보여드려도 괜찮으면 아래를 눌러 주세요.',
        SharePolicy.blocked => '돈 보내는 일은 통화를 끊고 은행이나 가족과 만나서 하세요.',
      };
}

/// 앱 하나에 대한 공유 정책 판정 — 순수 함수(단위 테스트 대상).
///
/// 판정 순서가 안전성을 좌우한다:
/// 1. 카테고리가 금융이면 즉시 [SharePolicy.blocked].
/// 2. 규칙 사각지대(기타·도구 등)라도 라벨·패키지에 금융 신호가 있으면 blocked.
///    분류가 아직 안 된 은행 앱이 그대로 노출되는 구멍을 막는 **default-deny** 장치다.
/// 3. 인증·공공·의료면 [SharePolicy.reconsent].
/// 4. 나머지는 [SharePolicy.allowed].
SharePolicy sharePolicyFor({
  required LifeCategory category,
  required String packageName,
  required String label,
}) {
  if (_blockedCategories.contains(category)) return SharePolicy.blocked;

  final haystack = '$packageName $label'.toLowerCase();
  for (final keyword in _financeSignals) {
    if (haystack.contains(keyword)) return SharePolicy.blocked;
  }

  if (_reconsentCategories.contains(category)) return SharePolicy.reconsent;
  return SharePolicy.allowed;
}

/// 송금·이체·결제가 일어나는 칸 — 경제적 착취 경로를 닫는다(§11).
const _blockedCategories = {
  LifeCategory.bank,
  LifeCategory.card,
  LifeCategory.invest,
};

/// 본인인증·행정·의료 — 코칭 목적상 열려 있어야 하되 매번 어르신 동의를 받는다.
/// PASS 3사(`com.sktelecom.tauth`·`com.kt.ktauth`·`com.lguplus.smartotp`)와
/// 정부24(`kr.go.minwon.m`)는 CategoryRules에서 이미 publicService로 확정돼 있다.
const _reconsentCategories = {
  LifeCategory.publicService,
  LifeCategory.health,
};

/// 카테고리가 아직 확정되지 않은 앱을 위한 보조 신호. CategoryRules의
/// bank·card·invest 라벨 키워드와 금융권 패키지 관용 접두어에서 가져왔다.
/// 오탐(일반 앱을 금융으로 판정)은 화면이 가려질 뿐이라 손실이 작고,
/// 미탐(금융 앱을 놓침)은 곧바로 금전 피해로 이어지므로 넓게 잡는다.
const _financeSignals = [
  '은행', '뱅크', '뱅킹', '금융', '카드', '페이', '결제', '월렛', '머니',
  '증권', '주식', '투자', '보험', '자산', '송금', '이체', '계좌',
  'bank', 'card', 'pay', 'wallet', 'money', 'finance', 'invest',
];
