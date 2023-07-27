//
//  Copyright 2021-2023 Picovoice Inc.
//  You may not use this file except in compliance with the license. A copy of the license is located in the "LICENSE"
//  file accompanying this source.
//  Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
//  an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
//  specific language governing permissions and limitations under the License.
//

import AVFoundation

/// Typealias for the callback function that handles frames of audio data.
public typealias VoiceProcessorFrameCallback = ([Int16]) -> ()

/// Listener class for receiving audio frames from `VoiceProcessor` via the `onFrame` property.
public class VoiceProcessorFrameListener {
    private let callback_: VoiceProcessorFrameCallback

    /// Initializes a new `VoiceProcessorFrameListener`.
    ///
    /// - Parameter callback: The callback function to be called when an audio frame is received.
    public init(_ callback: @escaping VoiceProcessorFrameCallback) {
        callback_ = callback
    }

    /// Function called when a frame of audio is received.
    public var onFrame: VoiceProcessorFrameCallback {
        get {
            callback_
        }
    }
}

/// Typealias for the callback function that handles errors that are emitted from `VoiceProcessor`.
public typealias VoiceProcessorErrorCallback = (VoiceProcessorError) -> ()

/// Listener class for receiving errors from `VoiceProcessor` via the `onError` property.
public class VoiceProcessorErrorListener {
    private let callback_: VoiceProcessorErrorCallback

    /// Initializes a new `VoiceProcessorErrorListener`.
    ///
    /// - Parameter callback: The callback function to be called when a `VoiceProcessorError` occurs.
    public init(_ callback: @escaping VoiceProcessorErrorCallback) {
        callback_ = callback
    }
    
    /// Function called when a `VoiceProcessorError` occurs.
    public var onError: VoiceProcessorErrorCallback {
        get {
            callback_
        }
    }
}

///
public class VoiceProcessor {
    
    /// The singleton instance of `VoiceProcessor`.
    public static let instance: VoiceProcessor = VoiceProcessor()

    private let lock = NSLock()
    private let numBuffers = 3
    private var audioQueue: AudioQueueRef!
    private var bufferList = [AudioQueueBufferRef?](repeating: nil, count: 3)
    private var circularBuffer: VoiceProcessorBuffer?

    private var frameListeners: [VoiceProcessorFrameListener] = []
    private var errorListeners: [VoiceProcessorErrorListener] = []

    private var isRecording_: Bool = false
    private var frameLength_: UInt32? = nil
    private var sampleRate_: UInt32? = nil
    
    /// A boolean value indicating if the `VoiceProcessor` is currently recording audio.
    public var isRecording: Bool {
        isRecording_
    }

    /// The number of audio samples per frame. Set when calling the `start(frameLength:sampleRate:)` method.
    public var frameLength: UInt32? {
        frameLength_
    }

    /// The sample rate for audio recording, set when calling the `start(frameLength:sampleRate:)` method.
    public var sampleRate: UInt32? {
        sampleRate_
    }

    /// The number of registered `VoiceProcessorFrameListeners`.
    public var numFrameListeners: Int {
        frameListeners.count
    }
    
    /// The number of registered `VoiceProcessorErrorListeners`.
    public var numErrorListeners: Int {
        errorListeners.count
    }

