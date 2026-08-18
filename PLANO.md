# Plano — Editor Automático de Vídeos (iOS/Swift nativo)

## 0. Relação com o projeto irmão

Este é um projeto **novo e separado** de `ai-video` (a versão web/local em
Python + Remotion, que continua existindo do jeito que está). O motivo da
existência deste projeto: o gargalo real medido na versão web é a composição
de frames via Chromium headless, que roda em software e não é acelerada por
GPU. Num app iOS nativo, a composição roda sobre Core Animation/Metal e o
encode sobre o media engine dedicado do chip da Apple — sem navegador nenhum
no caminho.

**Restrições reais que moldam este plano inteiro:**

1. **Não há Mac disponível.** Todo o fluxo de desenvolvimento foi desenhado
   em volta disso — não é detalhe secundário, é a decisão de arquitetura mais
   importante do documento (ver seção 2).
2. **O corte deve ser não-destrutivo, não um re-encode.** Descoberto durante
   o planejamento (não era óbvio de início): cortar silêncio reencodando o
   vídeo inteiro — que é como a versão web faz hoje — é inerentemente lento e
   escala com a resolução. Cortar como uma **lista de edição**
   (`AVMutableComposition`) que só referencia trechos do vídeo original, sem
   tocar em pixel nenhum, é independente de resolução — é por isso que dá pra
   cortar um vídeo em 8K em segundos. Essa é a arquitetura do corte deste
   projeto desde o início, não uma otimização posterior (ver seção 4).

---

## 1. Objetivo

Um app iOS que recebe um vídeo cru (gravado no próprio iPhone ou importado) e
devolve um vídeo pronto pra postar — cortes automáticos de silêncio, legenda
animada estilo "viral", zoom de ênfase, efeitos sonoros/visuais — 100%
nativo, rodando direto no aparelho, sem servidor.

**Ordem de construção pedida: uma ferramenta de cada vez, funcionando de
ponta a ponta, antes de somar a próxima.** Primeiro só corte. Depois legenda.
Depois o resto. Nada de construir as quatro coisas em paralelo sem a
primeira estar validada em vídeo real.

---

## 2. O problema do "sem Mac", resolvido por camada

### 2.1. Lógica pura (corte, heurística, timestamps) — desenvolve no Windows, sem CI, sem iPhone

Swift tem toolchain oficial pra Windows (`swift.org`) — **já instalado nesta
máquina**. Lógica escrita como um Swift Package separado (`EditorCore`), sem
NENHUM import exclusivo da Apple (nada de `UIKit`/`AVFoundation`/`SwiftUI` —
só `Foundation` puro), roda e testa com `swift test` local, em segundos,
igual `pytest` no projeto Python. Estratégia de escopo: **tudo que puder ser
lógica pura, deve ser lógica pura**, pra maximizar o que dá pra desenvolver
rápido sem depender de CI.

### 2.2. UI e composição de vídeo (SwiftUI, AVFoundation, Core Animation) — só valida via CI + iPhone físico

1. GitHub Actions (`macos-latest`) roda `xcodegen generate` → `xcodebuild`
   (`CODE_SIGNING_ALLOWED=NO`, sem certificado nenhum) → empacota um `.ipa`
   **não assinado** como artefato.
2. Você baixa o `.ipa` e usa o **AltServer/AltStore** (grátis, roda no
   Windows) pra assinar com seu Apple ID grátis e instalar no iPhone via
   cabo USB. Testado nesta máquina: o Sideloadly (a alternativa mais citada
   por aí) falha aqui com um erro de Anisette local (`iTunesCore.dll` não
   encontrado, provavelmente antivírus colocando o DLL em quarentena) — o
   AltServer é quem funcionou de fato, e é o caminho documentado neste
   projeto a partir daqui. Detalhe não óbvio do AltServer no Windows: pra
   instalar um `.ipa` próprio (não o AltStore em si), segura **Shift** e
   clica no ícone do AltServer na bandeja pra abrir o menu escondido
   "Sideload .ipa…".
3. **Limitação real, sem meio-termo:** apps assinados com Apple ID grátis
   expiram em 7 dias — reinstala toda semana.
4. **O que se perde nesse fluxo:** preview ao vivo de SwiftUI, breakpoint,
   log em tempo real. Cada ajuste visual custa minutos (build na nuvem +
   baixar + reinstalar), não segundos. É a única camada que sofre de verdade
   com a ausência de Mac — só dá pra minimizar quanto código vive aqui (2.1).

### 2.3. Xcode sem nunca abrir o Xcode

**XcodeGen** (`project.yml`, YAML puro, versionado no git) gera o
`.xcodeproj` como primeiro passo do workflow do GitHub Actions. Nunca precisa
abrir Xcode pra criar/manter a estrutura do projeto.

---

## 3. Pipeline (uma etapa de cada vez, nesta ordem)

