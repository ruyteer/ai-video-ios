import Speech
import EditorCore

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Permissão de reconhecimento de fala negada. Ative em Ajustes > Privacidade e Segurança > Reconhecimento de Fala > ViralClip."
        case .recognizerUnavailable:
            return "Reconhecimento de fala em português não está disponível neste aparelho agora."
        case .failed(let reason):
            return "Falha na transcrição: \(reason)"
        }
    }
}

struct TranscriptionResult {
    let words: [TranscriptWord]
    /// false quando a transcrição só deu certo caindo pro servidor da
    /// Apple — ver comentário em `transcribe`. A UI usa isso pra avisar
    /// que essa transcrição específica não ficou 100% no aparelho.
    let wasOnDevice: Bool
}

enum Transcriber {
    /// Fixo em pt-BR (decisão do usuário — ver PLANO.md Fase 2, não é
    /// configurável na UI). Transcreve o vídeo JÁ CORTADO (ver PLANO.md
    /// seção 3: a transcrição roda depois do corte de silêncio, não antes —
    /// senão os timestamps das palavras não bateriam com o vídeo final).
    static func transcribe(url: URL) async throws -> TranscriptionResult {
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

        // Prefere reconhecimento no aparelho, pra não mandar áudio pra
        // servidor nenhum (filosofia "tudo local" do resto do app) — mas
        // `isAvailable`/`supportsOnDeviceRecognition` têm um bug conhecido
        // do iOS onde retornam true mesmo quando o reconhecimento local vai
        // falhar de fato (erro "Siri and Dictation are disabled", que
        // acontece se o usuário tem o Dictation do sistema desligado em
        // Ajustes > Geral > Teclado, mesmo com a permissão do app OK). Em
        // vez de propagar esse erro sem alternativa, tenta local primeiro
        // e cai pro servidor da Apple só se isso falhar — a UI avisa
        // quando isso acontece (ver `wasOnDevice`), não é um fallback
        // silencioso.
        if recognizer.supportsOnDeviceRecognition {
            if let words = try? await runRecognition(recognizer: recognizer, url: url, requireOnDevice: true) {
                return TranscriptionResult(words: words, wasOnDevice: true)
            }
        }

        let words = try await runRecognition(recognizer: recognizer, url: url, requireOnDevice: false)
        return TranscriptionResult(words: words, wasOnDevice: false)
    }

    private static func runRecognition(
        recognizer: SFSpeechRecognizer,
        url: URL,
        requireOnDevice: Bool
    ) async throws -> [TranscriptWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = requireOnDevice

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
