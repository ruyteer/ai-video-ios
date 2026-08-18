import AVFoundation
import EditorCore

enum CompositionBuildError: Error {
    case emptyKeepRanges
    case noVideoTrack
}

/// Monta o corte como lista de edição (`AVMutableComposition`), não como
/// re-encode — cada trecho a manter é inserido por referência de tempo no
/// asset original, sem tocar em pixel nenhum (ver PLANO.md seção 4).
enum CompositionBuilder {
    static func build(asset: AVAsset, keepRanges: [KeepRange]) async throws -> AVMutableComposition {
        guard !keepRanges.isEmpty else { throw CompositionBuildError.emptyKeepRanges }

        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceVideoTrack = sourceVideoTracks.first else {
            throw CompositionBuildError.noVideoTrack
        }
        let sourceAudioTrack = sourceAudioTracks.first

        let composition = AVMutableComposition()
        let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let compositionAudioTrack = sourceAudioTrack != nil
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        // Preserva a orientação do vídeo original (ex: gravação em pé) — sem
        // isso o export sairia deitado mesmo que o original não fosse.
        compositionVideoTrack?.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        var cursor = CMTime.zero
        for range in keepRanges {
            let start = CMTime(seconds: range.start, preferredTimescale: 600)
            let duration = CMTime(seconds: range.duration, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: start, duration: duration)

            try compositionVideoTrack?.insertTimeRange(timeRange, of: sourceVideoTrack, at: cursor)
            if let compositionAudioTrack, let sourceAudioTrack {
                try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: cursor)
            }
            cursor = cursor + duration
        }

        return composition
    }
}
