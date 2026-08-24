/// 온기 전역 상수. 모델 정보는 결과보고서 붙임2와 일치해야 한다.
class OngiConfig {
  OngiConfig._();

  /// Gemma 4 E2B 온디바이스 배포본 (Apache 2.0, 게이트 없음 — 토큰 불필요).
  static const modelRepo = 'litert-community/gemma-4-E2B-it-litert-lm';

  /// HF API 실측 확정(2026-07-11). 다운로드 완료 검증은 파일 크기 대조로 한다
  /// (isModelInstalled는 부분 다운로드를 설치됨으로 오탐한 이력 있음).
  static const modelFileName = 'gemma-4-E2B-it.litertlm';
  static const modelSizeBytes = 2588147712;
  static const modelSha256 =
      '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c';
  static const modelUrl =
      'https://huggingface.co/$modelRepo/resolve/main/$modelFileName';

  /// LLM 컨텍스트 윈도 (.litertlm 최소 1024 — 미만이면 자동 클램프).
  static const maxTokens = 2048;

  /// 응답 길이 상한 — 분류·의도 해석은 짧은 응답이면 충분.
  static const maxOutputTokens = 256;

  /// RAM 게이팅 임계(기획설계서 §4.3 표 — W1 실측 후 조정 예정).
  /// 미만이면 경량 모드(LLM off) / cpuTier 미만이면 CPU / 이상이면 GPU 시도.
  static const lightModeMaxRamMb = 4096;
  static const cpuTierMaxRamMb = 6144;

  /// 모델 다운로드 사전 체크 — 필요 가용 저장공간 약 3.6GB(§4.3).
  static const requiredFreeStorageBytes = 3865470566;

  /// 음성(§6): TTS 속도 — Android 표준 1.0, 고령자 시작점 0.75.
  /// 설정 화면 슬라이더로 [ttsRateMin]~[ttsRateMax] 범위에서 조절·저장한다.
  static const ttsSpeechRate = 0.75;
  static const ttsRateMin = 0.5;
  static const ttsRateMax = 1.2;
  static const ttsRateSettingKey = 'tts_rate';

  /// STT listen 파라미터(§6) — pauseFor는 Android 미적용 전제(무음 컷오프 1~3초).
  static const sttListenSeconds = 25;
  static const sttPauseSeconds = 5;

  /// 보호자 통화 코칭(docs/50_guardian_coaching.md) 릴레이 서버 주소를 담는 설정 키.
  /// 서버는 요청 전달과 WebRTC 시그널링만 하고 어르신 데이터를 보관하지 않는다(§10).
  ///
  /// **주소를 코드에 박지 않는다.** 값은 기기 설정(보호자 등록 화면)에서만 들어오고,
  /// 비어 있으면 릴레이에 접속하지 않는다. 박아 두면 (a) 공개 저장소에 사내 주소가
  /// 남고, (b) 코칭을 쓰지 않는 모든 기기가 그 주소로 영구 재시도를 돌리며,
  /// (c) 환경이 바뀔 때마다 APK를 다시 말아야 한다.
  static const coachingRelaySettingKey = 'coaching_relay_url';

  /// 이 기기의 인스턴스 키 — 등록 시 보호자와 교환하는 신뢰 앵커(ADR-21).
  static const deviceKeySettingKey = 'device_key';

  /// 역할(어르신/보호자) — 온기 1개 앱에 두 모드를 둔다(ADR-20).
  static const roleSettingKey = 'role';
  static const roleElder = 'elder';
  static const roleGuardian = 'guardian';
}

/// 생활 카테고리 — 앱 분류와 런처 타일의 기준. 선언 순서 = 런처 타일 순서.
/// v2(2026-07-13): 금융을 은행/카드·페이/증권·보험으로 분리하고 동영상·음악,
/// SNS·커뮤니티, 게임, 인터넷·도구를 신설한 14종(기타 잔류 최소화). 이름 변경
/// 시 DB v3 마이그레이션(core/db.dart)과 함께 갱신할 것 — 구 이름은 폴백 처리.
enum LifeCategory {
  phone('전화·메시지'),
  bank('은행'),
  card('카드·페이'),
  invest('증권·보험'),
  transport('교통'),
  shopping('쇼핑·배달'),
  publicService('공공서비스'),
  health('의료·건강'),
  photo('사진·앨범'),
  media('동영상·음악'),
  sns('SNS·커뮤니티'),
  game('게임'),
  tools('인터넷·도구'),
  etc('기타');

  const LifeCategory(this.label);

  final String label;
}