    private init() {
        NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleInterruption),
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance())
    }

    /// Indicates whether the app has permission to record audio.
    public static var hasRecordAudioPermission: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// Requests permission to record audio from the user.
    ///
    /// - Parameter response: A closure to handle the user's response to the permission request.
    public static func requestRecordAudioPermission(_ response: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission(response)
    }

    /// Adds a listener to receive audio frames.
    ///
    /// - Parameter listener: The `VoiceProcessorFrameListener` to be added as a frame listener.
    public func addFrameListener(_ listener: VoiceProcessorFrameListener) {
        lock.lock()
        frameListeners.append(listener)
        lock.unlock()
    }

    /// Adds multiple frame listeners to receive audio frames.
    ///
    /// - Parameter listeners: An array of `VoiceProcessorFrameListener` to be added as frame listeners.
    public func addFrameListeners(_ listeners: [VoiceProcessorFrameListener]) {
        lock.lock()
        frameListeners.append(contentsOf: listeners)
        lock.unlock()
    }

    /// Removes a previously added frame listener.
    ///
    /// - Parameter listener: The `VoiceProcessorFrameListener` to be removed.
    public func removeFrameListener(_ listener: VoiceProcessorFrameListener) {
        lock.lock()
        frameListeners.removeAll {
            $0 === listener
        }
        lock.unlock()
    }

    /// Removes previously added multiple frame listeners.
    ///
    /// - Parameter listeners: An array of `VoiceProcessorFrameListener` to be removed.
    public func removeFrameListeners(_ listeners: [VoiceProcessorFrameListener]) {
        lock.lock()
        for listener in listeners {
            frameListeners.removeAll {
                $0 === listener
            }
        }
        lock.unlock()
    }

    /// Clears all currently registed frame listeners.
    public func clearFrameListeners() {
        lock.lock()
        frameListeners.removeAll()
        lock.unlock()
    }

    // Adds an error listener.
    ///
    /// - Parameter listener: The `VoiceProcessorErrorListener` to be added as an error listener.
    public func addErrorListener(_ listener: VoiceProcessorErrorListener) {
        lock.lock()
        errorListeners.append(listener)
        lock.unlock()
    }

    /// Removes a previously added error listener.
    ///
    /// - Parameter listener: The `VoiceProcessorErrorListener` to be removed.
    public func removeErrorListener(_ listener: VoiceProcessorErrorListener) {
        lock.lock()
        errorListeners.removeAll {
            $0 === listener
        }
        lock.unlock()
    }

    /// Clears all error listeners.
    public func clearErrorListeners() {
        lock.lock()
        errorListeners.removeAll()
        lock.unlock()
    }

    /// Starts audio recording with the specified audio properties.
    ///
    /// - Parameters:
    ///   - frameLength: The length of each audio frame, in number of samples.
    ///   - sampleRate: The sample rate to record audio at, in Hz.
    /// - Throws: An error if there is an issue starting the audio recording.
    public func start(frameLength: UInt32, sampleRate: UInt32) throws {
        if frameLength == 0 {
            throw VoiceProcessorArgumentError("Frame length cannot be zero.")
        }

        if sampleRate == 0 {
            throw VoiceProcessorArgumentError("Sample Rate cannot be zero.")
        }

        circularBuffer = VoiceProcessorBuffer(size: Int(frameLength * 10))
        if isRecording_ {
            if (frameLength != frameLength_ || sampleRate != sampleRate_) {
                throw VoiceProcessorArgumentError("""
                                                  VoiceProcessor start() was called with frame length
                                                  \(frameLength) and sample rate \(sampleRate) while already recording
                                                  with frame length \(frameLength_!) and sample rate \(sampleRate_!).
                                                  """)
            } else {
                return
            }
        }

        frameLength_ = frameLength
        sampleRate_ = sampleRate

        do {
            try AVAudioSession.sharedInstance().setCategory(
                    AVAudioSession.Category.playAndRecord,
                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(
                    true,
                    options: .notifyOthersOnDeactivation)
        } catch {
            throw VoiceProcessorRuntimeError("Unable to capture audio session.")
        }

        var format = AudioStreamBasicDescription()
        format.mSampleRate = Float64(sampleRate)
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        format.mBytesPerPacket = 2
        format.mFramesPerPacket = 1
        format.mChannelsPerFrame = 1
        format.mBitsPerChannel = 16
        format.mBytesPerPacket = 2
        format.mBytesPerFrame = 2
        format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AudioQueueNewInput(&format, createAudioQueueCallback(), userData, nil, nil, 0, &audioQueue)

        let bufferSize = frameLength * format.mBytesPerFrame
        for i in 0..<numBuffers {
            AudioQueueAllocateBuffer(audioQueue, bufferSize, &bufferList[i])
            AudioQueueEnqueueBuffer(audioQueue, bufferList[i]!, 0, nil)
        }

        AudioQueueStart(audioQueue, nil)
        isRecording_ = true
    }

    /// Stops audio recording and releases audio resources.
    ///
    /// - Throws: An error if there is an issue stopping the audio recording.
    public func stop() throws {
        if !isRecording_ {
            return
        }
        guard let audioQueue = audioQueue else {
            throw VoiceProcessorRuntimeError("Audio queue is nil")
        }
        AudioQueueFlush(audioQueue)
        AudioQueueStop(audioQueue, true)
        AudioQueueDispose(audioQueue, true)
        isRecording_ = false
    }

    private func createAudioQueueCallback() -> AudioQueueInputCallback {
        { userData, queue, bufferRef, startTimeRef, numPackets, packetDescriptions in
            let `self` = Unmanaged<VoiceProcessor>.fromOpaque(userData!).takeUnretainedValue()

            guard let frameLength = self.frameLength_ else {
                self.onError(VoiceProcessorRuntimeError("Unable to get audio frame: frame length is nil"))
                return
            }

            guard let circularBuffer = self.circularBuffer else {
                self.onError(VoiceProcessorRuntimeError("Unable to get audio frame: circular buffer is nil"))
                return
            }

            let bufferPtr = bufferRef.pointee.mAudioData.bindMemory(to: Int16.self, capacity: Int(bufferRef.pointee.mAudioDataByteSize) / MemoryLayout<Int16>.size)
            let samples = Array(UnsafeBufferPointer(start: bufferPtr, count: Int(numPackets)))

            do {
                try circularBuffer.write(samples: Array(samples))
            } catch let error as VoiceProcessorError {
                self.onError(error)
            } catch {
                print("Unknown error encountered")
                return
            }

            if circularBuffer.availableSamples() >= frameLength {
                let frame = circularBuffer.read(count: Int(frameLength))
                if (frame.count != frameLength) {
                    self.onError(VoiceProcessorReadError("Circular buffer returned a frame of size \(frame.count) (frameLength is \(frameLength))"))
                }
                self.onFrame(frame)
            }

            AudioQueueEnqueueBuffer(queue, bufferRef, 0, nil)
        }
    }

    @objc private func handleInterruption(_ notification: NSNotification) {
        guard isRecording_ else {
            return
        }
        guard let audioQueue = audioQueue else {
            onError(VoiceProcessorRuntimeError("Unable to handle interruption: Audio queue was nil"))
            return
        }

        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            onError(VoiceProcessorRuntimeError("Unable to handle interruption: Notification info was nil"))
            return
        }

        if type == .ended {
            guard let optionsValue =
            info[AVAudioSessionInterruptionOptionKey] as? UInt else {
                onError(VoiceProcessorRuntimeError("Unable to handle interruption: Options key was nil"))
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                for i in 0..<numBuffers {
                    AudioQueueEnqueueBuffer(audioQueue, bufferList[i]!, 0, nil)
                }

                AudioQueueStart(audioQueue, nil)
            }

        } else if type == .began {
            AudioQueueStop(audioQueue, true)
        }
    }

    private func onFrame(_ frame: [Int16]) {
        lock.lock()
        for listener in frameListeners {
            DispatchQueue.main.async {
                listener.onFrame(frame)
            }
        }
        lock.unlock()
    }

    private func onError(_ error: VoiceProcessorError) {
        lock.lock()
        for listener in errorListeners {
            DispatchQueue.main.async {
                listener.onError(error)
            }
        }
        lock.unlock()
    }
}
