import AVFoundation
import Darwin
import Flutter

final class SparkAudioBridge: NSObject {
  static let shared = SparkAudioBridge()

  private var audioEngine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var playbackEq: AVAudioUnitEQ?
  private var playbackInputFormat: AVAudioFormat?
  private var playbackFormat: AVAudioFormat?
  private var playbackConverter: AVAudioConverter?
  private let playbackEqPreset = "vocal_clarity_v1"
  private var playbackSessionId = 0
  private var playbackInputSampleRate = 0
  private var playbackOutputSampleRate = 0
  private var playbackStreamClosed = false
  private var playbackScheduledBuffers = 0
  private var playbackPlayedBuffers = 0
  private var playbackScheduledFrames = 0
  private var playbackPlayedFrames = 0
  private var playbackInputFrames = 0
  private var playbackResampleCalls = 0
  private var playbackTotalResampleMs = 0
  private var playbackLastResampleMs = 0
  private var playbackWriteCalls = 0
  private var playbackWrittenBytes = 0
  private var playbackLastWriteBytes = 0
  private var playbackDroppedNoPlayerWrites = 0
  private var playbackDroppedStaleWrites = 0
  private var playbackDrainWaiters: [PlaybackDrainWaiter] = []
  private var recordingEngine: AVAudioEngine?
  private var micEventSink: FlutterEventSink?
  private var recordingSampleRate = 16_000
  private var recordingFrameMs = 20
  private var recordingFrameBytes = 640
  private var recordingPendingPcm = Data()
  private var recordingFramesRead = 0
  private var recordingBytesRead = 0
  private var recordingReadErrors = 0
  private var recordingLastReadAtMs = 0
  private var recordingLastReadError = ""

  private override init() {
    super.init()
  }

  func register(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "spark/audio",
      binaryMessenger: messenger
    )
    methodChannel.setMethodCallHandler(handleMethodCall)

    let micChannel = FlutterEventChannel(
      name: "spark/mic",
      binaryMessenger: messenger
    )
    micChannel.setStreamHandler(self)

