// pigeon 스키마 — 수정 후 코드젠:
//   dart run pigeon --input pigeons/ongi_native.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/native/ongi_native.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/kr/tsp/ongi/OngiNative.g.kt',
    kotlinOptions: KotlinOptions(package: 'kr.tsp.ongi'),
    dartPackageName: 'ongi',
  ),
)
class NativeAppInfo {
  NativeAppInfo({
    required this.packageName,
    required this.label,
    required this.firstInstallMs,
  });
  String packageName;
  String label;

  /// PackageManager.firstInstallTime — 미사용 앱 정리의 기산점(§3 ④).
  /// 설치 직후라 사용 기록이 없는 앱이 "오래 안 쓴 앱"으로 오르는 것을 막는다.
  int firstInstallMs;
}

class MemInfo {
  MemInfo({
    required this.totalMemMb,
    required this.availMemMb,
    required this.appPssMb,
    required this.lowRamDevice,
  });
  int totalMemMb;
  int availMemMb;
  int appPssMb;
  bool lowRamDevice;
}

/// 설치 앱 조회·실행 — `<queries>` MAIN+LAUNCHER 범위(QUERY_ALL_PACKAGES 불사용).
@HostApi()
abstract class AppScanApi {
  List<NativeAppInfo> getInstalledApps();
  bool launchApp(String packageName);

  /// 앱 아이콘 PNG 바이트 (기기 밖 전송 없음 — 런처 표시용, 없으면 null).
  Uint8List? getAppIcon(String packageName);
}

/// 메모리 통계 — RAM 게이팅·모델 로드 벤치용.
@HostApi()
abstract class DeviceStatsApi {
  MemInfo getMemoryInfo();

  /// 앱 데이터 파티션 가용 용량 — 모델 다운로드 사전 체크(§4.3, 3.6GB 기준).
  int getFreeStorageBytes();

  /// 활성 네트워크가 Wi-Fi인지 — 다운로드 동의 화면의 요금 경고용.
  bool isOnWifi();

  /// Android 13+ 알림 권한 요청 — foreground 다운로드 진행률 알림(§4.3)과
  /// 화면 공유 상시 알림(50_ §7)이 이 권한 위에 선다. 결과 콜백 없음.
  /// **팝업을 띄울 수 없는 상태에서는 아무 일도 하지 않으므로**, 호출 전에
  /// [canRequestPostNotifications]로 묻고 불가면 호출부가 맥락에 맞는 대안을
  /// 정한다 — "알림 켜기"류 사용자 의도 경로는 설정 딥링크로, 모델 다운로드
  /// 같은 기회성 요청은 건너뛰기로(조용한 무반응 탭은 막다른 길이다, CG1).
  void requestPostNotifications();

  /// 지금 [requestPostNotifications]가 **시스템 팝업을 실제로 띄울 수 있는가.**
  /// Android 12 이하(런타임 권한 없음)·이미 허용됨·영구 거부(2회 거부)는 false.
  /// 영구 거부와 "아직 한 번도 안 물음"은 시스템이 구분해 주지 않으므로
  /// shouldShowRequestPermissionRationale + 요청 이력(영속 플래그)으로 가른다.
  bool canRequestPostNotifications();

  /// 알림 권한이 실제로 있는가. [requestPostNotifications]는 결과를 돌려주지 않고
  /// **2회 거부 뒤에는 호출해도 아무 일이 없으므로**, 상태를 따로 물어야 화면이
  /// "알림이 꺼져 있다"를 말해 줄 수 있다(50_ §7 가시성).
  /// Android 12 이하는 권한 자체가 없어 항상 true.
  bool isPostNotificationsGranted();
}

/// 무권한 표준 인텐트(§4.1 intent_actions_api) — LLM이 아니라 여기(화이트리스트)가
/// 인텐트를 조립한다(§4.2). startActivity는 패키지 가시성 제한의 예외라
/// `<queries>` 추가 선언이 필요 없다. 실패(처리 앱 없음) 시 false.
@HostApi()
abstract class IntentActionsApi {
  /// 전화 걸기 화면(ACTION_DIAL — 즉시 발신 아님, 오발신 방지 §4.2).
  bool openDialer();

  /// 문자 작성 화면(ACTION_SENDTO smsto:).
  bool openSmsComposer();

  /// 카메라(정지영상 모드).
  bool openCamera();

  /// 갤러리(CATEGORY_APP_GALLERY 기본 앱).
  bool openGallery();

  /// 알람 목록(ACTION_SHOW_ALARMS).
  bool showAlarms();

  /// 앱 삭제 안내(ACTION_DELETE) — 시스템 확인 다이얼로그 필수 경유, 우회 불가(§3 ④).
  bool requestUninstall(String packageName);

  /// 기기 잠금 설정 화면(ACTION_SECURITY_SETTINGS) — 잠금 미설정이면 보호자 등록
  /// 변경 보호(사전 A′)가 성립하지 않으므로, 막다른 길 대신 다음 행동을 준다.
  bool openSecuritySettings();

  /// 이 앱의 알림 설정 화면(ACTION_APP_NOTIFICATION_SETTINGS). 알림 권한은 2회
  /// 거부하면 앱에서 다시 물을 수 없으므로, 그때 남는 유일한 경로다.
  bool openNotificationSettings();
}

/// 보호자 통화 코칭(v1.2 — docs/50_guardian_coaching.md) 네이티브 지원.
///
/// 화면 캡처 자체는 flutter_webrtc의 getDisplayMedia가 담당하고(OS 동의
/// 다이얼로그 포함), 여기서는 Android 14+가 요구하는 `mediaProjection`
/// foreground service 수명과 민감 화면 판정용 포그라운드 앱 조회만 맡는다.
@HostApi()
abstract class CoachingApi {
  /// 캡처 전에 FGS를 올린다. Android 14+는 이 서비스가 떠 있지 않으면
  /// MediaProjection 획득 자체가 실패한다. 공유 중 상시 알림도 이 서비스가 낸다.
  bool startShareService();

  void stopShareService();

  /// 지금 화면 앞에 있는 앱 패키지명 — 민감 화면 3단 정책 판정용(§6).
  /// 사용정보 접근 권한이 없거나 알 수 없으면 빈 문자열.
  /// **감지 지연이 그대로 노출 시간이 되므로** 짧은 조회 창을 쓴다.
  String foregroundPackage();
}

class UsageSessionNative {
  UsageSessionNative({
    required this.packageName,
    required this.startMs,
    required this.endMs,
  });
  String packageName;
  int startMs;
  int endMs;
}

/// 사용 패턴(§4.2 루틴) — UsageStatsManager queryEvents를 RESUMED/PAUSED 페어링으로
/// 세션화. PACKAGE_USAGE_STATS 특수 권한(설정 토글) 필요 — 없으면 축퇴 모드(§5).
@HostApi()
abstract class UsageStatsApi {
  bool isUsageAccessGranted();

  /// 설정의 사용정보 접근 화면으로 딥링크(ACTION_USAGE_ACCESS_SETTINGS).
  void openUsageAccessSettings();

  List<UsageSessionNative> queryUsageSessions(int startMs, int endMs);
}
