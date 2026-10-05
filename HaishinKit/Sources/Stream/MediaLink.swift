import CoreMedia
import Foundation

final actor MediaLink {
    static let capacity = 90
    static let duration: TimeInterval = 0.0

    var dequeue: AsyncStream<CMSampleBuffer> {
        AsyncStream { continutation in
            self.continutation = continutation
        }
    }
    private(set) var isRunning = false
    private var storage: TypedBlockQueue<CMSampleBuffer>?
    private var continutation: AsyncStream<CMSampleBuffer>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var duration: TimeInterval = MediaLink.duration
    private var presentationTimeStampOrigin: CMTime = .invalid
    private lazy var displayLink = DisplayLinkChoreographer()
    private weak var audioPlayer: AudioPlayerNode?

    init() {
        do {
            storage = try .init(capacity: Self.capacity, handlers: .outputPTSSortedSampleBuffers)
        } catch {
            logger.error(error)
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        if presentationTimeStampOrigin == .invalid {
            presentationTimeStampOrigin = sampleBuffer.presentationTimeStamp
        }
        do {
            try storage?.enqueue(sampleBuffer)
        } catch {
            logger.error(error)
        }
    }

    func setAudioPlayer(_ audioPlayer: AudioPlayerNode?) {
        self.audioPlayer = audioPlayer
    }

    private func getCurrentTime(_ timestamp: TimeInterval) async -> TimeInterval {
        defer {
            duration += timestamp
        }
        // AudioPlayerNode.currentTime is 0.0 (not nil) whenever its node isn't
        // playing: no audio in the stream, audio not yet pre-rolled, or the
        // engine stopped by an audio route/configuration change. Paced off a
        // 0 clock, only the first frame is ever released and the queue fills
        // (-12764 on every enqueue) - a frozen picture (SRTstreamer fix,
        // 2026-10-05). Fall back to the display-link clock instead.
        let audioTime = await audioPlayer?.currentTime ?? 0
        return 0 < audioTime ? audioTime : duration
    }
}

extension MediaLink: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        duration = 0.0
        displayLink.startRunning()
        Task {
            for await currentTime in displayLink.updateFrames {
                guard let storage else {
                    continue
                }
                let currentTime = await getCurrentTime(currentTime.targetTimestamp - currentTime.timestamp)
                var frameCount = 0
                while !storage.isEmpty {
                    guard let first = storage.head else {
                        break
                    }
                    if first.presentationTimeStamp.seconds - presentationTimeStampOrigin.seconds <= currentTime {
                        continutation?.yield(first)
                        frameCount += 1
                        _ = storage.dequeue()
                    } else {
                        if 2 < frameCount {
                            logger.info("droppedFrame: \(frameCount)")
                        }
                        break
                    }
                }
            }
        }
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        continutation = nil
        displayLink.stopRunning()
        presentationTimeStampOrigin = .invalid
        try? storage?.reset()
        isRunning = false
    }
}
