@preconcurrency import AVFoundation

/// An object that provides the interface to control audio playback.
public final actor AudioPlayer {
    private var connected: [AudioPlayerNode: Bool] = [:]
    private var audioEngine: AVAudioEngine?
    private var playerNodes: [AudioPlayerNode: AVAudioPlayerNode] = [:]

    /// Create an audio player object.
    public init(audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
    }

    func isConnected(_ playerNode: AudioPlayerNode) -> Bool {
        return connected[playerNode] == true
    }

    func connect(_ playerNode: AudioPlayerNode, format: AVAudioFormat?) {
        guard let audioEngine, let avPlayerNode = playerNodes[playerNode] else {
            return
        }
        if let format {
            // mainMixerNode, not outputNode: a direct connection to outputNode requires
            // the format to match the hardware's actual I/O format exactly (no implicit
            // conversion), while mainMixerNode safely accepts an arbitrary input format
            // (here, whatever the remote encoder's sample rate/channel layout is).
            audioEngine.connect(avPlayerNode, to: audioEngine.mainMixerNode, format: format)
            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                } catch {
                    print("[AudioPlayerDiag] engine.start() failed:", error, "format:", format)
                }
            }
            connected[playerNode] = true
        } else {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.disconnectNodeOutput(avPlayerNode)
            connected[playerNode] = nil
        }
    }

    func detach(_ playerNode: AudioPlayerNode) {
        if let playerNode = playerNodes[playerNode] {
            audioEngine?.detach(playerNode)
        }
        playerNodes[playerNode] = nil
    }

    func makePlayerNode() -> AudioPlayerNode {
        let avAudioPlayerNode = AVAudioPlayerNode()
        audioEngine?.attach(avAudioPlayerNode)
        let playerNode = AudioPlayerNode(player: self, playerNode: avAudioPlayerNode)
        playerNodes[playerNode] = avAudioPlayerNode
        return playerNode
    }
}
