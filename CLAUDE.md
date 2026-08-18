# Instruções para o Claude Code neste projeto

Este arquivo é lido automaticamente no início de toda sessão nesta pasta.
Define como trabalhar aqui: como **orquestrador** que quebra o
[PLANO.md](PLANO.md) em tarefas e coloca múltiplos agentes trabalhando em
paralelo, do mesmo jeito que o projeto irmão `ai-video` já faz — mas com uma
diferença crítica que muda tudo: **não há Mac disponível nesta máquina.**

**Escopo do projeto:** uso pessoal, app instalado só no iPhone do usuário via
Sideloadly (não App Store, não TestFlight, não distribuição pra ninguém).
Repositório GitHub existe **só porque o GitHub Actions precisa de um runner
macOS pra compilar** — não é pra colaboração nem distribuição.

---

## 1. Antes de tudo: leia o plano

Leia [PLANO.md](PLANO.md) primeiro. Ele é a fonte da verdade sobre a
arquitetura em duas camadas (seção 2), a decisão de corte não-destrutivo
(seção 4) e as fases (seção 6). Não redecida isso — implemente o que está
lá. Se surgir motivo real pra desviar, pare e pergunte ao usuário antes de
seguir por outro caminho.

---

## 2. A regra mais importante deste projeto: onde cada código pode ser validado

Isso não existe no projeto irmão e é a causa mais provável de trabalho
desperdiçado se for ignorado:

- **Código em `EditorCore/`** (Swift puro, sem import de `UIKit`,
  `AVFoundation`, `SwiftUI`, `Speech`, `CoreML` — só `Foundation`) roda e
  testa com `swift test`, **local, nesta máquina Windows, sem CI**. O
  toolchain já está instalado (`swift --version` deve funcionar; se um
  agente novo não achar o comando, o instalador colocou os binários em
  `C:\Users\ruyte\AppData\Local\Programs\Swift\Toolchains\<versão>\usr\bin\` e
  `...\Runtimes\<versão>\usr\bin\` — adicione ao PATH da sessão se precisar).
- **Qualquer código em `ViralClip/`** (o app de fato: SwiftUI, AVFoundation,
  Speech, Core Animation) **não compila nem roda nesta máquina, nunca**. Só
  valida de verdade via GitHub Actions (`macos-latest`) + instalação real no
  iPhone do usuário via Sideloadly. Um agente que só tem acesso a este
  Windows **não consegue rodar `xcodebuild`** — o máximo que dá pra fazer é
  escrever o código com cuidado, checar sintaxe/lógica por leitura, e deixar
  claro no relatório final que a validação de compilação real fica pro
  orquestrador rodar via CI depois do merge.

**Consequência pra decomposição de tarefas:** ao quebrar uma fase em tarefas,
separe agressivamente o que é lógica pura (`EditorCore`, testável agora) do
que é integração com framework da Apple (`ViralClip`, só testável depois,
via CI). Tarefas de `EditorCore` são as que valem mais a pena rodar em
paralelo com confiança — o agente PROVA que funcionou antes de reportar.
Tarefas de `ViralClip` precisam de mais rigor de leitura/raciocínio no lugar
de execução real, e o orquestrador (você, sessão principal) é quem faz a
validação final via CI, não o agente implementador.

---

## 3. Papel do Claude principal: orquestrador, não implementador

Mesmo modelo do projeto irmão:

1. Decompor a fase atual em tarefas atômicas, priorizando o que é `EditorCore`
   puro (parágrafo acima).
2. Agrupar em lotes por dependência; tudo independente dispara junto, na
   mesma mensagem, com múltiplos blocos de chamada da ferramenta Agent.
3. Depois do lote: revisão (seção 5) antes de mesclar e seguir.
4. Ao final de cada fase, reportar o que foi feito, o que passou na revisão,
   e **se a validação via CI real (compilação + instalação no iPhone) já
   aconteceu ou ainda está pendente** — isso é sempre pra reportar
   explicitamente aqui, porque "os testes passaram" não significa "o app
   compila" neste projeto do jeito que significa no projeto irmão.

---

## 4. Isolamento entre agentes (git local + worktree)

Mesmo padrão do projeto irmão: `isolation: "worktree"` pra todo agente
implementador disparado em paralelo. Depois do lote + revisão, merge de
volta pro branch principal. Conflito entre tarefas que deveriam ser
independentes é sinal de que a decomposição se sobrepôs — ajuste a divisão.

**Diferença em relação ao projeto irmão:** este repositório TEM remote no
GitHub (necessário pra rodar Actions) — mas isso não muda o fluxo de
worktree local. Só faça `git push` quando o usuário pedir explicitamente ou
quando a fase exigir validar via CI (nesse caso, avise antes: push é uma
ação visível/externa, confirme primeiro).

---

## 5. Atribuição de modelo por complexidade

Mesma tabela do projeto irmão (haiku pra mecânico, sonnet pra integração,
opus pra decisão arquitetural/heurística). Uma nuança deste projeto: lógica
de `EditorCore` que decide corretude de corte/timing (ex: a matemática do
corte não-destrutivo, a heurística de RMS) tende pro lado `opus`/`sonnet`
mesmo parecendo "só matemática" — errar aqui silenciosamente produz vídeo
cortado errado, o mesmo tipo de bug caro que já aconteceu no projeto irmão
(ver o histórico do bug de flashes pretos por VFR lá).

---

## 6. Revisão do trabalho

Mesmo processo do projeto irmão (skill `code-review`), com uma adição:

- Testes de `EditorCore` **têm que ter rodado de verdade** (`swift test`)
  antes de reportar como concluído — não é opcional aqui, é a única rede de
  segurança que este projeto tem sem Mac.
- Para código de `ViralClip`, a revisão de código (leitura) é o que se pode
  fazer *antes* do merge; a validação real (compila? instala? funciona no
  vídeo de verdade?) só acontece depois, via CI + Sideloadly, e é o
  orquestrador quem confirma isso pessoalmente antes de marcar a fase como
  concluída — nunca confiar só no relato do agente aqui, porque o agente
  fisicamente não conseguiu compilar o que escreveu.

---

## 7. Variáveis de ambiente e secrets

Mesmo processo do projeto irmão (`.env.example`, nunca hardcoded). Ponto
específico deste projeto: **o CI não deve precisar de nenhum secret de
assinatura de código** (sem certificado, sem provisioning profile como
secret do GitHub) — a assinatura acontece localmente no Sideloadly, do lado
do usuário, não no CI. Se um agente achar que precisa de um secret de
assinatura no workflow do GitHub Actions, isso é sinal de desvio da
arquitetura do PLANO.md (seção 2.2) — pare e avise o orquestrador antes de
adicionar.

---

## 8. Relato ao usuário

Mesmo formato do projeto irmão, com um campo a mais sempre presente: **o que
já foi validado localmente (testes de `EditorCore`) vs. o que ainda depende
de rodar o CI + instalar no iPhone pra confirmar** — nunca deixar essa
distinção implícita.
