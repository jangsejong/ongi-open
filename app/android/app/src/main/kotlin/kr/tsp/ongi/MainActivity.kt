package kr.tsp.ongi

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.app.ActivityManager
import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Process
import android.os.StatFs
import android.provider.AlarmClock
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        AppScanApi.setUp(messenger, AppScanApiImpl(applicationContext))
        DeviceStatsApi.setUp(messenger, DeviceStatsApiImpl(applicationContext, this))
        IntentActionsApi.setUp(messenger, IntentActionsApiImpl(applicationContext))
        UsageStatsApi.setUp(messenger, UsageStatsApiImpl(applicationContext))
        CoachingApi.setUp(messenger, CoachingApiImpl(applicationContext))
    }
}

/**
 * 보호자 통화 코칭 네이티브 지원(docs/50_guardian_coaching.md).
 *
 * 화면 캡처 자체는 flutter_webrtc의 getDisplayMedia가 OS 동의 다이얼로그와 함께
 * 처리한다. 여기서는 Android 14+가 요구하는 FGS 수명과, 민감 화면 3단 정책(§6)
 * 판정에 쓸 포그라운드 앱 조회만 맡는다. **기기 상태를 바꾸는 메서드는 없다**(ADR-16).
 */
class CoachingApiImpl(private val context: Context) : CoachingApi {
    override fun startShareService(): Boolean = try {
        ShareForegroundService.start(context)
        true
    } catch (_: Exception) {
        false
    }

    override fun stopShareService() {
        try {
            ShareForegroundService.stop(context)
        } catch (_: Exception) {
        }
    }

    override fun foregroundPackage(): String {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
            ?: return ""
        val now = System.currentTimeMillis()
        // 감지 지연이 그대로 민감 화면 노출 시간이 된다(§6·리스크 #15) — 조회 창을
        // 짧게 잡고, 창 안에 전환 이벤트가 없으면 직전 판정을 유지하도록 빈 값을 준다.
        return try {
            val events = usm.queryEvents(now - LOOKBACK_MS, now)
            val event = UsageEvents.Event()
            var latest = ""
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED) {
                    latest = event.packageName
                }
            }
            latest
        } catch (_: Exception) {
            ""
        }
    }

    private companion object {
        const val LOOKBACK_MS = 10_000L
    }
}

/** 무권한 표준 인텐트 화이트리스트(§4.2) — LLM은 액션 ID만 고르고 인텐트는 여기서 조립. */
class IntentActionsApiImpl(private val context: Context) : IntentActionsApi {
    private fun start(intent: Intent): Boolean = try {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    override fun openDialer(): Boolean = start(Intent(Intent.ACTION_DIAL))

    override fun openSmsComposer(): Boolean =
        start(Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:")))

    override fun openCamera(): Boolean =
        start(Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA))

    override fun openGallery(): Boolean =
        start(
            Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_GALLERY),
        )

    override fun showAlarms(): Boolean = start(Intent(AlarmClock.ACTION_SHOW_ALARMS))

    override fun requestUninstall(packageName: String): Boolean =
        // 시스템 확인 다이얼로그 필수 경유 — 앱이 직접 삭제하지 않는다(§3 ④).
        start(Intent(Intent.ACTION_DELETE, Uri.parse("package:$packageName")))

    override fun openSecuritySettings(): Boolean =
        // 잠금 미설정이면 보호자 등록 변경 보호(사전 A′)가 성립하지 않는다.
        // 기능을 막고 끝내지 않고 다음 행동을 준다(CG1 — 원인+해결).
        start(Intent(Settings.ACTION_SECURITY_SETTINGS))

    override fun openNotificationSettings(): Boolean {
        // 알림 권한을 두 번 거부하면 앱에서는 다시 물을 수 없다 — 설정으로 보내는
        // 것이 남는 유일한 경로다(CG1). 채널별 화면이 없는 구형은 앱 정보로 폴백.
        if (Build.VERSION.SDK_INT >= 26) {
            val direct = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            if (start(direct)) return true
        }
        return start(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}"),
            ),
        )
    }
}

