@preconcurrency import AVFoundation
import Foundation

final actor AudioPlayerNode {
    static let bufferCounts: Int = 10

    var currentTime: TimeInterval {
        if playerNode.isPlaying {
            guard
                let nodeTime = playerNode.lastRenderTime,
                let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return 0.0
            }
            return TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
        }
        return 0.0
    }
    private(set) var isPaused = false
    private(set) var isRunning = false
    private(set) var soundTransfrom = SoundTransform()
    private let playerNode: AVAudioPlayerNode
    private var audioTime = AudioTime()
    private var scheduledAudioBuffers: Int = 0
    private var isBuffering = true
    private weak var player: AudioPlayer?
    private var format: AVAudioFormat? {
        didSet {
            guard format != oldValue else {
                return
            }
            Task { [format] in
                await player?.connect(self, format: format)
            }
        }
    }

    init(player: AudioPlayer, playerNode: AVAudioPlayerNode) {
        self.player = player
        self.playerNode = playerNode
    }

    func setSoundTransfrom(_ soundTransfrom: SoundTransform) {
        soundTransfrom.apply(playerNode)
        self.soundTransfrom = soundTransfrom
    }

    func enqueue(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) async {
        format = audioBuffer.format
        guard let audioBuffer = audioBuffer as? AVAudioPCMBuffer, await player?.isConnected(self) == true else {
            return
        }
        if !audioTime.hasAnchor {
            audioTime.anchor(playerNode.lastRenderTime ?? AVAudioTime(hostTime: 0))
        }
        scheduledAudioBuffers += 1
        if !isPaused && !playerNode.isPlaying && Self.bufferCounts <= scheduledAudioBuffers {
            playerNode.play()
        }
        Task {
            audioTime.advanced(Int64(audioBuffer.frameLength))
            // Was `at: audioTime.at`. audioTime anchors once per session off
            // `playerNode.lastRenderTime ?? AVAudioTime(hostTime: 0)`, taken before the
            // node has ever rendered anything, so lastRenderTime is nil and this
            // anchors at the mach host-time epoch - a timestamp the render clock can
            // never actually reach. scheduleBuffer's async completion depends on
            // reaching the given time, so with that anchor it never returned, for any
            // buffer, ever: scheduledAudioBuffers grew unboundedly all session, and
            // nothing was audible despite the engine running and isPlaying == true.
            // nil lets the node queue buffers back-to-back in its own arrival order,
            // using its own real clock - confirmed fixed on device (2026-10-04).
            await playerNode.scheduleBuffer(audioBuffer, at: nil)
            scheduledAudioBuffers -= 1
            if scheduledAudioBuffers == 0 {
                isBuffering = true
            }
        }
    }

    func detach() async {
        stopRunning()
        await player?.detach(self)
    }
}

extension AudioPlayerNode: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() {
        guard !isRunning else {
            return
        }
        scheduledAudioBuffers = 0
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        if playerNode.isPlaying {
            playerNode.stop()
            playerNode.reset()
        }
        audioTime.reset()
        format = nil
        isRunning = false
    }
}

extension AudioPlayerNode: Hashable {
    // MARK: Hashable
    nonisolated public static func == (lhs: AudioPlayerNode, rhs: AudioPlayerNode) -> Bool {
        lhs === rhs
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
