package com.ircmobile.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    companion object {
        private var retainedEngine: FlutterEngine? = null
        private var destroyEngineWithHost = false
        private const val REQUEST_PICK_LOCAL_IMAGE = 9201
    }

    private var activityChannel: MethodChannel? = null
    private var localImagePickResult: MethodChannel.Result? = null
    private var callRingbackTone: ToneGenerator? = null
    private var proximityWakeLock: PowerManager.WakeLock? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        captureForegroundSelection(intent)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return retainedEngine
    }

    override fun shouldDestroyEngineWithHost(): Boolean {
        return destroyEngineWithHost
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        retainedEngine = flutterEngine
        destroyEngineWithHost = false
        val appContext = applicationContext
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.ircmobile.app/activity"
        )
        activityChannel = channel
        ForegroundBridge.attach(channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                "startForeground" -> {
                    val title = call.argument<String>("title") ?: "Connected"
                    val text = call.argument<String>("text") ?: "Connected"
                    val radioPlaying = call.argument<Boolean>("radioPlaying")
                    val radioUrl = call.argument<String>("radioUrl")
                    val payload = call.argument<String>("payload")
                    val alert = call.argument<Boolean>("alert") ?: false
                    val alertSound = call.argument<Boolean>("alertSound") ?: false
                    val alertKind = call.argument<String>("alertKind")
                    IrcForegroundService.start(appContext, title, text, radioPlaying, radioUrl, payload, alert, alertSound, alertKind)
                    result.success(null)
                }
                "stopForeground" -> {
                    appContext.stopService(Intent(appContext, IrcForegroundService::class.java))
                    result.success(null)
                }
                "clearForegroundAlert" -> {
                    IrcForegroundService.clearAlert(appContext)
                    result.success(null)
                }
                "quitApp" -> {
                    retainedEngine = null
                    destroyEngineWithHost = true
                    appContext.stopService(Intent(appContext, IrcForegroundService::class.java))
                    result.success(null)
                    finishAndRemoveTask()
                    Handler(Looper.getMainLooper()).postDelayed({
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                            finishAndRemoveTask()
                        }
                    }, 150L)
                }
                "popForegroundSelection" -> {
                    result.success(ForegroundBridge.popForegroundSelection())
                }
                "pickLocalImage" -> {
                    pickLocalImage(result)
                }
                "setCallAudioRoute" -> {
                    val speaker = call.argument<Boolean>("speaker") ?: false
                    setCallAudioRoute(speaker)
                    result.success(null)
                }
                "clearCallAudioRoute" -> {
                    clearCallAudioRoute()
                    result.success(null)
                }
                "startCallRingback" -> {
                    startCallRingback()
                    result.success(null)
                }
                "stopCallRingback" -> {
                    stopCallRingback()
                    result.success(null)
                }
                "setCallProximity" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setCallProximity(enabled)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        clearCallAudioRoute()
        setCallProximity(false)
        activityChannel?.let { ForegroundBridge.detach(it) }
        activityChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureForegroundSelection(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_LOCAL_IMAGE) {
            val pending = localImagePickResult ?: return
            localImagePickResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                pending.success(null)
                return
            }
            runCatching { readPickedImage(uri) }
                .onSuccess { pending.success(it) }
                .onFailure { pending.error("read_failed", it.message, null) }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun pickLocalImage(result: MethodChannel.Result) {
        if (localImagePickResult != null) {
            result.error("busy", "Image picker already active", null)
            return
        }
        val intent = Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).apply {
            type = "image/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        localImagePickResult = result
        runCatching {
            startActivityForResult(intent, REQUEST_PICK_LOCAL_IMAGE)
        }.onFailure {
            localImagePickResult = null
            result.error("unavailable", it.message, null)
        }
    }

    private fun readPickedImage(uri: Uri): Map<String, Any?> {
        val resolver = contentResolver
        val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
        return mapOf(
            "bytes" to bytes,
            "name" to (queryDisplayName(uri) ?: "profile-avatar.jpg"),
            "mimeType" to resolver.getType(uri)
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        return contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) cursor.getString(index) else null
            } else {
                null
            }
        }
    }

    private fun setCallAudioRoute(speaker: Boolean) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val targetType = if (speaker) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            } else {
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            }
            val device = audioManager.availableCommunicationDevices.firstOrNull { it.type == targetType }
            if (device != null) {
                audioManager.setCommunicationDevice(device)
                return
            }
        }

        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = speaker
    }

    private fun clearCallAudioRoute() {
        stopCallRingback()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        resetCallAudioManager(audioManager)
        scheduleCallAudioManagerReset(audioManager)
    }

    private fun scheduleCallAudioManagerReset(audioManager: AudioManager) {
        val handler = Handler(Looper.getMainLooper())
        handler.postDelayed({ resetCallAudioManager(audioManager) }, 250L)
        handler.postDelayed({ resetCallAudioManager(audioManager) }, 1000L)
    }

    private fun resetCallAudioManager(audioManager: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { audioManager.clearCommunicationDevice() }
        }
        @Suppress("DEPRECATION")
        runCatching { audioManager.stopBluetoothSco() }
        @Suppress("DEPRECATION")
        runCatching { audioManager.isBluetoothScoOn = false }
        @Suppress("DEPRECATION")
        runCatching { audioManager.isSpeakerphoneOn = false }
        @Suppress("DEPRECATION")
        runCatching { audioManager.isMicrophoneMute = false }
        runCatching { audioManager.mode = AudioManager.MODE_NORMAL }
    }

    private fun startCallRingback() {
        if (callRingbackTone != null) return
        val tone = runCatching {
            ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80)
        }.getOrNull() ?: return
        if (tone.startTone(ToneGenerator.TONE_SUP_RINGTONE)) {
            callRingbackTone = tone
        } else {
            tone.release()
        }
    }

    private fun stopCallRingback() {
        val tone = callRingbackTone ?: return
        callRingbackTone = null
        runCatching { tone.stopTone() }
        runCatching { tone.release() }
    }

    private fun setCallProximity(enabled: Boolean) {
        if (!enabled) {
            val wakeLock = proximityWakeLock
            proximityWakeLock = null
            if (wakeLock?.isHeld == true) {
                runCatching {
                    wakeLock.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
                }
            }
            return
        }

        if (proximityWakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!powerManager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            return
        }
        val wakeLock = powerManager.newWakeLock(
            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
            "$packageName:call-proximity"
        )
        wakeLock.setReferenceCounted(false)
        runCatching { wakeLock.acquire() }
            .onSuccess { proximityWakeLock = wakeLock }
    }

    private fun captureForegroundSelection(intent: Intent?) {
        val payload = intent?.getStringExtra(IrcForegroundService.EXTRA_PAYLOAD)
        ForegroundBridge.foregroundSelection(payload)
        if (payload?.startsWith("call:") == true) {
            IrcForegroundService.clearAlert(applicationContext)
        }
    }
}