/** 사용 패턴 세션화(§4.2 루틴) — PACKAGE_USAGE_STATS 특수 권한 필요. */
class UsageStatsApiImpl(private val context: Context) : UsageStatsApi {
    override fun isUsageAccessGranted(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= 29) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName,
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName,
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    override fun openUsageAccessSettings() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    override fun queryUsageSessions(startMs: Long, endMs: Long): List<UsageSessionNative> {
        val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(startMs, endMs)
        val event = UsageEvents.Event()
        val resumedAt = HashMap<String, Long>()
        val sessions = ArrayList<UsageSessionNative>()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            // ACTIVITY_RESUMED/PAUSED(API 29+)는 MOVE_TO_FOREGROUND/BACKGROUND(API<29)와
            // 같은 정수값(1/2) — 구형 기기 이벤트도 동일 분기로 처리된다.
            when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED ->
                    resumedAt[event.packageName] = event.timeStamp
                UsageEvents.Event.ACTIVITY_PAUSED -> {
                    val start = resumedAt.remove(event.packageName) ?: continue
                    if (event.timeStamp > start) {
                        sessions.add(UsageSessionNative(event.packageName, start, event.timeStamp))
                    }
                }
                UsageEvents.Event.DEVICE_SHUTDOWN -> {
                    // PAUSED 없이 전원이 꺼지면 열린 세션이 다음 조회 끝까지 부풀어
                    // 사용 시간이 왜곡된다(밤샘 12시간 세션) — 종료 시점에 마감.
                    for ((pkg, start) in resumedAt) {
                        if (event.timeStamp > start) {
                            sessions.add(UsageSessionNative(pkg, start, event.timeStamp))
                        }
                    }
                    resumedAt.clear()
                }
            }
        }
        // 조회 구간 끝에 아직 열려 있던 세션은 endMs로 마감.
        for ((pkg, start) in resumedAt) {
            if (endMs > start) sessions.add(UsageSessionNative(pkg, start, endMs))
        }
        return sessions
    }
}

/** 앱 스캔 — <queries> MAIN+LAUNCHER 범위(QUERY_ALL_PACKAGES 불사용, ADR-3). */
class AppScanApiImpl(private val context: Context) : AppScanApi {
    override fun getInstalledApps(): List<NativeAppInfo> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val pm = context.packageManager
        return pm.queryIntentActivities(intent, 0)
            .map {
                val pkg = it.activityInfo.packageName
                NativeAppInfo(
                    packageName = pkg,
                    label = it.loadLabel(pm).toString(),
                    // 미사용 앱 정리 기산점 — 조회 실패 시 0(기존 사용기록 기준으로 폴백).
                    firstInstallMs = try {
                        pm.getPackageInfo(pkg, 0).firstInstallTime
                    } catch (_: Exception) {
                        0L
                    },
                )
            }
            .distinctBy { it.packageName }
            .sortedBy { it.label }
    }

    override fun launchApp(packageName: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return true
    }

    override fun getAppIcon(packageName: String): ByteArray? {
        return try {
            // AdaptiveIconDrawable 포함 모든 Drawable 대응 — 캔버스에 직접 그린다.
            val drawable = context.packageManager.getApplicationIcon(packageName)
            val bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, canvas.width, canvas.height)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (_: Exception) {
            null
        }
    }

    private companion object {
        const val ICON_PX = 96
    }
}

