package kr.tsp.ongi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * 화면 공유 중 상시 foreground service(docs/50_guardian_coaching.md §10).
 *
 * 두 가지를 동시에 한다:
 * 1. Android 14+가 요구하는 `mediaProjection` 서비스 타입 제공 — 이 서비스가 떠 있지
 *    않으면 MediaProjection 획득 자체가 실패한다. flutter_webrtc의 getDisplayMedia를
 *    부르기 전에 반드시 시작해야 한다.
 * 2. 공유 중임을 숨길 수 없게 하는 상시 알림 — 어르신이 지금 화면이 나가고 있다는
 *    것을 언제든 확인하고 앱으로 돌아올 수 있어야 한다(§7 가시성).
 *
 * 알림은 사용자가 지울 수 없다(setOngoing). 코칭이 끝나면 앱이 중지시킨다.
 */
class ShareForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        // 프로세스가 죽어도 되살리지 않는다 — 세션이 끊기면 공유도 끝나야 한다(§11).
        return START_NOT_STICKY
    }

    /**
     * 최근 앱에서 밀어 제거해도 서비스는 남는다 — 그러면 공유는 이미 끝났는데
     * "화면을 보여드리고 있어요" 알림만 지울 수 없는 채로 남아 어르신이 아직
     * 보이는 줄 안다. 태스크가 사라지면 서비스도 함께 끝낸다.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun startForegroundCompat() {
        ensureChannel()
        val tapBack = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        // Notification.Builder(Context, String)은 API 26+다. minSdk가 24라 구형
        // 기기에서 NoSuchMethodError로 죽는다 — 채널을 아는 Compat 빌더를 쓴다.
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("지금 화면을 보여드리고 있어요")
            .setContentText("끝내려면 눌러서 온기로 돌아오세요")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(tapBack)
            .setOngoing(true)
            .build()

        // Android 14+는 화면 캡처 동의를 받은 뒤에야 mediaProjection 타입 FGS를
        // 허용한다. 그래서 호출부(ScreenShare.start)가 Helper.requestCapturePermission
        // 으로 동의를 **먼저** 받고 이 서비스를 올린다 — 순서를 되돌리면 여기서
        // SecurityException이 나고, 이어지는 캡처 획득은 플러그인 안쪽(포획 없는
        // ResultReceiver 콜백)에서 다시 터져 앱이 통째로 죽는다.
        // 그래도 거부당하는 경우를 대비해 프로세스가 죽지 않게 받아서 스스로
        // 종료한다. startForeground 5초 계약은 stopSelf로 해소되고, 공유 시작은
        // 호출부에서 실패로 처리된다. 실기기 확인은 docs/50 §14.
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            stopSelf()
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "보호자에게 화면 보여주기",
                // 소리 없이 계속 떠 있는 상태 알림 — 어르신을 놀라게 하지 않는다.
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    companion object {
        internal const val CHANNEL_ID = "ongi_screen_share"
        private const val NOTIFICATION_ID = 8201

        fun start(context: Context) {
            val intent = Intent(context, ShareForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ShareForegroundService::class.java))
        }
    }
}
