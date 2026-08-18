import Speech
import EditorCore

enum TranscriptionError: Error {
    case notAuthorized
    case recognizerUnavailable
    case failed(String)
}

enum Transcriber {
    /// Fixo em pt-BR (decisão do usuário — ver PLANO.md Fase 2, não é
    /// configurável na UI). Transcreve o vídeo JÁ CORTADO (ver PLANO.md
    /// seção 3: a transcrição roda depois do corte de silêncio, não antes —
    /// senão os timestamps das palavras não bateriam com o vídeo final).
    /// Prefere reconhecimento no aparelho quando disponível, pra não
    /// depender de rede nem mandar áudio pra servidor nenhum — mesma
    /// filosofia "tudo local" do resto do app.
    static func transcribe(url: URL) async throws -> [TranscriptWord] {
        let authStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-BR")), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            // O resultHandler pode ser chamado mais de uma vez mesmo com
            // shouldReportPartialResults = false (ex: um erro antes de
            // qualquer resultado) — a flag evita resumir a continuation
            // duas vezes, que travaria o processo.
            var didResume = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let error {
                    didResume = true
                    continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                didResume = true
                continuation.resume(returning: result)
            }
        }

        return result.bestTranscription.segments.map { segment in
            TranscriptWord(
                text: segment.substring,
                start: segment.timestamp,
                end: segment.timestamp + segment.duration
            )
        }
    }
}
