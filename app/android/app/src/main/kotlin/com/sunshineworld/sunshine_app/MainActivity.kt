package com.sunshineworld.sunshine_app

import android.Manifest
import android.app.ActivityManager
import android.app.PendingIntent
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.DocumentsContract
import android.view.WindowManager
import com.konovalov.vad.webrtc.VadWebRTC
import com.konovalov.vad.webrtc.config.FrameSize
import com.konovalov.vad.webrtc.config.Mode
import com.konovalov.vad.webrtc.config.SampleRate
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import me.jahnen.libaums.core.UsbMassStorageDevice
import me.jahnen.libaums.core.fs.UsbFile
import me.jahnen.libaums.core.fs.UsbFileInputStream
import me.jahnen.libaums.core.fs.UsbFileOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.max
import kotlin.math.min

class MainActivity : FlutterActivity() {
    private val methodChannelName = "spark/audio"
    private val micChannelName = "spark/mic"
    private val devicePerformanceChannelName = "storyvault/device_performance"
    private val usbExportChannelName = "storyvault/usb_export"
    private val permissionRequestCode = 4107
    private val usbTreeRequestCode = 4308
    private val usbExportPermissionAction = "com.sunshineworld.sunshine_app.USB_EXPORT_PERMISSION"
    private val usbMassStorageRootUri = "usbms://storyvault-root"
    private val vadMode = Mode.VERY_AGGRESSIVE
    private val vadSpeechDurationMs = 50
    private val vadSilenceDurationMs = 300

    private val mainHandler = Handler(Looper.getMainLooper())
    private var permissionResult: MethodChannel.Result? = null
    private var usbTreeResult: MethodChannel.Result? = null
    private var usbExportPermissionResult: MethodChannel.Result? = null
    private var usbExportPendingDevice: UsbMassStorageDevice? = null
    private var usbExportSession: UsbExportSession? = null
    private var micSink: EventChannel.EventSink? = null

    @Volatile
    private var recording = false
    private var audioRecord: AudioRecord? = null
    private var recordThread: Thread? = null
    @Volatile
    private var recordSampleRate = 0
    @Volatile
    private var recordFrameMs = 0
    @Volatile
    private var recordFrameBytes = 0
    @Volatile
    private var recordBufferSize = 0
    @Volatile
    private var recordAudioSource = ""
    @Volatile
    private var recordFramesRead = 0L
    @Volatile
    private var recordBytesRead = 0L
    @Volatile
    private var recordReadErrors = 0L
    @Volatile
    private var recordLastReadAtMs = 0L
    @Volatile
    private var recordLastReadError = 0
    @Volatile
    private var recordVadSource = "none"
    @Volatile
    private var recordVadMode = ""
    @Volatile
    private var recordVadFrameSamples = 0
    @Volatile
    private var recordVadSpeechFrames = 0L
    @Volatile
    private var recordVadNoiseFrames = 0L
    @Volatile
    private var recordVadErrors = 0L
    @Volatile
    private var recordVadLastSpeech = false