/** 메모리·저장공간·네트워크 — RAM 게이팅과 모델 다운로드 사전 체크(기획설계서 §4.3). */
class DeviceStatsApiImpl(
    private val context: Context,
    private val activity: Activity,
) : DeviceStatsApi {
    override fun getMemoryInfo(): MemInfo {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        val pssKb = am.getProcessMemoryInfo(intArrayOf(Process.myPid()))[0].totalPss
        return MemInfo(
            totalMemMb = mi.totalMem / (1024L * 1024L),
            availMemMb = mi.availMem / (1024L * 1024L),
            appPssMb = pssKb / 1024L,
            lowRamDevice = am.isLowRamDevice,
        )
    }

    override fun getFreeStorageBytes(): Long = StatFs(context.filesDir.path).availableBytes

    override fun isOnWifi(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    }

    /** [canRequestPostNotifications]의 영구 거부 판별용 요청 이력. */
    private val permPrefs
        get() = context.getSharedPreferences("ongi_permissions", Context.MODE_PRIVATE)

    override fun requestPostNotifications() {
        // 여기서는 요청만 던지고 이력을 남긴다. 팝업이 뜰 수 없는 상태의 대안은
        // 호출부(화면)가 맥락에 맞게 정한다 — "알림 켜기"는 설정 딥링크로 보내야
        // 하지만, 모델 다운로드 시작에서 설정 화면이 열리면 그게 더 큰 사고다.
        // 그래서 v0.0.28의 일괄 설정 폴백을 canRequestPostNotifications 사전 판별로
        // 바꿨다(호출 전에 물을 것).
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            permPrefs.edit().putBoolean(KEY_ASKED_POST_NOTI, true).apply()
            ActivityCompat.requestPermissions(
                activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTI,
            )
        }
    }

    /**
     * 지금 [requestPostNotifications]가 시스템 팝업을 실제로 띄울 수 있는가.
     *
     * 영구 거부(2회 거부) 상태의 요청은 UI 없이 즉시 거부되므로, 그 상태에서
     * 요청만 던지면 "알림 켜기"를 눌렀는데 아무 일도 없는 막다른 탭이 된다(CG1).
     * 영구 거부와 "아직 한 번도 안 물음"은 둘 다 rationale이 false라 시스템만으로는
     * 구분할 수 없다 — 요청 이력을 스스로 남겨 가른다(요청을 보낸 적이 있는데
     * rationale도 필요 없다면 남은 것은 영구 거부뿐이다).
     */
    override fun canRequestPostNotifications(): Boolean {
        // Android 12 이하는 런타임 권한 자체가 없다 — 차단은 설정으로만 풀린다.
        if (Build.VERSION.SDK_INT < 33) return false
        if (ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            // 이미 허용 — 요청할 것이 없다(채널만 끈 상태도 설정으로만 풀린다).
            return false
        }
        // 1회 거부 상태는 rationale이 참이고, 이때는 확실히 다시 물을 수 있다.
        if (ActivityCompat.shouldShowRequestPermissionRationale(
                activity, Manifest.permission.POST_NOTIFICATIONS,
            )
        ) {
            return true
        }
        return !permPrefs.getBoolean(KEY_ASKED_POST_NOTI, false)
    }

    /**
     * 묻는 것은 "권한이 있는가"가 아니라 **"공유 중 상시 알림이 실제로 뜨는가"**다.
     *
     * 그 알림은 캡처를 멈춘 뒤 앱으로 돌아오는 유일한 경로라(50_ §7), 뜨지 않는데
     * 뜬다고 답하면 안내 카드까지 함께 잠겨 복구 수단이 사라진다. 권한만 보면 두
     * 상태를 놓친다: minSdk 24라 런타임 권한이 없는 API 24~32 기기의 앱 단위 차단,
     * 그리고 13+에서 권한은 그대로 둔 채 이 채널만 끈 경우.
     */
    override fun isPostNotificationsGranted(): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26) {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = manager.getNotificationChannel(ShareForegroundService.CHANNEL_ID)
            // 채널은 첫 공유 때 만들어진다 — 아직 없으면 막힌 것이 아니다.
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) {
                return false
            }
        }
        return true
    }

    private companion object {
        const val REQ_POST_NOTI = 820
        const val KEY_ASKED_POST_NOTI = "asked_post_notifications"
    }
}
