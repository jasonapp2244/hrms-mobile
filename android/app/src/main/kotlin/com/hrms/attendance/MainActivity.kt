package com.hrms.attendance

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    /**
     * Creates the channel the server addresses its notifications to.
     *
     * From Android 8 a notification naming a channel that does not exist is
     * dropped in complete silence — nothing shown, nothing logged, and the FCM
     * send still reports success. The server sets `channel_id` from
     * `config/fcm.php` (`hrms_default` by default), so this id has to match
     * that value exactly.
     *
     * Done in Kotlin rather than by adding a notifications plugin to Flutter:
     * this is the only native call the app needs, and creating a channel is
     * idempotent, so running it on every launch also repairs the case where the
     * app was installed before this code existed.
     *
     * Importance HIGH because all three notifications are time-bound — a
     * clock-out reminder that waits silently for the person to open the app has
     * already failed at its job. The user can still turn it down in settings,
     * and Android remembers that choice over this value.
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            DEFAULT_CHANNEL_ID,
            "Attendance and leave",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Shift reminders, and decisions on your leave requests."
        }

        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    private companion object {
        /** Must match `FCM_ANDROID_CHANNEL` on the server. */
        const val DEFAULT_CHANNEL_ID = "hrms_default"
    }
}