    private var audioTrack: AudioTrack? = null
    private var playbackExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var usbExportExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val playbackLock = Any()
    private var playbackSessionId = 0
    private var playbackSampleRate = 0
    private var playbackStreamClosed = false
    private var playbackWritesSettled = true
    private var playbackScheduledBuffers = 0
    private var playbackScheduledFrames = 0L
    private var playbackBufferEndFrames = mutableListOf<Long>()
    private var playbackWriteCalls = 0
    private var playbackWrittenBytes = 0L
    private var playbackLastWriteBytes = 0
    private var playbackDroppedNoPlayerWrites = 0
    private var playbackDroppedStaleWrites = 0
    private val playbackDrainWaiters = mutableListOf<PlaybackDrainWaiter>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        registerUsbExportPermissionReceiver()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestRecordPermission" -> requestRecordPermission(result)
                "startRecording" -> startRecording(call, result)
                "recordingStatus" -> result.success(recordingStatus())
                "stopRecording" -> {
                    stopRecording()
                    result.success(null)
                }
                "startPlayback" -> startPlayback(call, result)
                "writePlayback" -> writePlayback(call, result)
                "finishPlaybackStream" -> finishPlaybackStream(call, result)
                "playbackStatus" -> result.success(playbackStatus())
                "stopPlayback" -> stopPlayback(call, result)
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            micChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                micSink = events
            }

            override fun onCancel(arguments: Any?) {
                micSink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            devicePerformanceChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "snapshot" -> result.success(devicePerformanceSnapshot())
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            usbExportChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "selectRoot" -> selectUsbRoot(result)
                "getDeviceInfo" -> getUsbDeviceInfo(call, result)
                "releaseRoot" -> releaseUsbRoot(call, result)
                "listRoot" -> listUsbRoot(call, result)
                "readTextFile" -> readUsbTextFile(call, result)
                "writeTextFile" -> writeUsbTextFile(call, result)
                "deleteRootFile" -> deleteUsbRootFile(call, result)
                "copyFileToRoot" -> copyFileToUsbRoot(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun devicePerformanceSnapshot(): Map<String, Any> {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager.getMemoryInfo(memoryInfo)
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            powerManager.currentThermalStatus
        } else {
            PowerManager.THERMAL_STATUS_NONE
        }
        return mapOf(
            "platform" to "android",
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "sdkInt" to Build.VERSION.SDK_INT,
            "buildFingerprint" to Build.FINGERPRINT,
            "totalMemoryBytes" to memoryInfo.totalMem,
            "availableMemoryBytes" to memoryInfo.availMem,
            "processPssBytes" to Debug.getPss().toLong() * 1024L,
            "memoryClassMb" to activityManager.memoryClass,
            "cpuCores" to Runtime.getRuntime().availableProcessors(),
            "lowMemory" to memoryInfo.lowMemory,
            "lowRamDevice" to activityManager.isLowRamDevice,
            "powerSaveMode" to powerManager.isPowerSaveMode,
            "thermalStatus" to thermalStatus
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) {
            return
        }
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != usbTreeRequestCode) {
            return
        }
        val pending = usbTreeResult
        usbTreeResult = null
        if (pending == null) {
            return
        }
        if (resultCode != RESULT_OK) {
            pending.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            pending.success(null)
            return
        }
        val flags = data.flags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            // Some providers do not expose persistable grants. The active grant is
            // still enough for the current export session.
        }
        pending.success(uri.toString())
    }

    override fun onDestroy() {
        stopRecording()
        stopPlayback()
        closeUsbExportSession()
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        playbackExecutor.shutdownNow()
        usbExportExecutor.shutdownNow()
        try {
            unregisterReceiver(usbExportPermissionReceiver)
        } catch (_: IllegalArgumentException) {
            // Receiver was not registered or was already unregistered.
        }
        super.onDestroy()
    }

    private val usbExportPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != usbExportPermissionAction) {
                return
            }
            val pendingResult = usbExportPermissionResult
            val pendingDevice = usbExportPendingDevice
            usbExportPermissionResult = null
            usbExportPendingDevice = null
            if (pendingResult == null || pendingDevice == null) {
                return
            }
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            if (!granted) {
                pendingResult.success(null)
                return
            }
            try {
                pendingResult.success(openUsbMassStorageRoot(pendingDevice))
            } catch (error: Exception) {
                pendingResult.error("usb_open_failed", error.message, null)
            }
        }
    }

    private fun registerUsbExportPermissionReceiver() {
        val filter = IntentFilter(usbExportPermissionAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbExportPermissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(usbExportPermissionReceiver, filter)
        }
    }

    private fun selectUsbRoot(result: MethodChannel.Result) {
        /*
         * Parent-mode USB export intentionally targets attached mass-storage
         * devices via Android USB Host + libaums. Cheap MP3 speakers generally
         * expect root-level 001_*.mp3 files, so a generic folder picker is not
         * useful for this feature and would confuse the user about where files
         * are written.
         *
         * The app does not request MANAGE_EXTERNAL_STORAGE, scan phone storage,
         * format devices, or write outside the attached USB export target.
         */
        val directStarted = tryStartUsbMassStorageSelection(result)
        if (directStarted) {
            return
        }
        result.error("no_usb_device", "Connect a StoryVault storage device and try again.", null)
    }

    private fun tryStartUsbMassStorageSelection(result: MethodChannel.Result): Boolean {
        val devices = UsbMassStorageDevice.getMassStorageDevices(this)
        if (devices.isEmpty()) {
            return false
        }
        if (usbExportPermissionResult != null) {
            result.error("usb_permission_pending", "USB permission is already pending.", null)
            return true
        }
        val device = devices.first()
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        if (usbManager.hasPermission(device.usbDevice)) {
            try {
                result.success(openUsbMassStorageRoot(device))
            } catch (error: Exception) {
                result.error("usb_open_failed", error.message, null)
            }
            return true
        }
        usbExportPermissionResult = result
        usbExportPendingDevice = device
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android fills UsbManager.EXTRA_PERMISSION_GRANTED into this
                // broadcast. Keeping it mutable avoids a false first-tap denial
                // on Android 12+ while still scoping the intent to this package.
                PendingIntent.FLAG_MUTABLE
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        val permissionIntent = PendingIntent.getBroadcast(
            this,
            0,
            Intent(usbExportPermissionAction).setPackage(packageName),
            flags
        )
        usbManager.requestPermission(device.usbDevice, permissionIntent)
        return true
    }

    private fun openUsbMassStorageRoot(device: UsbMassStorageDevice): String {
        closeUsbExportSession()
        device.init()
        val partition = device.partitions.firstOrNull()
            ?: throw IllegalStateException("USB drive has no supported FAT partition.")
        val fileSystem = partition.fileSystem
        usbExportSession = UsbExportSession(
            device = device,
            root = fileSystem.rootDirectory,
            volumeLabel = fileSystem.volumeLabel,
            capacity = fileSystem.capacity,
            freeSpace = fileSystem.freeSpace
        )
        return usbMassStorageRootUri
    }

    private fun closeUsbExportSession() {
        val session = usbExportSession
        usbExportSession = null
        try {
            session?.device?.close()
        } catch (_: Exception) {
            // USB devices are removable; close failures are not actionable.
        }
    }

    private fun listUsbRoot(call: MethodCall, result: MethodChannel.Result) {
        val rootUri = call.argument<String>("rootUri")
        if (rootUri.isNullOrBlank()) {
            result.error("bad_args", "rootUri is required.", null)
            return
        }
        try {
            if (isUsbMassStorageUri(rootUri)) {
                runUsbExportTask(
                    result,
                    work = { listUsbMassStorageRoot() },
                    success = { value -> result.success(value) }
                )
                return
            }
            val files = listRootDocuments(Uri.parse(rootUri)).map { document ->
                mapOf(
                    "name" to document.name,
                    "size" to document.size,
                    "mimeType" to document.mimeType,
                    "lastModified" to document.lastModified
                )
            }
            result.success(files)
        } catch (error: Exception) {
            result.error("list_failed", error.message, null)
        }
    }

    private fun getUsbDeviceInfo(call: MethodCall, result: MethodChannel.Result) {
        val rootUri = call.argument<String>("rootUri")
        if (rootUri.isNullOrBlank()) {
            result.error("bad_args", "rootUri is required.", null)
            return
        }
        try {
            if (!isUsbMassStorageUri(rootUri)) {
                result.error("unsupported_target", "Only USB mass-storage export is supported.", null)
                return
            }
            result.success(usbExportSessionInfo())
        } catch (error: Exception) {
            result.error("device_info_failed", error.message, null)
        }
    }

    private fun releaseUsbRoot(call: MethodCall, result: MethodChannel.Result) {
        val rootUri = call.argument<String>("rootUri")
        if (rootUri.isNullOrBlank()) {
            result.error("bad_args", "rootUri is required.", null)
            return
        }
        try {
            if (!isUsbMassStorageUri(rootUri)) {
                result.success(null)
                return
            }
            closeUsbExportSession()
            result.success(null)
        } catch (error: Exception) {
            result.error("release_failed", error.message, null)
        }
    }

    private fun usbExportSessionInfo(): Map<String, Any> {
        val session = requireUsbExportSession()
        val usbDevice = session.device.usbDevice
        val volume = session.volumeLabel.trim()
        val product = usbDevice.productName?.trim().orEmpty()
        val manufacturer = usbDevice.manufacturerName?.trim().orEmpty()
        val label = listOf(volume, product, manufacturer)
            .firstOrNull { it.isNotEmpty() }
            ?: "USB storage device"
        return mapOf(
            "rootUri" to usbMassStorageRootUri,
            "label" to label,
            "volumeLabel" to volume,
            "manufacturer" to manufacturer,
            "product" to product,
            "capacity" to session.capacity,
            "freeSpace" to session.freeSpace
        )
    }

    private fun readUsbTextFile(call: MethodCall, result: MethodChannel.Result) {
        val rootUri = call.argument<String>("rootUri")
        val fileName = call.argument<String>("fileName")
        if (rootUri.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("bad_args", "rootUri and fileName are required.", null)
            return
        }
        try {
            if (isUsbMassStorageUri(rootUri)) {
                runUsbExportTask(
                    result,
                    work = { readUsbMassStorageTextFile(fileName) },
                    success = { value -> result.success(value) }
                )
                return
            }
            val document = findRootDocument(Uri.parse(rootUri), fileName)
            if (document == null) {
                result.success(null)
                return
            }
            val text = contentResolver.openInputStream(document.uri)?.use { input ->
                String(input.readBytes(), StandardCharsets.UTF_8)
            }
            result.success(text)
        } catch (error: Exception) {
            result.error("read_failed", error.message, null)
        }
    }

    private fun writeUsbTextFile(call: MethodCall, result: MethodChannel.Result) {
        val rootUri = call.argument<String>("rootUri")
        val fileName = call.argument<String>("fileName")
        val text = call.argument<String>("text")
        val mimeType = call.argument<String>("mimeType") ?: "application/json"
        if (rootUri.isNullOrBlank() || fileName.isNullOrBlank() || text == null) {
            result.error("bad_args", "rootUri, fileName, and text are required.", null)
            return
        }
        try {
            if (isUsbMassStorageUri(rootUri)) {
                runUsbExportTask(
                    result,
                    work = {
                        writeUsbMassStorageTextFile(fileName, text)
                        null
                    },
                    success = { result.success(null) }
                )
                return
            }
            val root = Uri.parse(rootUri)
            val existing = findRootDocument(root, fileName)
            val target = existing?.uri ?: createRootDocument(root, mimeType, fileName)
            contentResolver.openOutputStream(target, "wt")?.use { output ->
                output.write(text.toByteArray(StandardCharsets.UTF_8))
            } ?: throw IllegalStateException("Could not open output stream.")
            result.success(null)
        } catch (error: Exception) {
            result.error("write_failed", error.message, null)
        }
    }

    private fun copyFileToUsbRoot(call: MethodCall, result: MethodChannel.Result) {
        val rootUri = call.argument<String>("rootUri")
        val sourcePath = call.argument<String>("sourcePath")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "audio/mpeg"
        if (rootUri.isNullOrBlank() || sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("bad_args", "rootUri, sourcePath, and fileName are required.", null)
            return
        }
        try {
            if (isUsbMassStorageUri(rootUri)) {
                runUsbExportTask(
                    result,
                    work = { copyFileToUsbMassStorageRoot(sourcePath, fileName) },
                    success = { bytes ->
                        result.success(
                            mapOf(
                                "filename" to fileName,
                                "bytes" to bytes
                            )
                        )
                    }
                )
                return
            }
            val source = File(sourcePath)
            if (!source.exists() || !source.isFile) {
                result.error("source_missing", "Source file is missing: $sourcePath", null)
                return
            }
            val root = Uri.parse(rootUri)
            if (findRootDocument(root, fileName) != null) {
                result.error("target_exists", "Target already exists: $fileName", null)
                return
            }
            val target = createRootDocument(root, mimeType, fileName)
            var bytes = 0L
            FileInputStream(source).use { input ->
                contentResolver.openOutputStream(target, "w")?.use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) {
                            break
                        }
                        output.write(buffer, 0, read)
                        bytes += read.toLong()
                    }
                    output.flush()
                } ?: throw IllegalStateException("Could not open output stream.")
            }
            result.success(
                mapOf(
                    "filename" to fileName,
                    "bytes" to bytes
                )
            )
        } catch (error: Exception) {
            result.error("copy_failed", error.message, null)
        }
    }

    private fun deleteUsbRootFile(call: MethodCall, result: MethodChannel.Result) {
        val rootUri = call.argument<String>("rootUri")
        val fileName = call.argument<String>("fileName")
        if (rootUri.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("bad_args", "rootUri and fileName are required.", null)
            return
        }
        try {
            if (isUsbMassStorageUri(rootUri)) {
                runUsbExportTask(
                    result,
                    work = {
                        deleteUsbMassStorageRootFile(fileName)
                        null
                    },
                    success = { result.success(null) }
                )
                return
            }
            val document = findRootDocument(Uri.parse(rootUri), fileName)
            if (document != null) {
                DocumentsContract.deleteDocument(contentResolver, document.uri)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("delete_failed", error.message, null)
        }
    }

    private fun isUsbMassStorageUri(rootUri: String): Boolean {
        return rootUri.startsWith("usbms://")
    }

    private fun requireUsbExportSession(): UsbExportSession {
        return usbExportSession
            ?: throw IllegalStateException("No USB mass-storage export session is active.")
    }

    private fun <T> runUsbExportTask(
        result: MethodChannel.Result,
        work: () -> T,
        success: (T) -> Unit
    ) {
        /*
         * libaums performs real USB/FAT I/O. Keeping this off Flutter's platform
         * thread prevents ANRs and reduces vendor-ROM instability during longer
         * multi-file playlist exports.
         */
        try {
            usbExportExecutor.execute {
                try {
                    val value = work()
                    mainHandler.post { success(value) }
                } catch (error: Throwable) {
                    mainHandler.post {
                        result.error(
                            "usb_export_failed",
                            error.message ?: error.javaClass.simpleName,
                            null
                        )
                    }
                }
            }
        } catch (error: RejectedExecutionException) {
            result.error("usb_export_unavailable", error.message, null)
        }
    }

    private fun listUsbMassStorageRoot(): List<Map<String, Any>> {
        val session = requireUsbExportSession()
        return session.root.listFiles().map { file ->
            mapOf(
                "name" to file.name,
                "size" to if (file.isDirectory) 0L else file.length,
                "mimeType" to if (file.isDirectory) "vnd.android.document/directory" else "application/octet-stream",
                "lastModified" to file.lastModified()
            )
        }
    }

    private fun readUsbMassStorageTextFile(fileName: String): String? {
        val file = findUsbMassStorageRootFile(fileName) ?: return null
        UsbFileInputStream(file).use { input ->
            return String(input.readBytes(), StandardCharsets.UTF_8)
        }
    }

    private fun writeUsbMassStorageTextFile(fileName: String, text: String) {
        writeBytesToUsbMassStorageRoot(
            fileName = fileName,
            bytes = text.toByteArray(StandardCharsets.UTF_8),
            overwrite = true
        )
    }

    private fun copyFileToUsbMassStorageRoot(sourcePath: String, fileName: String): Long {
        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
            throw IllegalStateException("Source file is missing: $sourcePath")
        }
        if (findUsbMassStorageRootFile(fileName) != null) {
            throw IllegalStateException("Target already exists: $fileName")
        }
        val root = requireUsbExportSession().root
        val target = root.createFile(fileName)
        var bytes = 0L
        FileInputStream(source).use { input ->
            UsbFileOutputStream(target).use { output ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) {
                        break
                    }
                    output.write(buffer, 0, read)
                    bytes += read.toLong()
                }
                output.flush()
            }
        }
        return bytes
    }

    private fun writeBytesToUsbMassStorageRoot(
        fileName: String,
        bytes: ByteArray,
        overwrite: Boolean
    ) {
        val existing = findUsbMassStorageRootFile(fileName)
        if (existing != null) {
            if (!overwrite) {
                throw IllegalStateException("Target already exists: $fileName")
            }
            existing.delete()
        }
        val target = requireUsbExportSession().root.createFile(fileName)
        UsbFileOutputStream(target).use { output ->
            output.write(bytes)
            output.flush()
        }
    }

    private fun findUsbMassStorageRootFile(fileName: String): UsbFile? {
        val normalized = fileName.trim().lowercase()
        if (normalized.isEmpty()) {
            return null
        }
        return requireUsbExportSession().root.listFiles().firstOrNull {
            it.name.trim().lowercase() == normalized
        }
    }

    private fun deleteUsbMassStorageRootFile(fileName: String) {
        findUsbMassStorageRootFile(fileName)?.delete()
    }

    private fun createRootDocument(rootUri: Uri, mimeType: String, fileName: String): Uri {
        val parent = rootDocumentUri(rootUri)
        return DocumentsContract.createDocument(
            contentResolver,
            parent,
            mimeType,
            fileName
        ) ?: throw IllegalStateException("Could not create $fileName.")
    }

    private fun findRootDocument(rootUri: Uri, fileName: String): UsbRootDocument? {
        val normalized = fileName.trim().lowercase()
        if (normalized.isEmpty()) {
            return null
        }
        return listRootDocuments(rootUri).firstOrNull {
            it.name.trim().lowercase() == normalized
        }
    }

    private fun listRootDocuments(rootUri: Uri): List<UsbRootDocument> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            rootUri,
            DocumentsContract.getTreeDocumentId(rootUri)
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )
        val documents = mutableListOf<UsbRootDocument>()
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val modifiedColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            while (cursor.moveToNext()) {
                val documentId = if (idColumn >= 0) cursor.getString(idColumn) else ""
                val name = if (nameColumn >= 0) cursor.getString(nameColumn) else ""
                if (documentId.isNullOrBlank() || name.isNullOrBlank()) {
                    continue
                }
                documents.add(
                    UsbRootDocument(
                        uri = DocumentsContract.buildDocumentUriUsingTree(rootUri, documentId),
                        name = name,
                        mimeType = if (mimeColumn >= 0) cursor.getString(mimeColumn) ?: "" else "",
                        size = if (sizeColumn >= 0) cursor.getLong(sizeColumn) else 0L,
                        lastModified = if (modifiedColumn >= 0) cursor.getLong(modifiedColumn) else 0L
                    )
                )
            }
        }
        return documents
    }

    private fun rootDocumentUri(rootUri: Uri): Uri {
        return DocumentsContract.buildDocumentUriUsingTree(
            rootUri,
            DocumentsContract.getTreeDocumentId(rootUri)
        )
    }

    private data class UsbRootDocument(
        val uri: Uri,
        val name: String,
        val mimeType: String,
        val size: Long,
        val lastModified: Long
    )

    private data class UsbExportSession(
        val device: UsbMassStorageDevice,
        val root: UsbFile,
        val volumeLabel: String,
        val capacity: Long,
        val freeSpace: Long
    )

    private fun requestRecordPermission(result: MethodChannel.Result) {
        if (hasRecordPermission()) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(false)
            return
        }
        if (permissionResult != null) {
            result.error("permission_pending", "Microphone permission is already pending.", null)
            return
        }
        permissionResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), permissionRequestCode)
    }

    private fun hasRecordPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun startRecording(call: MethodCall, result: MethodChannel.Result) {
        if (!hasRecordPermission()) {
            result.success(false)
            return
        }
        if (recording) {
            result.success(true)
            return
        }

        val sampleRate = call.argument<Int>("sampleRate") ?: 16000
        val frameMs = call.argument<Int>("frameMs") ?: 20
        val frameBytes = max(2, sampleRate * frameMs / 1000 * 2)
        val minBuffer = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuffer <= 0) {
            result.success(false)
            return
        }

        val bufferSize = max(minBuffer, frameBytes * 4)
        val recorderInfo = createRecorder(sampleRate, bufferSize)
        val recorder = recorderInfo?.first
        val sourceName = recorderInfo?.second ?: ""
        if (recorder == null) {
            result.success(false)
            return
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            result.success(false)
            return
        }

        recordSampleRate = sampleRate
        recordFrameMs = frameMs
        recordFrameBytes = frameBytes
        recordBufferSize = bufferSize
        recordAudioSource = sourceName
        recordFramesRead = 0
        recordBytesRead = 0
        recordReadErrors = 0
        recordLastReadAtMs = 0
        recordLastReadError = 0
        recordVadSource = "none"
        recordVadMode = ""
        recordVadFrameSamples = frameBytes / 2
        recordVadSpeechFrames = 0
        recordVadNoiseFrames = 0
        recordVadErrors = 0
        recordVadLastSpeech = false
        audioRecord = recorder
        recording = true
        try {
            recorder.startRecording()
        } catch (_: IllegalStateException) {
            recording = false
            audioRecord = null
            recorder.release()
            result.success(false)
            return
        }

        val vad = createNativeVad(sampleRate, frameBytes / 2)
        recordThread = Thread {
            val buffer = ByteArray(frameBytes)
            try {
                while (recording) {
                    val read = recorder.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        recordFramesRead += 1
                        recordBytesRead += read.toLong()
                        recordLastReadAtMs = SystemClock.elapsedRealtime()
                        val frame = if (read == buffer.size) {
                            buffer.copyOf()
                        } else {
                            buffer.copyOf(read)
                        }
                        val speech = if (read == buffer.size) {
                            detectNativeSpeech(vad, frame)
                        } else {
                            null
                        }
                        val payload = HashMap<String, Any>()
                        payload["pcm16"] = frame
                        payload["vadSource"] = recordVadSource
                        if (speech != null) {
                            payload["isSpeech"] = speech
                            payload["vadMode"] = recordVadMode
                        }
                        mainHandler.post {
                            micSink?.success(payload)
                        }
                    } else if (read < 0) {
                        recordReadErrors += 1
                        recordLastReadError = read
                    }
                }
            } finally {
                closeNativeVad(vad)
            }
        }.also {
            it.name = "spark-audio-record"
            it.start()
        }

        result.success(true)
    }

    private fun stopRecording() {
        recording = false
        val recorder = audioRecord
        audioRecord = null
        try {
            recorder?.stop()
        } catch (_: IllegalStateException) {
            // Recorder may already be stopped.
        }
        recorder?.release()
        recordThread?.join(250)
        recordThread = null
    }

    private fun createRecorder(sampleRate: Int, bufferSize: Int): Pair<AudioRecord, String>? {
        val sources = listOf(
            MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION",
            MediaRecorder.AudioSource.MIC to "MIC"
        )
        for ((source, name) in sources) {
            val recorder = AudioRecord(
                source,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize
            )
            if (recorder.state == AudioRecord.STATE_INITIALIZED) {
                return recorder to name
            }
            recorder.release()
        }
        return null
    }

    private fun createNativeVad(sampleRate: Int, frameSamples: Int): VadWebRTC? {
        val vadSampleRate = when (sampleRate) {
            8000 -> SampleRate.SAMPLE_RATE_8K
            16000 -> SampleRate.SAMPLE_RATE_16K
            32000 -> SampleRate.SAMPLE_RATE_32K
            48000 -> SampleRate.SAMPLE_RATE_48K
            else -> {
                recordVadSource = "unsupported"
                return null
            }
        }
        val vadFrameSize = when (frameSamples) {
            80 -> FrameSize.FRAME_SIZE_80
            160 -> FrameSize.FRAME_SIZE_160
            240 -> FrameSize.FRAME_SIZE_240
            320 -> FrameSize.FRAME_SIZE_320
            480 -> FrameSize.FRAME_SIZE_480
            640 -> FrameSize.FRAME_SIZE_640
            960 -> FrameSize.FRAME_SIZE_960
            1440 -> FrameSize.FRAME_SIZE_1440
            else -> {
                recordVadSource = "unsupported"
                return null
            }
        }
        return try {
            VadWebRTC(
                sampleRate = vadSampleRate,
                frameSize = vadFrameSize,
                mode = vadMode,
                speechDurationMs = vadSpeechDurationMs,
                silenceDurationMs = vadSilenceDurationMs
            ).also {
                recordVadSource = "webrtc"
                recordVadMode = vadMode.name
            }
        } catch (_: Throwable) {
            recordVadSource = "unavailable"
            recordVadMode = ""
            null
        }
    }

    private fun detectNativeSpeech(vad: VadWebRTC?, frame: ByteArray): Boolean? {
        if (vad == null) {
            return null
        }
        return try {
            val speech = vad.isSpeech(frame)
            recordVadLastSpeech = speech
            if (speech) {
                recordVadSpeechFrames += 1
            } else {
                recordVadNoiseFrames += 1
            }
            speech
        } catch (_: Throwable) {
            recordVadErrors += 1
            null
        }
    }

    private fun closeNativeVad(vad: VadWebRTC?) {
        try {
            vad?.close()
        } catch (_: Throwable) {
            // Native VAD may already be closed if recording stops during teardown.
        }
    }

    private fun recordingStatus(): Map<String, Any> {
        return mapOf(
            "permission" to hasRecordPermission(),
            "recording" to recording,
            "hasEventSink" to (micSink != null),
            "sampleRate" to recordSampleRate,
            "frameMs" to recordFrameMs,
            "frameBytes" to recordFrameBytes,
            "bufferSize" to recordBufferSize,
            "audioSource" to recordAudioSource,
            "framesRead" to recordFramesRead,
            "bytesRead" to recordBytesRead,
            "readErrors" to recordReadErrors,
            "lastReadAtMs" to recordLastReadAtMs,
            "lastReadError" to recordLastReadError,
            "vadSource" to recordVadSource,
            "vadMode" to recordVadMode,
            "vadFrameSamples" to recordVadFrameSamples,
            "vadSpeechFrames" to recordVadSpeechFrames,
            "vadNoiseFrames" to recordVadNoiseFrames,
            "vadErrors" to recordVadErrors,
            "vadLastSpeech" to recordVadLastSpeech
        )
    }

    private fun startPlayback(call: MethodCall, result: MethodChannel.Result) {
        val sampleRate = max(8000, call.argument<Int>("sampleRate") ?: 24000)
        val requestedSessionId = call.argument<Int>("sessionId")
        val nextSessionId = synchronized(playbackLock) {
            requestedSessionId ?: (playbackSessionId + 1)
        }
        val existingTrack = synchronized(playbackLock) {
            audioTrack?.takeIf {
                playbackSessionId == nextSessionId &&
                    playbackSampleRate == sampleRate &&
                    !playbackStreamClosed &&
                    it.state == AudioTrack.STATE_INITIALIZED
            }
        }
        if (existingTrack != null) {
            if (existingTrack.playState != AudioTrack.PLAYSTATE_PLAYING) {
                existingTrack.play()
            }
            result.success(true)
            return
        }

        stopPlayback(invalidateSession = false)

        val minBuffer = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuffer <= 0) {
            result.success(false)
            return
        }

        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STREAM)
                .setBufferSizeInBytes(max(minBuffer, sampleRate / 2))
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                android.media.AudioManager.STREAM_MUSIC,
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuffer, sampleRate / 2),
                AudioTrack.MODE_STREAM
            )
        }

        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            result.success(false)
            return
        }

        synchronized(playbackLock) {
            playbackSessionId = nextSessionId
            playbackSampleRate = sampleRate
            resetPlaybackTrackingLocked()
            audioTrack = track
        }
        track.play()
        result.success(true)
    }

    private fun writePlayback(call: MethodCall, result: MethodChannel.Result) {
        val bytes = call.argument<ByteArray>("bytes")
        if (bytes == null || bytes.isEmpty()) {
            result.success(null)
            return
        }
        val requestedSessionId = call.argument<Int>("sessionId")
        val accepted = synchronized(playbackLock) {
            val track = audioTrack
            if (track == null) {
                playbackDroppedNoPlayerWrites += 1
                null
            } else if (
                (requestedSessionId != null && requestedSessionId != playbackSessionId) ||
                playbackStreamClosed
            ) {
                playbackDroppedStaleWrites += 1
                null
            } else {
                playbackWriteCalls += 1
                playbackLastWriteBytes = bytes.size
                playbackWritesSettled = false
                PlaybackWriteTarget(
                    track = track,
                    executor = playbackExecutor,
                    sessionId = playbackSessionId
                )
            }
        }
        if (accepted == null) {
            result.success(null)
            return
        }

        try {
            accepted.executor.execute {
                writePlaybackBytes(accepted, bytes)
            }
        } catch (_: RejectedExecutionException) {
            synchronized(playbackLock) {
                playbackDroppedStaleWrites += 1
            }
        }
        result.success(null)
    }

    private fun writePlaybackBytes(target: PlaybackWriteTarget, bytes: ByteArray) {
        val byteCount = bytes.size - (bytes.size % 2)
        var offset = 0
        try {
            while (offset < byteCount) {
                val stillCurrent = synchronized(playbackLock) {
                    audioTrack === target.track && playbackSessionId == target.sessionId
                }
                if (!stillCurrent) {
                    return
                }
                val written = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    target.track.write(
                        bytes,
                        offset,
                        byteCount - offset,
                        AudioTrack.WRITE_BLOCKING
                    )
                } else {
                    @Suppress("DEPRECATION")
                    target.track.write(bytes, offset, byteCount - offset)
                }
                if (written <= 0) {
                    break
                }
                offset += written
            }
        } catch (_: IllegalStateException) {
            // Playback can be stopped while a blocking write is active.
        } finally {
            if (offset > 0) {
                synchronized(playbackLock) {
                    if (audioTrack === target.track && playbackSessionId == target.sessionId) {
                        val frames = offset / 2
                        playbackWrittenBytes += offset.toLong()
                        playbackScheduledBuffers += 1
                        playbackScheduledFrames += frames.toLong()
                        playbackBufferEndFrames.add(playbackScheduledFrames)
                    }
                }
            }
        }
    }

    private fun finishPlaybackStream(call: MethodCall, result: MethodChannel.Result) {
        val requestedSessionId = call.argument<Int>("sessionId")
        val timeoutMs = max(0, call.argument<Int>("timeoutMs") ?: 30000)
        val staleStatus = synchronized(playbackLock) {
            if (requestedSessionId != null && requestedSessionId != playbackSessionId) {
                playbackStatusLocked().toMutableMap().apply {
                    this["requestedSessionId"] = requestedSessionId
                    this["stale"] = true
                    this["drained"] = true
                    this["timedOut"] = false
                    this["stopped"] = false
                    this["waitMs"] = 0
                }
            } else {
                null
            }
        }
        if (staleStatus != null) {
            result.success(staleStatus)
            return
        }

        val waiter: PlaybackDrainWaiter
        val executor: ExecutorService
        synchronized(playbackLock) {
            playbackStreamClosed = true
            waiter = PlaybackDrainWaiter(
                sessionId = playbackSessionId,
                startedAtMs = SystemClock.elapsedRealtime(),
                timeoutMs = timeoutMs,
                result = result
            )
            playbackDrainWaiters.add(waiter)
            executor = playbackExecutor
        }

        try {
            executor.execute {
                synchronized(playbackLock) {
                    if (waiter.sessionId == playbackSessionId) {
                        playbackWritesSettled = true
                    }
                }
                waitForPlaybackDrain(waiter)
            }
        } catch (_: RejectedExecutionException) {
            completePlaybackDrainWaiter(
                waiter = waiter,
                drained = false,
                timedOut = false,
                stopped = true
            )
        }
    }

    private fun waitForPlaybackDrain(waiter: PlaybackDrainWaiter) {
        while (true) {
            val state = synchronized(playbackLock) {
                if (waiter.completed) {
                    return
                }
                val stale = waiter.sessionId != playbackSessionId
                val status = playbackStatusLocked()
                PlaybackDrainState(
                    stale = stale,
                    drained = status["drained"] == true,
                    elapsedMs = SystemClock.elapsedRealtime() - waiter.startedAtMs
                )
            }
            if (state.stale) {
                completePlaybackDrainWaiter(waiter, drained = true, stale = true)
                return
            }
            if (state.drained) {
                // Playback head position is the device-consumed frame count. A
                // small route tail avoids clipping Bluetooth/speaker pipelines.
                try {
                    Thread.sleep(80)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    completePlaybackDrainWaiter(waiter, stopped = true)
                    return
                }
                completePlaybackDrainWaiter(waiter, drained = true)
                return
            }
            if (state.elapsedMs >= waiter.timeoutMs) {
                completePlaybackDrainWaiter(waiter, timedOut = true)
                return
            }
            try {
                Thread.sleep(12)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                completePlaybackDrainWaiter(waiter, stopped = true)
                return
            }
        }
    }

    private fun playbackStatus(): Map<String, Any> = synchronized(playbackLock) {
        playbackStatusLocked()
    }

    private fun playbackStatusLocked(): Map<String, Any> {
        val track = audioTrack
        val playedFrames = playbackHeadFrames(track)
        val playedBuffers = playbackBufferEndFrames.count { it <= playedFrames }
        val pendingFrames = max(0L, playbackScheduledFrames - playedFrames)
        return mapOf(
            "sessionId" to playbackSessionId,
            "playing" to (track?.playState == AudioTrack.PLAYSTATE_PLAYING),
            "streamClosed" to playbackStreamClosed,
            "scheduledBuffers" to playbackScheduledBuffers,
            "playedBuffers" to playedBuffers,
            "pendingBuffers" to max(0, playbackScheduledBuffers - playedBuffers),
            "scheduledFrames" to playbackScheduledFrames,
            "playedFrames" to playedFrames,
            "pendingFrames" to pendingFrames,
            "inputSampleRate" to playbackSampleRate,
            "outputSampleRate" to playbackSampleRate,
            "inputFrames" to playbackScheduledFrames,
            "resampler" to "none",
            "resampleCalls" to 0,
            "resampleTotalMs" to 0,
            "resampleLastMs" to 0,
            "eqEnabled" to false,
            "eqPreset" to "none",
            "writeCalls" to playbackWriteCalls,
            "writtenBytes" to playbackWrittenBytes,
            "lastWriteBytes" to playbackLastWriteBytes,
            "droppedNoPlayerWrites" to playbackDroppedNoPlayerWrites,
            "droppedStaleWrites" to playbackDroppedStaleWrites,
            "drained" to (
                playbackStreamClosed &&
                    playbackWritesSettled &&
                    pendingFrames == 0L
                )
        )
    }

    private fun playbackHeadFrames(track: AudioTrack?): Long {
        if (track == null || track.state != AudioTrack.STATE_INITIALIZED) {
            return 0L
        }
        return try {
            min(
                playbackScheduledFrames,
                track.playbackHeadPosition.toLong() and 0xffffffffL
            )
        } catch (_: IllegalStateException) {
            0L
        }
    }

    private fun completePlaybackDrainWaiter(
        waiter: PlaybackDrainWaiter,
        drained: Boolean = false,
        timedOut: Boolean = false,
        stopped: Boolean = false,
        stale: Boolean = false
    ) {
        val status = synchronized(playbackLock) {
            if (waiter.completed) {
                return
            }
            waiter.completed = true
            playbackDrainWaiters.remove(waiter)
            playbackStatusLocked().toMutableMap().apply {
                this["waitMs"] = max(
                    0L,
                    SystemClock.elapsedRealtime() - waiter.startedAtMs
                )
                this["drained"] = drained
                this["timedOut"] = timedOut
                this["stopped"] = stopped
                this["stale"] = stale || waiter.sessionId != playbackSessionId
            }
        }
        mainHandler.post {
            waiter.result.success(status)
        }
    }

    private fun stopPlayback(call: MethodCall, result: MethodChannel.Result) {
        val requestedSessionId = call.argument<Int>("sessionId")
        val stale = synchronized(playbackLock) {
            requestedSessionId != null && requestedSessionId != playbackSessionId
        }
        if (!stale) {
            stopPlayback()
        }
        result.success(null)
    }

    private fun stopPlayback(invalidateSession: Boolean = true) {
        val waiters = synchronized(playbackLock) {
            playbackDrainWaiters.toList()
        }
        waiters.forEach {
            completePlaybackDrainWaiter(it, stopped = true)
        }

        val stopped = synchronized(playbackLock) {
            val track = audioTrack
            val executor = playbackExecutor
            audioTrack = null
            playbackExecutor = Executors.newSingleThreadExecutor()
            if (invalidateSession) {
                playbackSessionId += 1
            }
            playbackSampleRate = 0
            resetPlaybackTrackingLocked()
            track to executor
        }
        stopped.second.shutdownNow()
        try {
            stopped.first?.pause()
            stopped.first?.flush()
            stopped.first?.stop()
        } catch (_: IllegalStateException) {
            // Track may already be stopped.
        }
        stopped.first?.release()
    }

    private fun resetPlaybackTrackingLocked() {
        playbackStreamClosed = false
        playbackWritesSettled = true
        playbackScheduledBuffers = 0
        playbackScheduledFrames = 0L
        playbackBufferEndFrames = mutableListOf()
        playbackWriteCalls = 0
        playbackWrittenBytes = 0L
        playbackLastWriteBytes = 0
        playbackDroppedNoPlayerWrites = 0
        playbackDroppedStaleWrites = 0
    }
}

private data class PlaybackWriteTarget(
    val track: AudioTrack,
    val executor: ExecutorService,
    val sessionId: Int
)

private data class PlaybackDrainState(
    val stale: Boolean,
    val drained: Boolean,
    val elapsedMs: Long
)

private class PlaybackDrainWaiter(
    val sessionId: Int,
    val startedAtMs: Long,
    val timeoutMs: Int,
    val result: MethodChannel.Result
) {
    var completed = false
}