    let performanceChannel = FlutterMethodChannel(
      name: "storyvault/device_performance",
      binaryMessenger: messenger
    )
    performanceChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "snapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.devicePerformanceSnapshot ?? [:])
    }
  }

  private var devicePerformanceSnapshot: [String: Any] {
    let process = ProcessInfo.processInfo
    let residentBytes = processResidentMemoryBytes
    let totalBytes = process.physicalMemory
    let availableEstimate = totalBytes > residentBytes ? totalBytes - residentBytes : 0
    let thermalStatus: Int
    switch process.thermalState {
    case .nominal: thermalStatus = 0
    case .fair: thermalStatus = 1
    case .serious: thermalStatus = 3
    case .critical: thermalStatus = 4
    @unknown default: thermalStatus = 4
    }
    #if arch(arm64)
    let architectures = ["arm64"]
    #else
    let architectures = ["simulator"]
    #endif
    return [
      "platform": "ios",
      "supportedAbis": architectures,
      "sdkInt": 0,
      "buildFingerprint": "ios-\(UIDevice.current.systemVersion)-\(UIDevice.current.model)",
      "totalMemoryBytes": Int64(totalBytes),
      "availableMemoryBytes": Int64(availableEstimate),
      "processPssBytes": Int64(residentBytes),
      "memoryClassMb": Int(totalBytes / 1_048_576),
      "cpuCores": process.activeProcessorCount,
      "lowMemory": false,
      "lowRamDevice": totalBytes < 4 * 1_073_741_824,
      "powerSaveMode": process.isLowPowerModeEnabled,
      "thermalStatus": thermalStatus,
    ]
  }

  private var processResidentMemoryBytes: UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
  }

  private func handleMethodCall(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "requestRecordPermission":
      requestRecordPermission(result: result)
    case "startRecording":
      startRecording(call: call, result: result)
    case "recordingStatus":
      result(recordingStatus)
    case "stopRecording":
      stopRecording(result: result)
    case "startPlayback":
      startPlayback(call: call, result: result)
    case "writePlayback":
      writePlayback(call: call, result: result)
    case "finishPlaybackStream":
      finishPlaybackStream(call: call, result: result)
    case "playbackStatus":
      result(playbackStatus)
    case "playDiagnosticTone":
      playDiagnosticTone(call: call, result: result)
    case "stopPlayback":
      stopPlayback(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestRecordPermission(result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .granted:
      result(true)
    case .denied:
      result(false)
    case .undetermined:
      session.requestRecordPermission { granted in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    @unknown default:
      result(false)
    }
  }

  private var recordingStatus: [String: Any] {
    [
      "permission": AVAudioSession.sharedInstance().recordPermission == .granted,
      "recording": recordingEngine?.isRunning == true,
      "hasEventSink": micEventSink != nil,
      "sampleRate": recordingSampleRate,
      "frameMs": recordingFrameMs,
      "frameBytes": recordingFrameBytes,
      "bufferSize": recordingPendingPcm.count,
      "audioSource": "ios_av_audio_engine",
      "framesRead": recordingFramesRead,
      "bytesRead": recordingBytesRead,
      "readErrors": recordingReadErrors,
      "lastReadAtMs": recordingLastReadAtMs,
      "lastReadError": recordingLastReadError,
      "vadSource": "client",
      "vadMode": "",
      "vadFrameSamples": 0,
      "vadSpeechFrames": 0,
      "vadNoiseFrames": 0,
      "vadErrors": 0,
      "vadLastSpeech": false,
    ]
  }

  private var playbackStatus: [String: Any] {
    let pendingBuffers = max(0, playbackScheduledBuffers - playbackPlayedBuffers)
    let pendingFrames = max(0, playbackScheduledFrames - playbackPlayedFrames)
    let resamplerName = playbackInputSampleRate > 0 &&
      playbackOutputSampleRate > playbackInputSampleRate
        ? "av_audio_converter"
        : "none"
    return [
      "sessionId": playbackSessionId,
      "playing": playerNode?.isPlaying == true,
      "streamClosed": playbackStreamClosed,
      "scheduledBuffers": playbackScheduledBuffers,
      "playedBuffers": playbackPlayedBuffers,
      "pendingBuffers": pendingBuffers,
      "scheduledFrames": playbackScheduledFrames,
      "playedFrames": playbackPlayedFrames,
      "pendingFrames": pendingFrames,
      "inputSampleRate": playbackInputSampleRate,
      "outputSampleRate": playbackOutputSampleRate,
      "inputFrames": playbackInputFrames,
      "resampler": resamplerName,
      "resampleCalls": playbackResampleCalls,
      "resampleTotalMs": playbackTotalResampleMs,
      "resampleLastMs": playbackLastResampleMs,
      "eqEnabled": playbackEq != nil,
      "eqPreset": playbackEq != nil ? playbackEqPreset : "none",
      "writeCalls": playbackWriteCalls,
      "writtenBytes": playbackWrittenBytes,
      "lastWriteBytes": playbackLastWriteBytes,
      "droppedNoPlayerWrites": playbackDroppedNoPlayerWrites,
      "droppedStaleWrites": playbackDroppedStaleWrites,
      "drained": playbackStreamClosed && pendingBuffers == 0,
    ]
  }

  private func startRecording(call: FlutterMethodCall, result: FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let sampleRate = arguments?["sampleRate"] as? Int ?? 16_000
    let frameMs = arguments?["frameMs"] as? Int ?? 20

    do {
      try startRecording(sampleRate: sampleRate, frameMs: frameMs)
      result(true)
    } catch {
      recordingReadErrors += 1
      recordingLastReadError = error.localizedDescription
      result(false)
    }
  }

  private func startRecording(sampleRate: Int, frameMs: Int) throws {
    if recordingEngine?.isRunning == true,
       recordingSampleRate == sampleRate,
       recordingFrameMs == frameMs {
      return
    }

    guard AVAudioSession.sharedInstance().recordPermission == .granted else {
      throw SparkAudioBridgeError.microphonePermissionDenied
    }

    stopRecordingEngine()

    recordingSampleRate = max(8_000, sampleRate)
    recordingFrameMs = max(10, frameMs)
    let frameSamples = max(1, recordingSampleRate * recordingFrameMs / 1000)
    recordingFrameBytes = frameSamples * MemoryLayout<Int16>.size
    recordingPendingPcm.removeAll(keepingCapacity: true)
    recordingFramesRead = 0
    recordingBytesRead = 0
    recordingReadErrors = 0
    recordingLastReadAtMs = 0
    recordingLastReadError = ""

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
    )
    try session.setPreferredSampleRate(Double(recordingSampleRate))
    try session.setPreferredIOBufferDuration(Double(recordingFrameMs) / 1000.0)
    try session.overrideOutputAudioPort(.none)
    try session.setActive(true)

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    let tapFrames = AVAudioFrameCount(
      max(256, Int(inputFormat.sampleRate) * recordingFrameMs / 1000)
    )

    input.installTap(
      onBus: 0,
      bufferSize: tapFrames,
      format: inputFormat
    ) { [weak self] buffer, _ in
      self?.handleInputBuffer(buffer, inputFormat: inputFormat)
    }

    try engine.start()
    recordingEngine = engine
  }

  private func stopRecording(result: @escaping FlutterResult) {
    stopRecordingEngine()
    result(recordingStatus)
  }

  private func stopRecordingEngine() {
    if let engine = recordingEngine {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    recordingEngine = nil
    recordingPendingPcm.removeAll(keepingCapacity: true)
  }

  private func handleInputBuffer(
    _ buffer: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat
  ) {
    guard let channels = buffer.floatChannelData,
          buffer.frameLength > 0 else {
      recordingReadErrors += 1
      recordingLastReadError = "Missing float microphone channel data"
      return
    }

    let inputFrames = Int(buffer.frameLength)
    let channelCount = max(1, Int(inputFormat.channelCount))
    let outputFrames = max(
      1,
      Int(
        (Double(inputFrames) * Double(recordingSampleRate) /
          inputFormat.sampleRate).rounded()
      )
    )
    var pcm = Data(capacity: outputFrames * MemoryLayout<Int16>.size)

    for outputIndex in 0..<outputFrames {
      let inputPosition =
        Double(outputIndex) * inputFormat.sampleRate / Double(recordingSampleRate)
      let lowerIndex = min(inputFrames - 1, max(0, Int(inputPosition)))
      let upperIndex = min(inputFrames - 1, lowerIndex + 1)
      let fraction = Float(inputPosition - Double(lowerIndex))
      var sample: Float = 0

      for channel in 0..<channelCount {
        let channelData = channels[channel]
        let lower = channelData[lowerIndex]
        let upper = channelData[upperIndex]
        sample += lower + ((upper - lower) * fraction)
      }
      sample /= Float(channelCount)
      sample = min(1.0, max(-1.0, sample))
      var pcm16 = Int16(sample * 32767.0).littleEndian
      withUnsafeBytes(of: &pcm16) { bytes in
        pcm.append(contentsOf: bytes)
      }
    }

    appendRecordingPcm(pcm)
  }

  private func appendRecordingPcm(_ pcm: Data) {
    guard !pcm.isEmpty else {
      return
    }

    recordingPendingPcm.append(pcm)
    while recordingPendingPcm.count >= recordingFrameBytes {
      let frame = recordingPendingPcm.prefix(recordingFrameBytes)
      recordingPendingPcm.removeFirst(recordingFrameBytes)
      emitRecordingFrame(Data(frame))
    }
  }

  private func emitRecordingFrame(_ frame: Data) {
    recordingFramesRead += 1
    recordingBytesRead += frame.count
    recordingLastReadAtMs = Int(Date().timeIntervalSince1970 * 1000)

    guard let micEventSink else {
      return
    }

    let event: [String: Any] = [
      "pcm16": FlutterStandardTypedData(bytes: frame),
      "vadSource": "client",
      "vadMode": "dart_energy",
    ]
    DispatchQueue.main.async {
      micEventSink(event)
    }
  }

  private func startPlayback(call: FlutterMethodCall, result: FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let sampleRate = arguments?["sampleRate"] as? Int ?? 24_000
    let sessionId = arguments?["sessionId"] as? Int
    do {
      try startPlayback(sampleRate: sampleRate, sessionId: sessionId)
      result(true)
    } catch {
      result(
        FlutterError(
          code: "playback_start_failed",
          message: "Could not start iOS playback.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func writePlayback(call: FlutterMethodCall, result: FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let bytes = arguments["bytes"] as? FlutterStandardTypedData else {
      result(nil)
      return
    }
    if let sessionId = arguments["sessionId"] as? Int,
       sessionId != playbackSessionId {
      playbackDroppedStaleWrites += 1
      result(nil)
      return
    }

    do {
      try appendPcm16(bytes.data)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "playback_write_failed",
          message: "Could not write iOS playback audio.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func stopPlayback(call: FlutterMethodCall, result: FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    if let sessionId = arguments?["sessionId"] as? Int,
       sessionId != playbackSessionId {
      result(nil)
      return
    }
    stopPlayback()
    result(nil)
  }

  private func finishPlaybackStream(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    let arguments = call.arguments as? [String: Any]
    let requestedSessionId = arguments?["sessionId"] as? Int
    let timeoutMs = max(0, arguments?["timeoutMs"] as? Int ?? 30_000)

    if let requestedSessionId,
       requestedSessionId != playbackSessionId {
      var status = playbackStatus
      status["requestedSessionId"] = requestedSessionId
      status["stale"] = true
      status["drained"] = true
      status["timedOut"] = false
      status["stopped"] = false
      status["waitMs"] = 0
      result(status)
      return
    }

    playbackStreamClosed = true
    if isPlaybackDrained {
      var status = playbackStatus
      status["stale"] = false
      status["timedOut"] = false
      status["stopped"] = false
      status["waitMs"] = 0
      result(status)
      return
    }

    let waiter = PlaybackDrainWaiter(
      sessionId: playbackSessionId,
      startedAtMs: currentTimeMs,
      result: result
    )
    playbackDrainWaiters.append(waiter)

    if timeoutMs > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
        [weak self, weak waiter] in
        guard let self,
              let waiter,
              !waiter.completed else {
          return
        }
        self.completePlaybackDrainWaiter(
          waiter,
          drained: false,
          timedOut: true,
          stopped: false
        )
      }
    }
  }

  private func playDiagnosticTone(call: FlutterMethodCall, result: FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let sampleRate = max(8_000, arguments?["sampleRate"] as? Int ?? 24_000)
    let durationMs = min(2_000, max(80, arguments?["durationMs"] as? Int ?? 650))
    let frequency = max(120.0, min(2_000.0, arguments?["frequency"] as? Double ?? 660.0))
    let volume = max(0.02, min(0.80, arguments?["volume"] as? Double ?? 0.35))
    let sampleCount = max(1, sampleRate * durationMs / 1000)
    var pcm = Data(capacity: sampleCount * MemoryLayout<Int16>.size)

    for index in 0..<sampleCount {
      let position = Double(index) / Double(sampleRate)
      let fadeFrames = max(1, min(sampleRate / 40, sampleCount / 4))
      let fadeIn = min(1.0, Double(index) / Double(fadeFrames))
      let fadeOut = min(1.0, Double(sampleCount - index) / Double(fadeFrames))
      let envelope = min(fadeIn, fadeOut)
      let value = sin(2.0 * Double.pi * frequency * position) * volume * envelope
      var pcm16 = Int16(value * 32767.0).littleEndian
      withUnsafeBytes(of: &pcm16) { bytes in
        pcm.append(contentsOf: bytes)
      }
    }

    do {
      try startPlayback(sampleRate: sampleRate, sessionId: nil)
      try appendPcm16(pcm)
      playbackStreamClosed = true
      var status = playbackStatus
      status["diagnosticToneMs"] = durationMs
      status["diagnosticToneHz"] = frequency
      status["diagnosticToneBytes"] = pcm.count
      result(status)
    } catch {
      result(
        FlutterError(
          code: "diagnostic_tone_failed",
          message: "Could not play iOS diagnostic tone.",
          details: error.localizedDescription
        )
      )
    }
  }

  private func startPlayback(sampleRate: Int, sessionId: Int?) throws {
    let inputSampleRate = max(8_000, sampleRate)
    let outputSampleRate = max(inputSampleRate, 48_000)
    let nextSessionId = sessionId ?? (playbackSessionId + 1)
    if audioEngine != nil,
       playbackSessionId == nextSessionId,
       playbackInputSampleRate == inputSampleRate,
       playbackOutputSampleRate == outputSampleRate {
      if playerNode?.isPlaying != true {
        playerNode?.play()
      }
      return
    }

    stopPlayback(invalidateSession: false)
    playbackSessionId = nextSessionId
    resetPlaybackTracking()

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .spokenAudio,
      options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
    )
    try session.setPreferredSampleRate(Double(outputSampleRate))
    try session.overrideOutputAudioPort(.none)
    try session.setActive(true)

    guard let inputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(inputSampleRate),
      channels: 1,
      interleaved: false
    ) else {
      throw SparkAudioBridgeError.audioFormatUnavailable
    }

    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(outputSampleRate),
      channels: 1,
      interleaved: false
    ) else {
      throw SparkAudioBridgeError.audioFormatUnavailable
    }

    let converter = inputSampleRate == outputSampleRate
      ? nil
      : AVAudioConverter(from: inputFormat, to: format)
    converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = makeVocalPlaybackEq()
    engine.attach(player)
    engine.attach(eq)
    engine.connect(player, to: eq, format: format)
    engine.connect(eq, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.play()

    audioEngine = engine
    playerNode = player
    playbackEq = eq
    playbackInputFormat = inputFormat
    playbackFormat = format
    playbackConverter = converter
    playbackInputSampleRate = inputSampleRate
    playbackOutputSampleRate = outputSampleRate
  }

  private func appendPcm16(_ data: Data) throws {
    guard !data.isEmpty else {
      return
    }
    guard let inputFormat = playbackInputFormat,
          let format = playbackFormat,
          let player = playerNode else {
      playbackDroppedNoPlayerWrites += 1
      return
    }

    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0,
          let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
          ),
          let destination = inputBuffer.floatChannelData?.pointee else {
      throw SparkAudioBridgeError.audioFormatUnavailable
    }
    inputBuffer.frameLength = AVAudioFrameCount(sampleCount)

    data.withUnsafeBytes { rawBuffer in
      guard let source = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
        return
      }
      for index in 0..<sampleCount {
        destination[index] = Float(source[index]) / 32768.0
      }
    }

    let buffer = try convertPlaybackBuffer(inputBuffer, to: format)
    let scheduledFrameCount = Int(buffer.frameLength)
    guard scheduledFrameCount > 0 else {
      return
    }

    let sessionId = playbackSessionId
    playbackWriteCalls += 1
    playbackWrittenBytes += data.count
    playbackLastWriteBytes = data.count
    playbackInputFrames += sampleCount
    playbackScheduledBuffers += 1
    playbackScheduledFrames += scheduledFrameCount

    player.scheduleBuffer(
      buffer,
      completionCallbackType: .dataPlayedBack
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.notePlaybackBufferPlayed(
          sessionId: sessionId,
          frameCount: scheduledFrameCount
        )
      }
    }
    if !player.isPlaying {
      player.play()
    }
  }

  private func convertPlaybackBuffer(
    _ inputBuffer: AVAudioPCMBuffer,
    to outputFormat: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    guard let converter = playbackConverter else {
      return inputBuffer
    }

    let sampleRateRatio = outputFormat.sampleRate /
      max(1.0, inputBuffer.format.sampleRate)
    let outputCapacity = max(
      1,
      Int(ceil(Double(inputBuffer.frameLength) * sampleRateRatio)) + 32
    )
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: AVAudioFrameCount(outputCapacity)
    ) else {
      throw SparkAudioBridgeError.audioFormatUnavailable
    }

    var providedInput = false
    var conversionError: NSError?
    let conversionStartedAt = Date().timeIntervalSince1970
    let status = converter.convert(
      to: outputBuffer,
      error: &conversionError
    ) { _, outStatus in
      if providedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      providedInput = true
      outStatus.pointee = .haveData
      return inputBuffer
    }
    let conversionElapsedMs = max(
      0,
      Int((Date().timeIntervalSince1970 - conversionStartedAt) * 1000)
    )
    playbackResampleCalls += 1
    playbackTotalResampleMs += conversionElapsedMs
    playbackLastResampleMs = conversionElapsedMs

    if let conversionError {
      throw conversionError
    }
    if status == .error {
      throw SparkAudioBridgeError.audioFormatUnavailable
    }
    return outputBuffer
  }

  private func makeVocalPlaybackEq() -> AVAudioUnitEQ {
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    eq.globalGain = -0.5

    configureEqBand(
      eq.bands[0],
      type: .highPass,
      frequency: 85,
      bandwidth: 0.7,
      gain: 0
    )
    configureEqBand(
      eq.bands[1],
      type: .parametric,
      frequency: 260,
      bandwidth: 1.0,
      gain: -1.6
    )
    configureEqBand(
      eq.bands[2],
      type: .parametric,
      frequency: 3_200,
      bandwidth: 0.85,
      gain: 1.8
    )
    configureEqBand(
      eq.bands[3],
      type: .highShelf,
      frequency: 7_500,
      bandwidth: 1.0,
      gain: 0.8
    )

    return eq
  }

  private func configureEqBand(
    _ band: AVAudioUnitEQFilterParameters,
    type: AVAudioUnitEQFilterType,
    frequency: Float,
    bandwidth: Float,
    gain: Float
  ) {
    band.filterType = type
    band.frequency = frequency
    band.bandwidth = bandwidth
    band.gain = gain
    band.bypass = false
  }

  private func stopPlayback(invalidateSession: Bool = true) {
    completePlaybackDrainWaiters(
      drained: false,
      timedOut: false,
      stopped: true
    )
    if invalidateSession {
      playbackSessionId += 1
    }
    playerNode?.stop()
    audioEngine?.stop()
    if let playerNode {
      audioEngine?.detach(playerNode)
    }
    if let playbackEq {
      audioEngine?.detach(playbackEq)
    }
    playerNode = nil
    playbackEq = nil
    audioEngine = nil
    playbackInputFormat = nil
    playbackFormat = nil
    playbackConverter = nil
    playbackInputSampleRate = 0
    playbackOutputSampleRate = 0
    resetPlaybackTracking()
  }

  private var isPlaybackDrained: Bool {
    playbackStreamClosed && playbackScheduledBuffers <= playbackPlayedBuffers
  }

  private var currentTimeMs: Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  private func notePlaybackBufferPlayed(sessionId: Int, frameCount: Int) {
    guard sessionId == playbackSessionId else {
      return
    }
    playbackPlayedBuffers += 1
    playbackPlayedFrames += frameCount
    completePlaybackDrainWaitersIfReady()
  }

  private func completePlaybackDrainWaitersIfReady() {
    guard isPlaybackDrained else {
      return
    }
    let waiters = playbackDrainWaiters.filter {
      $0.sessionId == playbackSessionId && !$0.completed
    }
    for waiter in waiters {
      completePlaybackDrainWaiter(
        waiter,
        drained: true,
        timedOut: false,
        stopped: false
      )
    }
  }

  private func completePlaybackDrainWaiters(
    drained: Bool,
    timedOut: Bool,
    stopped: Bool
  ) {
    let waiters = playbackDrainWaiters.filter { !$0.completed }
    for waiter in waiters {
      completePlaybackDrainWaiter(
        waiter,
        drained: drained,
        timedOut: timedOut,
        stopped: stopped
      )
    }
  }

  private func completePlaybackDrainWaiter(
    _ waiter: PlaybackDrainWaiter,
    drained: Bool,
    timedOut: Bool,
    stopped: Bool
  ) {
    guard !waiter.completed else {
      return
    }
    waiter.completed = true
    playbackDrainWaiters.removeAll { $0 === waiter }

    var status = playbackStatus
    status["waitMs"] = max(0, currentTimeMs - waiter.startedAtMs)
    status["drained"] = drained
    status["timedOut"] = timedOut
    status["stopped"] = stopped
    status["stale"] = waiter.sessionId != playbackSessionId
    waiter.result(status)
  }

  private func resetPlaybackTracking() {
    playbackStreamClosed = false
    playbackScheduledBuffers = 0
    playbackPlayedBuffers = 0
    playbackScheduledFrames = 0
    playbackPlayedFrames = 0
    playbackInputFrames = 0
    playbackResampleCalls = 0
    playbackTotalResampleMs = 0
    playbackLastResampleMs = 0
    playbackWriteCalls = 0
    playbackWrittenBytes = 0
    playbackLastWriteBytes = 0
    playbackDroppedNoPlayerWrites = 0
    playbackDroppedStaleWrites = 0
  }
}

extension SparkAudioBridge: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    micEventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    micEventSink = nil
    return nil
  }
}

private enum SparkAudioBridgeError: Error {
  case audioFormatUnavailable
  case microphonePermissionDenied
}

private final class PlaybackDrainWaiter {
  init(
    sessionId: Int,
    startedAtMs: Int,
    result: @escaping FlutterResult
  ) {
    self.sessionId = sessionId
    self.startedAtMs = startedAtMs
    self.result = result
  }

  let sessionId: Int
  let startedAtMs: Int
  let result: FlutterResult
  var completed = false
}