```
1. Corte automático de silêncio     → AVMutableComposition (não-destrutivo)
2. Transcrição do vídeo já cortado  → Speech framework (on-device)
3. Legenda animada + zoom de ênfase → Core Animation, dirigido pelos timestamps
4. Efeitos sonoros/visuais          → trilhas extras + Core Image
5. Export final                     → AVAssetExportSession (hardware encode)
```

Sem backend separado: tudo roda dentro do próprio app. O "backend" é o
módulo `EditorCore` in-process.

---

## 4. O corte: como fica rápido de verdade (independente de resolução)

Isto é o núcleo técnico da Fase 1 — vale detalhar antes de generalizar pro
resto:

1. **Detecção de silêncio** (`EditorCore`, lógica pura): ler o áudio como
   amostras PCM (`AVAssetReader` extrai, `EditorCore` só recebe o array de
   amostras — a extração em si é a única parte que precisa de AVFoundation),
   rodar RMS numa janela deslizante, marcar trechos abaixo de um limiar por
   tempo mínimo como silêncio, devolver os **trechos a manter** (não os
   cortados) com uma margem de padding em cada borda.
2. **Montagem do corte** (`ViralClip`, AVFoundation): para cada trecho a
   manter, inserir o intervalo correspondente do `AVAsset` original numa
   `AVMutableComposition` — é cópia de referência, não de pixel.
3. **Export**: tentar `AVAssetExportPresetPassthrough` primeiro (remux puro,
   sem re-encode — é o que torna o corte independente de resolução). Ressalva
   real, não hipotética: cortes que caem no meio de um GOP (não num keyframe)
   podem perder precisão no passthrough puro — a validar com medição real na
   Fase 1, não assumir. Se acontecer, o fallback é re-encodar só nos
   pedacinhos ao redor de cada corte impreciso, não o vídeo inteiro.

Isso substitui totalmente o modelo da versão web (que reencoda tudo via
`auto-editor`, mesmo acelerado por NVENC) — aqui a meta não é acelerar o
re-encode, é não precisar de re-encode nenhum.

---

## 5. Arquitetura do projeto

```
ai-video-ios/
├── project.yml                    # XcodeGen — gera o .xcodeproj no CI
├── EditorCore/                    # Swift Package PURO — roda/testa no Windows
│   ├── Package.swift
│   ├── Sources/EditorCore/
│   │   └── SilenceDetection.swift # RMS + trechos a manter (Fase 1)
│   └── Tests/EditorCoreTests/
├── ViralClip/                     # o app iOS — só compõe/exibe
│   ├── ViralClipApp.swift
│   ├── Pipeline/                  # AVFoundation: extrai PCM, monta composição, exporta
│   └── UI/                        # SwiftUI
└── .github/workflows/
    └── build-and-package.yml
```

---

## 6. Fases (reduzidas ao essencial — uma ferramenta funcionando por vez)

**Fase 1 — Corte, ponta a ponta**
Bootstrap do projeto (XcodeGen + workflow do CI + validar AltServer com um
app mínimo) + `SilenceDetection` em `EditorCore` (testado no Windows) +
composição/export não-destrutivo no app. Entregável: escolher um vídeo da
galeria, cortar silêncio, exportar, salvar. **Sem legenda, sem transcrição,
sem zoom ainda.**

**Fase 2 — Legenda**
Transcrição via `SFSpeechRecognizer` (ver risco de qualidade abaixo) +
legenda animada queimada no vídeo via Core Animation. Um template só pra
validar o pipeline; mais templates depois se este funcionar bem.

**Fase 3 — Zoom de ênfase + efeitos**
RMS de ênfase (mesma lógica pura), zoom via `CAKeyframeAnimation`, SFX,
efeitos visuais.

**Fase 4 — Polish**
Histórico local, presets salvos, mais templates de legenda, ajuste manual de
timeline.

Sem fase de "futuro" especulativa por enquanto — quando a Fase 4 estiver
pronta, decide-se o próximo passo com o app já funcionando na mão.

---

## 7. Riscos reais (não hipotéticos)

- **Precisão do corte por passthrough perto de bordas de GOP** — validar com
  medição na Fase 1 (ver seção 4).
- **Ciclo de UI lento** é estrutural — resolvido só minimizando quanto código
  vive fora de `EditorCore`.
- **Expiração de 7 dias** do app assinado por conta grátis — reinstala
  semanalmente via AltServer (ver seção 2.2 sobre o Shift-clique pra
  sideload de `.ipa` próprio).
- **Qualidade do `SFSpeechRecognizer`** pode não bastar — plano B é
  `whisper.cpp` embarcado, decisão adiada pra quando houver dado real da
  Fase 2 (custo real: aumenta tamanho do app e tempo de processamento).
- **Sem Simulator com performance real** — todo teste de composição precisa
  do iPhone físico via CI, por isso vale exaurir o teste da lógica pura antes
  de gastar um ciclo de CI.

---

## 8. Próximo passo

Fase 1, já em andamento: bootstrap do projeto + `SilenceDetection` em
`EditorCore` + composição/export não-destrutivo no app.
