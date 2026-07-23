package com.ircmobile.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class IrcForegroundService : Service() {
    private var title = "Connected"
    private var text = "Connected"
    private var baseTitle = "Connected"
    private var baseText = "Connected"
    private var basePayload: String? = "radio"
    private var radioUrl = DEFAULT_RADIO_URL
    private var activeRadioUrl: String? = null
    private var radioPlaying = false
    private var notificationPayload: String? = "radio"
    private var alert = false
    private var alertKind: String? = null
    private var mediaPlayer: MediaPlayer? = null
    private var callRingtonePlayer: MediaPlayer? = null

    override fun onCreate() {
        super.onCreate()
        createChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopNativeRadio(status = "Stopped", userStopped = true)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RADIO_START -> {
                startOrUpdateForeground(buildNotification(alertSound = false))
                startNativeRadio()
                return START_STICKY
            }
            ACTION_RADIO_STOP -> {
                stopNativeRadio(status = "Stopped", userStopped = true)
                startOrUpdateForeground(buildNotification(alertSound = false))
                return START_STICKY
            }
            ACTION_CLEAR_ALERT -> {
                clearAlert(intent.getBooleanExtra(EXTRA_NOTIFY_DECLINE, false))
                return START_STICKY
            }
        }

        val incomingAlert = intent?.getBooleanExtra(EXTRA_ALERT, false) == true
        val incomingTitle = intent?.getStringExtra(EXTRA_TITLE)
        val incomingText = intent?.getStringExtra(EXTRA_TEXT)
        val incomingPayload = intent?.getStringExtra(EXTRA_PAYLOAD)
        val incomingAlertKind = intent?.getStringExtra(EXTRA_ALERT_KIND)
        if (incomingAlert) {
            title = incomingTitle ?: title
            text = incomingText ?: text
            if (intent?.hasExtra(EXTRA_PAYLOAD) == true) {
                notificationPayload = incomingPayload
            }
        } else {
            baseTitle = incomingTitle ?: baseTitle
            baseText = incomingText ?: baseText
            if (intent?.hasExtra(EXTRA_PAYLOAD) == true) {
                basePayload = incomingPayload ?: "radio"
            }
            title = baseTitle
            text = baseText
            notificationPayload = basePayload
        }
        radioUrl = intent?.getStringExtra(EXTRA_RADIO_URL)?.takeIf { it.isNotBlank() } ?: radioUrl
        if (intent?.hasExtra(EXTRA_ALERT) == true) {
            alert = incomingAlert
            alertKind = if (incomingAlert) incomingAlertKind else null
        }
        val alertSound = intent?.getBooleanExtra(EXTRA_ALERT_SOUND, false) == true
        if (intent?.hasExtra(EXTRA_RADIO_PLAYING) == true) {
            if (intent.getBooleanExtra(EXTRA_RADIO_PLAYING, false)) {
                startOrUpdateForeground(buildNotification(alertSound = alertSound))
                startNativeRadio()
            } else {
                stopNativeRadio(status = "Stopped", userStopped = true)
            }
        }

        startOrUpdateForeground(buildNotification(alertSound = alertSound))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopCallRingtone()
        stopNativeRadio(status = "Stopped", userStopped = true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)?.cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    private fun buildNotification(alertSound: Boolean = false): Notification {
        val isAlert = alert && !notificationPayload.isNullOrBlank() && notificationPayload != "radio"
        val isCallAlert = isAlert && alertKind == ALERT_KIND_CALL
        val shouldAlert = isAlert && alertSound
        if (isCallAlert) {
            if (shouldAlert) startCallRingtone()
        } else {
            stopCallRingtone()
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent.apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                notificationPayload?.takeIf { it.isNotBlank() }?.let {
                    putExtra(EXTRA_PAYLOAD, it)
                }
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val answerIntent = PendingIntent.getActivity(
            this,
            CALL_ANSWER_REQUEST_CODE,
            launchIntent.apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                notificationPayload?.takeIf { it.isNotBlank() }?.let {
                    putExtra(EXTRA_PAYLOAD, it)
                }
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val declineIntent = PendingIntent.getService(
            this,
            CALL_DECLINE_REQUEST_CODE,
            Intent(this, IrcForegroundService::class.java)
                .setAction(ACTION_CLEAR_ALERT)
                .putExtra(EXTRA_NOTIFY_DECLINE, true),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val actionIntent = PendingIntent.getService(
            this,
            if (radioPlaying) RADIO_STOP_REQUEST_CODE else RADIO_START_REQUEST_CODE,
            Intent(this, IrcForegroundService::class.java).setAction(
                if (radioPlaying) ACTION_RADIO_STOP else ACTION_RADIO_START,
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val actionIcon = if (radioPlaying) {
            R.drawable.ic_notification_stop
        } else {
            R.drawable.ic_notification_start
        }
        val clearAlertIntent = PendingIntent.getService(
            this,
            CLEAR_ALERT_REQUEST_CODE,
            Intent(this, IrcForegroundService::class.java)
                .setAction(ACTION_CLEAR_ALERT)
                .putExtra(EXTRA_NOTIFY_DECLINE, isCallAlert),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val smallIcon = R.drawable.ic_notification_irc

        val notificationChannelId = when {
            isCallAlert -> CALL_CHANNEL_ID
            isAlert -> ALERT_CHANNEL_ID
            else -> CHANNEL_ID
        }
        val builder = NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(contentIntent)
            .setShowWhen(false)
            .setLocalOnly(true)
            .setOngoing(!isAlert)
            .setAutoCancel(isAlert)
            .setOnlyAlertOnce(!isAlert)
            .setSilent(isCallAlert || !shouldAlert)
            .setCategory(
                when {
                    isCallAlert -> NotificationCompat.CATEGORY_CALL
                    isAlert -> NotificationCompat.CATEGORY_MESSAGE
                    else -> NotificationCompat.CATEGORY_SERVICE
                },
            )
            .setPriority(
                when {
                    isCallAlert -> NotificationCompat.PRIORITY_MAX
                    isAlert -> NotificationCompat.PRIORITY_HIGH
                    else -> NotificationCompat.PRIORITY_LOW
                },
            )
        if (isCallAlert) {
            builder
                // Keep the notification itself silent. Incoming calls are rung
                // by the manual MediaPlayer below, so Android will not replace
                // it with the short notification ding from the channel.
                .setDefaults(0)
                .setVibrate(longArrayOf(0L, 650L, 350L, 650L))
                .setFullScreenIntent(contentIntent, shouldAlert)
                .addAction(R.drawable.ic_notification_start, "Answer", answerIntent)
                .addAction(R.drawable.ic_notification_stop, "Decline", declineIntent)
        } else {
            builder
                .setDefaults(if (shouldAlert) Notification.DEFAULT_SOUND else 0)
                .addAction(
                    actionIcon,
                    if (radioPlaying) "Stop radio" else "Start radio",
                    actionIntent,
                )
        }
        if (isAlert) {
            builder.setDeleteIntent(clearAlertIntent)
        }
        return builder.build()
    }

    private fun clearAlert(notifyDecline: Boolean = false) {
        val declinedCallPayload =
            if (notifyDecline && alertKind == ALERT_KIND_CALL) notificationPayload else null
        stopCallRingtone()
        alert = false
        alertKind = null
        title = baseTitle
        text = baseText
        notificationPayload = basePayload
        ForegroundBridge.foregroundMessagesDismissed()
        declinedCallPayload
            ?.takeIf { it.isNotBlank() && it != "radio" }
            ?.let { ForegroundBridge.foregroundSelection("call-decline:$it") }
        startOrUpdateForeground(buildNotification(alertSound = false))
    }

    private fun startCallRingtone() {
        val current = callRingtonePlayer
        if (current?.isPlaying == true) return

        val player = MediaPlayer()
        var fallbackAfd: android.content.res.AssetFileDescriptor? = null
        try {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            player.setAudioAttributes(attributes)

            val ringtoneUri =
                RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            val systemRingtoneReady = ringtoneUri != null && runCatching {
                player.setDataSource(this, ringtoneUri)
            }.isSuccess
            if (!systemRingtoneReady) {
                player.reset()
                player.setAudioAttributes(attributes)
                val afd = resources.openRawResourceFd(R.raw.irc_call_ring)
                fallbackAfd = afd
                player.setDataSource(
                    afd.fileDescriptor,
                    afd.startOffset,
                    afd.length,
                )
            }

            player.isLooping = true
            player.setVolume(1.0f, 1.0f)
            player.prepare()
            player.start()
            callRingtonePlayer = player
        } catch (_: Exception) {
            runCatching { player.release() }
        } finally {
            runCatching { fallbackAfd?.close() }
        }
    }

    private fun stopCallRingtone() {
        val player = callRingtonePlayer ?: return
        callRingtonePlayer = null
        runCatching { player.stop() }
        runCatching { player.reset() }
        runCatching { player.release() }
    }

    private fun startNativeRadio() {
        if (radioPlaying && mediaPlayer != null && activeRadioUrl == radioUrl) return
        stopNativeRadio(notifyDart = false)
        radioPlaying = true
        activeRadioUrl = radioUrl
        ForegroundBridge.radioStateChanged(radioPlaying = true, status = "Connecting", userStopped = false)
        var player: MediaPlayer? = null
        try {
            val newPlayer = MediaPlayer()
            player = newPlayer
            mediaPlayer = newPlayer
            newPlayer.apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                setDataSource(radioUrl)
                setOnPreparedListener {
                    if (mediaPlayer != it) return@setOnPreparedListener
                    it.start()
                    radioPlaying = true
                    ForegroundBridge.radioStateChanged(radioPlaying = true, status = "On air", userStopped = false)
                    startOrUpdateForeground(buildNotification(alertSound = false))
                }
                setOnErrorListener { failedPlayer, _, _ ->
                    if (mediaPlayer != failedPlayer) return@setOnErrorListener true
                    stopNativeRadio(status = "Stream error", userStopped = false)
                    if (!alert) {
                        text = "Stream error"
                    }
                    startOrUpdateForeground(buildNotification(alertSound = false))
                    true
                }
                prepareAsync()
            }
        } catch (_: Exception) {
            if (mediaPlayer == player) {
                mediaPlayer = null
            }
            player?.let { releaseNativeRadioPlayer(it) }
            stopNativeRadio(status = "Stream error", userStopped = false)
        }
    }

    private fun stopNativeRadio(
        status: String = "Stopped",
        userStopped: Boolean = true,
        notifyDart: Boolean = true,
    ) {
        val player = mediaPlayer
        mediaPlayer = null
        activeRadioUrl = null
        radioPlaying = false
        if (player != null) {
            releaseNativeRadioPlayer(player)
        }
        if (notifyDart) {
            ForegroundBridge.radioStateChanged(radioPlaying = false, status = status, userStopped = userStopped)
        }
    }

    private fun releaseNativeRadioPlayer(player: MediaPlayer) {
        runCatching { player.setOnPreparedListener(null) }
        runCatching { player.setOnErrorListener(null) }
        runCatching { player.stop() }
        runCatching { player.reset() }
        runCatching { player.release() }
    }

    private fun startOrUpdateForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "IRC mobile",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps IRC mobile connected in the background"
            setShowBadge(false)
        }
        val alertChannel = NotificationChannel(
            ALERT_CHANNEL_ID,
            "IRC messages",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Direct messages and channel highlights"
            setShowBadge(false)
            setSound(
                RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            enableVibration(true)
        }
        val callChannel = NotificationChannel(
            CALL_CHANNEL_ID,
            "IRC calls",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Incoming IRC voice and video calls"
            setShowBadge(false)
            // The channel stays silent on purpose. The service plays the
            // bundled ringing WAV in a loop, which behaves like a call ringtone
            // instead of the one-shot notification sound.
            setSound(null, null)
            enableVibration(true)
        }
        getSystemService(NotificationManager::class.java).apply {
            createNotificationChannel(channel)
            createNotificationChannel(alertChannel)
            createNotificationChannel(callChannel)
        }
    }

    companion object {
        private const val CHANNEL_ID = "irc_connection_status"
        private const val ALERT_CHANNEL_ID = "irc_foreground_message_alerts_v2"
        private const val CALL_CHANNEL_ID = "irc_call_ringing_manual_v2"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "com.ircmobile.app.action.STOP_FOREGROUND"
        private const val ACTION_RADIO_START = "com.ircmobile.app.action.RADIO_START"
        private const val ACTION_RADIO_STOP = "com.ircmobile.app.action.RADIO_STOP"
        private const val ACTION_CLEAR_ALERT = "com.ircmobile.app.action.CLEAR_ALERT"
        private const val RADIO_START_REQUEST_CODE = 7011
        private const val RADIO_STOP_REQUEST_CODE = 7012
        private const val CLEAR_ALERT_REQUEST_CODE = 7013
        private const val CALL_ANSWER_REQUEST_CODE = 7014
        private const val CALL_DECLINE_REQUEST_CODE = 7015
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_RADIO_PLAYING = "radioPlaying"
        private const val EXTRA_RADIO_URL = "radioUrl"
        const val EXTRA_PAYLOAD = "foregroundPayload"
        private const val EXTRA_ALERT = "alert"
        private const val EXTRA_ALERT_SOUND = "alertSound"
        private const val EXTRA_ALERT_KIND = "alertKind"
        private const val EXTRA_NOTIFY_DECLINE = "notifyDecline"
        private const val ALERT_KIND_CALL = "call"
        private const val DEFAULT_RADIO_URL = "https://29103.live.streamtheworld.com/SUPER_FM.mp3"

        fun clearAlert(context: Context) {
            val intent = Intent(context.applicationContext, IrcForegroundService::class.java).apply {
                action = ACTION_CLEAR_ALERT
            }
            ContextCompat.startForegroundService(context.applicationContext, intent)
        }

        fun start(
            context: Context,
            title: String,
            text: String,
            radioPlaying: Boolean?,
            radioUrl: String?,
            payload: String?,
            alert: Boolean,
            alertSound: Boolean,
            alertKind: String?,
        ) {
            val intent = Intent(context.applicationContext, IrcForegroundService::class.java).apply {
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                if (radioPlaying != null) putExtra(EXTRA_RADIO_PLAYING, radioPlaying)
                if (radioUrl != null) putExtra(EXTRA_RADIO_URL, radioUrl)
                putExtra(EXTRA_PAYLOAD, payload ?: "radio")
                putExtra(EXTRA_ALERT, alert)
                putExtra(EXTRA_ALERT_SOUND, alertSound)
                if (alertKind != null) putExtra(EXTRA_ALERT_KIND, alertKind)
            }
            ContextCompat.startForegroundService(context.applicationContext, intent)
        }
    }
}
