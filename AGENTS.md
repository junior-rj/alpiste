# Alpiste

## O que é
App macOS nativo de notas de reunião com IA, no estilo do Granola: captura o áudio da reunião, transcreve e gera notas estruturadas.

## Escopo
- App novo em SwiftUI, macOS 15+ (piso do `SCStreamConfiguration.captureMicrophone`)
- Captura de áudio da reunião (sistema + microfone) via ScreenCaptureKit
- Transcrição local com whisper.cpp (modelo medium), API só como fallback
- Notas geradas por IA a partir da transcrição, por **dois provedores em cadeia** cuja ordem
  depende do tamanho do transcript: Groq lidera até 29.000 chars, Gemini acima disso, e o que
  não lidera fica de reserva. Detalhe e motivo em "Regras específicas"
- Saída em `~/MeetingNotes/YYYY-MM-DD-HHMM.md` + `.m4a` ao lado

## Contexto
- Repo: https://github.com/junior-rj/alpiste (público desde 2026-08-27, MIT, releases com DMG
  assinado e notarizado). Nota interna fica em `CLAUDE.local.md`, ignorado pelo git
- Referência de produto: Granola (granola.ai)
- Projeto via XcodeGen (project.yml é a fonte de verdade, .xcodeproj gitignored)
- Base copiada do menubar-hide: project.yml, postura de assinatura, padrão de permissão do ScreenCaptureKit
- Sem contas, sem cloud storage, sem telemetria: só a chamada do LLM sai da máquina

## Arquivos importantes
- project.yml — definição do projeto (rodar `xcodegen` após mudar)
- Alpiste/Recorder.swift — SCStream, escreve system.caf e mic.caf separados
- Alpiste/Notes.swift — mix ffmpeg, whisper, Groq/Gemini, escrita do markdown; `Tool` e `Env`
- Alpiste/Backfill.swift — varredura que regenera resumos que falharam (launch e agendada)
- Alpiste/MeetingWatcher.swift — detector de reunião: funções puras de classificação e
  casamento com o calendário, leitura do CoreAudio, e o `MeetingMonitor` que faz o polling
- Alpiste/MeetingCalendar.swift — EventKit, só leitura, título e horário de término
- Alpiste/MeetingPrompt.swift — o painel flutuante Record / Not now
- Alpiste/SettingsView.swift — a janela de preferências (scene `Settings`): toggles de Launch at
  login e Auto-start on Meetings, mais status read-only de transcrição
- Alpiste/SleepGuard.swift — segura o assertion de energia enquanto grava e processa
- Alpiste/Log.swift — registro persistente em `~/Library/Logs/Alpiste/alpiste.log`
- Alpiste/AlpisteApp.swift — MenuBarExtra (`MenuContent`), scene `Settings`, máquina de estados,
  permissões, launch-at-login (`SMAppService`), `SelfTest`
- scripts/setup.sh — brew deps + download do ggml-medium.bin + ~/.alpiste/.env
- scripts/make-icon.py — gera o AppIcon (grãos-onda) com Pillow, sem dependência externa
- scripts/release.sh — DMG assinado (Developer ID) e notarizado; desde 31/08/2026 é um wrapper
  de config: o fluxo mora no compartilhado `sparrow_workspace/scripts/release-macos.sh`, que
  builda inteiro fora do repo (generaliza a cópia pra /tmp do 0.5.6), gera o ExportOptions a
  partir de `TEAM_ID` e produz `build/Alpiste-X.Y.Z.dmg` + `build/export/Alpiste-stapled.app`.
  O perfil de notary vem da variável `NOTARY_PROFILE` (perfil do keychain criado com
  `notarytool store-credentials`).
  No fim ele pergunta ao LaunchServices quais `Alpiste.app` estão registrados e desregistra tudo
  que não seja o instalado. É por consulta, e não por caminho fixo, porque o `.app` intermediário
  do archive muda de lugar dentro do DerivedData entre releases (`BuildProductsPath` numa vez,
  `InstallationBuildProductsLocation` noutra). DerivedData continua FORA do repo de propósito:
  dentro do Documents o iCloud recarimba atributos e o codesign rejeita como detritus.
  O mesmo iCloud carimbava o `.app` exportado no `build/staging` (`com.apple.FinderInfo`,
  `com.apple.fileprovider.fpfs#P`), e todo DMG até o 0.5.5 falhava `codesign --verify --strict`
  sem ninguém notar, porque notarização e Gatekeeper aceitam. Desde o 0.5.6 o script copia o
  app para um `mktemp -d` em /tmp, roda `xattr -cr` lá, exige o strict antes do `hdiutil` e
  de novo no app dentro do DMG pronto. Verificar release por `spctl` sozinho não pega isso.
  **Gerou DMG, instala em /Applications na sequência, sempre.** DMG parado em `build/` não serve
  de nada: o app da barra de menu continua na versão velha e o que foi testado não é o que roda.
  Encerrar o Alpiste em execução antes (conferindo que não há gravação em andamento em
  `~/Library/Application Support/Alpiste/captures/`), substituir o .app e relançar. A permissão
  de TCC sobrevive porque a identidade Developer ID é a mesma. Depois: tag `vX.Y.Z` anotada,
  `git push origin main --follow-tags` e `gh release create vX.Y.Z build/Alpiste-X.Y.Z.dmg`
  com notas em inglês (abertura, bullets, fechamento "Signed with Developer ID and notarized
  by Apple. Requires macOS 15+."). Tag sem release no GitHub não serve para quem instala

## Regras específicas
- O ScreenCaptureKit NÃO mistura mic com áudio do sistema: chegam em output types e formatos
  diferentes, e o SCRecordingOutput exige codec de vídeo. Por isso dois .caf + um `amix` do ffmpeg
- ffmpeg com dois arquivos de saída exige `-map` explícito e `asplit`. Sem isso o segundo output
  consome os streams de entrada e o amix falha com "Cannot find an unused audio input stream"
- App aberto pelo Finder não herda o PATH do shell: binários do brew são achados via `Tool.find`,
  que sonda /opt/homebrew/bin e /usr/local/bin. Nunca assumir `ffmpeg` no PATH
- Permissão de Gravação de Tela só vale após relançar o app (o alerta já avisa)
- SCK não tem modo só-áudio: o filtro de display é obrigatório, daí a superfície de vídeo 2x2 descartada
- Config em `~/.alpiste/.env` (caminho absoluto fixo, porque o .app não acha um .env relativo ao repo)
- Falha em qualquer etapa ainda grava o .md e mantém o áudio. Nunca perder a gravação: mix falho
  resgata os .caf brutos para `~/MeetingNotes`, colisão de nome (mesmo minuto) ganha sufixo `-2`,
  `-3`..., e falha ao escrever o .md tenta `~/Desktop` como fallback antes de desistir
- **Quem apaga o `captures/` é o resgate, não o pipeline.** `Notes.rescueRawAudio` devolve
  `Rescue.complete`, e o `removeItem` do `process` depende dela. Até 0.5.7 a função montava a
  mensagem só com o que tinha conseguido mover e não contava o resto: move parcial destruía o
  `mic.caf` em silêncio, e move total falho fazia a nota dizer "raw audio left in captures/…" uma
  linha antes de apagar exatamente esse diretório. O gatilho mais provável da falha no move é
  colisão de nome, então o `uniqueStem` sonda `caf` além de `md` e `m4a`. Resgate também escreve a
  linha `Audio:` com o `.caf`, senão o `--retranscribe` recusa justo a gravação que já falhou uma vez
- Captura que **nunca virou nota** (crash, queda de energia, Forçar Encerramento) é varrida no
  launch por `Recorder.orphanedCaptures` e passa pelo `Notes.process`. Antes disso o áudio ficava
  inteiro no disco e invisível para sempre. A varredura filtra pelo prefixo `alpiste-` de propósito:
  o `--retranscribe` guarda o scratch na mesma pasta, e varrê-lo reprocessaria nota já salva
- Falha de escrita do `AudioTap` (disco cheio, troca de formato quando o mic vira AirPods) some no
  meio de uma gravação que continua abrindo e tocando. Contada por fonte, logada uma vez, e devolvida
  em `Capture.incomplete` para o .md dizer que a faixa está incompleta
- Captura em andamento mora em `~/Library/Application Support/Alpiste/captures/`, não no temp dir
  do sistema (que o macOS pode purgar sob pressão de disco numa reunião longa)
- Quit (Cmd-Q) durante gravação ou processamento é interceptado por `AppDelegate.applicationShouldTerminate`:
  segura o quit (`.terminateLater`), deixa o pipeline salvar, e só então libera a saída
- **Toda saída terminal do `start()` deve responder ao AppKit**, não só o fim do pipeline. O
  `start()` também estaciona em `.working("Starting…")`, e até 0.5.7 nenhuma das suas saídas
  chamava `NSApp.reply`: Cmd-Q ali travava o app para sempre e o `pendingTermination` ligado
  passava a engolir **todo** alerta pelo resto da sessão. A decisão é `QuitDecision.decide`
  (pura, `--selftest`), e quit que chega com a gravação já de pé vira `stop()` que salva antes
  de liberar. Diálogo de permissão (mic e tela) chama `NSApp.activate` antes, mesma pegadinha de
  LSUIElement do calendário; e aviso de mic desligado vai **depois** do stream de pé, porque
  modal antes segurava a gravação que o próprio texto promete
- `SCShareableContent` e `startCapture` têm teto (`Recorder.withDeadline`), que **abandona** a
  chamada em vez de esperar: `replayd` travado não honra cancelamento, e `TaskGroup` espera todo
  filho antes de sair do escopo. O `catch` seguinte ainda chama `stopCapture`, que é o que impede
  um sucesso tardio de virar sessão órfã
- **O app segura `idleDisplaySleepDisabled` enquanto grava E enquanto processa** (`SleepGuard`,
  `ProcessInfo.beginActivity`, coberto pelo `--selftest`). Não é conforto: o filtro do SCK é um
  **display**, e display que dorme por inatividade derruba o stream com "Failed to find any
  displays or windows to capture". Em 02/09 isso cortou duas reuniões pela metade, ao segundo
  exato do `Display is turned off` do `pmset -g log`, e a nota saiu curta e plausível sem dizer
  que faltava metade. Piorava o diagnóstico porque o modal que a queda levantava culpava a tampa,
  que nunca tinha sido fechada. A janela cobre o pipeline de propósito: o whisper roda por minutos
  e a tela apagando logo depois do stop o suspenderia. Tampa fechada continua **não** sendo
  impedida (nada impede), e é justamente o caso que o `streamFailed` salva. O `hold` é idempotente
  porque um segundo token vazaria o primeiro, e o `release` é devido por **toda** saída terminal de
  `start()` e `stop()`, mesma disciplina do `finishTerminationIfPending`
- Stream do SCK que morre sozinho no meio da reunião (display desconectado, sleep/wake) é reportado
  via callback e salva o que foi capturado até ali, em vez de deixar a UI travada em "Recording".
  A causa comum é **tampa fechada no fim da reunião**: "Failed to find any displays or windows to
  capture" no log bate ao segundo com `Display is turned off` no `pmset -g log` (26 e 27/08). Em
  `streamFailed` o `stop()` vem **antes** do alerta, porque o alerta é modal e segura tudo até o
  OK: com a ordem invertida a captura ficou 47 min parada em `captures/` esperando a tampa abrir
- O start da gravação **tenta duas vezes**. Em 27/08 o SCK lançou "Stream failed to start
  microphone" 100 s depois de um wake por tampa aberta, e a tentativa na mão 6 s depois
  funcionou; sem ninguém olhando, a reunião de 46 min não teria sido gravada. Uma tentativa
  extra com 2 s de espera, sem laço. Start que falha depois do stream já ter entregue áudio
  deixava `system.caf` parcial num diretório órfão em `captures/`; `Recorder.start` agora
  desfaz o diretório antes de relançar o erro
- **Start que falha tem que chamar `stopCapture()`, e o log diz se o `replayd` obedeceu.** O
  SCK roda a captura dentro do daemon `replayd`; em 27/08 o start falhou porque o mic padrão
  era o de um iPhone via Continuity (`start mic capture timed out`), o
  0.5.4 descartou o `SCStream` sem stop, e o `replayd` manteve a sessão viva por 6 h com o
  cliente morto, pegou o microfone no primeiro wake do dispositivo (14:24) e **encerrar o
  Alpiste não soltou**, porque o dono era o daemon. Sintoma: mic "em uso" sem app nenhum
  segurando. Diagnóstico: `pmset -g assertions` mostra `com.apple.audio.AudioTap-…` com
  `audio-in`, e a lista de `kAudioProcessPropertyIsRunningInput` (mesma leitura do
  `MeetingWatcher`) acusa `com.apple.replayd`. Remédio: **`kill -9 $(pgrep -x replayd)`**; o
  daemon ignora SIGTERM (`killall` diz ok e o pid não muda) e `launchctl kickstart -k` é barrado
  pelo SIP. O launchd relança sob demanda. O log unificado só responde por `/usr/bin/log show`:
  `log` é builtin do zsh e devolve vazio
- `Alpiste --regenerate <file.md>`: re-sumariza um .md já salvo, no lugar, reaproveitando o transcript
  (recuperação para quando o LLM falhou ou a chave não estava configurada na hora da gravação)
- `Alpiste --retranscribe <file.md>`: joga o transcript fora e transcreve de novo a partir do `.m4a`
  ao lado, depois re-sumariza. É a recuperação que o `--regenerate` **não** dá, porque ele reaproveita
  o transcript que encontra: transcript estragado pelo decoder continuaria estragado. Só existe porque
  o `.m4a` nunca foi perdido. Reaproveita o `Notes.mix` com uma fonte só, que é exatamente a conversão
  "áudio entra, wav 16 kHz mono sai" que o whisper quer, e já é exercida pelo `--selftest`
- O whisper roda com **`-mc 0` e idioma fixo**, e as duas flags são correção de perda de dados, não
  ajuste fino. `--max-context` no default (`-1`) faz o whisper.cpp injetar o texto já decodificado
  como contexto da janela seguinte: um segmento ruim (queda de nível, vozes sobrepostas) se
  auto-alimenta e o decoder trava repetindo uma frase **até o fim do arquivo**, apagando tudo que
  vinha depois. Medido em 25/08 sobre o `~/MeetingNotes` inteiro: a reunião de 06/08 (45 min) saiu
  95% `(speaking in foreign language)` e a de 25/08 perdeu os últimos 3 min; com `-mc 0` as duas
  transcreveram inteiras e uma reunião que já estava boa saiu igual. O áudio estava intacto nos dois
  casos, o defeito era só de decodificação
- `-l auto` é a segunda metade do mesmo estrago e **não** se resolve sozinha: a detecção olha só os
  primeiros 30 segundos e aplica o palpite ao arquivo todo, então abertura ruidosa traduziu uma
  reunião inteira em português para o inglês. Fixar só o idioma sem o `-mc 0` apenas traduz a
  alucinação (testado: 644 de 644 linhas viraram `[multidão conversando]`). Default `pt`, override por
  `WHISPER_LANGUAGE` no `.env` (`Notes.transcriptionLanguage`, coberta pelo `--selftest`). O
  mesmo idioma vai no `transcribeViaAPI`: era o único caminho que ainda auto-detectava
- **O stdout do whisper-cli é o transcript**, e por isso é descartado (`Tool.run`,
  `discardStandardOutput`). O `-np` significa "não imprima nada além dos resultados", e os
  resultados são o texto: medido em 29/08 com fala sintetizada, 80 bytes de transcript no stdout,
  nada dele no stderr, `.txt` escrito do mesmo jeito. O `Tool.run` mandava stdout para o log do
  comando e, num exit != 0, punha as últimas 6 linhas na mensagem de erro, que vai para o
  `alpiste.log` e para um alerta modal. Nada se perde descartando: o `-otxt` escreve a saída de
  verdade e o stderr guarda os diagnósticos
- A perda era **silenciosa**: o .md salvava, o resumo saía plausível, e só faltava metade da reunião.
  Por isso `Notes.runawayRepetition` (função pura, `--selftest`) marca o problema no .md quando uma
  linha se repete `Notes.repetitionLimit` vezes seguidas. O limiar de 12 foi medido, não chutado: os
  transcripts arruinados corriam 80 e 39 linhas, o pior saudável chegou a 8 ("Bom dia." enquanto a
  reunião enche). A mensagem **nunca cita a linha repetida**, porque `problems` é ecoado no log e
  conteúdo de reunião não pode ir para lá
- Resumo tem dois provedores em cadeia, e a ordem **depende do tamanho do transcript**
  (`Notes.summaryProviders`, função pura coberta pelo `--selftest`; se mudar a ordem, mude o teste
  junto e de propósito). Até `Notes.groqTranscriptLimit` (29.000 chars) o **Groq lidera**
  (`GROQ_API_KEY`, modelo padrão `openai/gpt-oss-120b`, override por `GROQ_MODEL`) por
  confiabilidade medida: o free tier do Gemini tem cota de 20 requisições/dia e deixou 3 reuniões
  sem resumo em 2 dias, uma delas despercebida por um dia. Acima do limite a ordem inverte e o
  Gemini lidera, pela janela de contexto muito maior
- A função **reordena, nunca descarta**: o provedor que não lidera continua sendo a reserva. Em
  20/08 o Gemini respondeu 503 quatro vezes seguidas, e uma lista com um provedor só não teria
  para onde cair
- O limite do Groq é de **taxa, não de contexto**, e chega disfarçado de erro de tamanho. O tier
  `on_demand` corta em **8.000 tokens por minuto** contando a requisição inteira, e devolve
  **HTTP 413** ("Request too large … on tokens per minute (TPM): Limit 8000, Requested N"), não
  429. O `gpt-oss-120b` tem 131k de contexto, então olhar só o modelo não explica a recusa.
  Medido em 21/08 com sondas espaçadas de 70s: 20.000 chars = 5.088 tokens, 25.000 = 6.254,
  29.000 = 7.120. Dá 4,43 chars/token na margem sobre 572 tokens de overhead fixo, e ruptura
  real em ~32.900 chars; o limiar de 29.000 guarda 880 tokens de folga. **Medir sempre pelo
  `usage.prompt_tokens` de um 200, nunca pelo corpo do 413**: o "Requested N" dele conta contra
  a janela móvel do minuto, então sondas em sequência se inflam (o mesmo payload leu 9.475 num
  dia e 11.449 no outro).
  **Não mandar `max_tokens`**: o Groq soma o teto de saída ao cálculo de TPM, então declarar
  `max_tokens=2000` num payload de 8.121 tokens pediu 10.121 e piorou a recusa
- O catálogo do Groq muda rápido e a página de marketing atrasa em relação à API (em 19/08 a
  página listava Llama 3.3 70B que a API já não servia): conferir em
  `https://api.groq.com/openai/v1/models` com a chave antes de fixar nome de modelo
- Recuperação é automática: `Backfill` varre `~/MeetingNotes` atrás de .md dos últimos 7 dias que
  tenham transcript mas não tenham resumo, e regenera. Roda na abertura do app e em +5/+15/+45 min
  depois de uma gravação que terminou sem resumo; para assim que nada fica pendente. O mesmo sweep
  na mão: `Alpiste --backfill`
- **Todo diagnóstico vai para `~/Library/Logs/Alpiste/alpiste.log`** (`Log.write`), aberto pelo item
  "Open Log" do menu. Existe porque `print()` some quando o `.app` abre pelo Finder e o `NSLog` não
  chegou ao log unificado em 20/08: o alerta modal era o único registro, e o usuário não conseguiu
  nem ler nem printar. Um evento por linha (o `Log.write` achata espaço em branco, senão um corpo de
  erro JSON do Gemini espalha um evento por 15 linhas). **Nunca logar segredo nem conteúdo de
  reunião**: nome da chave sim, valor não; tamanho do transcript sim, texto não. Rotaciona em 2 MB
  guardando um arquivo. Antes de `exit()` chamar `Log.flush()`, senão a linha que diz como terminou
  se perde na fila
- Falha que o `Backfill` vai reter **não** abre alerta modal: o menu vai para `Phase.retrying` e o
  alerta só aparece se as três tentativas se esgotarem (`AppState.backfillGaveUp`). Quem decide é
  `Notes.problemsWorthAlerting` (função pura, coberta pelo `--selftest`), que separa pelo prefixo
  `Notes.summaryFailurePrefix`. Em 20/08 o modal disparou no instante em que três novas tentativas
  tinham acabado de ser agendadas, uma delas deu certo 6 minutos depois, e o alarme nunca foi
  desfeito: a reunião pareceu perdida o dia todo sem estar. Recuperação agora vira `Phase.recovered`,
  que diz "Recovered", não só "Saved"
- O marcador de "falta resumo" é o placeholder `_No notes were generated…`, procurado só acima do
  divisor do transcript (`Notes.pendingSummary`). Se mudar o texto do placeholder, a varredura para
  de achar os arquivos: por isso ele é uma constante única compartilhada com o `markdown()`
- Regenerar reconstrói o arquivo a partir do `split()`, que preserva só título, linha de áudio e
  transcript. Avisos não relacionados ao LLM (ex: "áudio bruto preservado como X") somem na
  regeneração; foi decisão consciente para não complicar o `split()`
- `Tool.run` é assíncrono e tem timeout (default 30 min, whisper usa 4h): nunca bloqueia o
  cooperative pool do Swift Concurrency, e um processo pendurado não trava o pipeline pra sempre
- Check único: `Alpiste.app/Contents/MacOS/Alpiste --selftest` (assíncrono; roda ffmpeg de verdade no mixer)
- "About Alpiste" no menu chama o painel nativo do macOS (`NSApp.orderFrontStandardAboutPanel`), que lê
  nome/versão/copyright direto do Info.plist. Sem tela custom
- **Preferências são a scene `Settings {}`** (`SettingsView`), aberta pelo item "Settings…" (⌘,) via
  `@Environment(\.openSettings)` num `MenuContent` extraído (o `\.openSettings` só existe dentro de
  uma `View`, não no builder de `Scene`). Como `LSUIElement`, chamar `NSApp.activate` antes de
  `openSettings()`, senão a janela abre atrás. **Nunca `NSWindow` própria com controle interativo:
  crasha por recursão de constraints em app de barra de menu** (erros.md 2026-08-17). Os toggles e a
  afordância de calendário moram aqui, não mais no menu
- **Launch at login** é `SMAppService.mainApp` (macOS 13+; sem entitlement em app Developer ID sem
  sandbox). A fonte de verdade é o `status` do serviço, não `UserDefaults` (o usuário pode mudar em
  Ajustes do Sistema): `AppState.launchAtLoginEnabled` espelha `.enabled || .requiresApproval` e é
  relido no `.task` da janela. `register()` que cai em `.requiresApproval` abre os Ajustes e avisa;
  erro reverte o toggle e alerta pelo `AppState.alert`. Só se valida de verdade com o app em
  `/Applications` (o login item guarda o caminho real do bundle — erros.md 2026-08-17 sobre teste)
- **Auto-start de reunião**: o gatilho é **áudio, não calendário**. O CoreAudio expõe, desde o
  macOS 14.4, quais processos seguram o microfone (`kAudioHardwarePropertyProcessObjectList`,
  `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyBundleID`), sem permissão
  nenhuma além das que o app já tem. Evento de calendário em que o usuário não entrou não pode
  avisar, e reunião não agendada tem que ser pega mesmo assim
- O casamento é por **prefixo de bundle ID**, nunca por igualdade: quem segura o dispositivo é o
  processo helper, não o app pai. Medido em 24/08 — uma chamada no Comet aparece como
  `ai.perplexity.comet.helper` e o renderer do Chrome como `com.google.Chrome.helper`. Comparar
  com o bundle ID do app não acharia nenhum dos dois
- A lista negada (`MeetingWatcher.alwaysIgnoredApps`) **não é configurável, de propósito**, e tem
  duas entradas que sustentam o recurso inteiro: o **Wispr Flow**, que segura o microfone o dia
  todo para ditado e faria o painel aparecer de dez em dez minutos, e o **próprio Alpiste**, que
  segura o microfone enquanto grava e realimentaria o detector com a própria captura. Ambos
  cobertos pelo `--selftest`
- O calendário é **contexto, não gatilho**: entra depois que o áudio disparou, só para dar o
  título da nota e o horário de término. Toda falha (sem permissão, sem conta, sem evento) cai
  em nil e o recurso segue em modo degradado. Permissão pedida **preguiçosamente**, na primeira
  vez que o toggle é ligado, nunca no launch
- Parada: `endDate + folga`, mas reunião que estica é **prorrogada em blocos** enquanto o mic
  continua ativo, em vez de ser cortada. Sem evento casado, para com 5 min de mic ocioso; com
  evento casado o ocioso vira 15 min, generoso de propósito para que um trecho longo no mudo
  nunca corte reunião viva. `Stop Recording` na mão sempre vence. A prorrogação tem **teto de 4h**
  (`MeetingWatcher.exceededMaximum`): aba de reunião esquecida segura o mic para sempre, e captura
  de 6h estoura o timeout de 4h do próprio whisper
- **`offered` é identidade de sessão de microfone, não booleano** (`MeetingWatcher.alreadyOffered`,
  pura, `--selftest`), e a contabilidade da sessão roda **acima** de todo return antecipado do tick.
  Com um booleano abaixo do `guard !isBusy`, a reunião que começava enquanto o whisper ainda
  processava a anterior nunca era oferecida **nem logada**: o mic não ficava ocioso, o re-arm não
  rodava, e o flag continuava ligado da reunião anterior. Pauta de reuniões emendadas é o caso
  comum, não o exótico. O mesmo campo evita o painel reaparecer para a call que o usuário acabou
  de parar de gravar na mão
- `MeetingMonitor.stop()` limpa as cinco variáveis, inclusive `startedByWatcher` e `autoStopAt`.
  Deixando as duas para trás, desligar e religar o toggle durante uma gravação fazia o ocioso valer
  `.infinity` no primeiro tick e cortava a reunião viva; "nunca visto ativo" agora conta como não
  ocioso (`MeetingWatcher.idleInterval`)
- Evento **recusado ou cancelado** não é reunião (`looksLikeMeeting`, `--selftest`). Ele continua no
  calendário com link e convidados, e como o `meetingEvent` escolhe o de início mais recente, um
  all-hands recusado vencia a call ad-hoc e dava a ela o título e o término errados
- `EKEventStore` mora num actor próprio: `events(matching:)` é síncrono e o header do EventKit manda
  não rodar na main thread. Ficava no caminho crítico de "a call começou, poe o painel e grava".
  `startDate`/`endDate` são `null_unspecified`, então chegam implicitamente desembrulhados e um nil
  derrubava o processo inteiro de um app sem janela: o `descriptor` devolve opcional
- Ler o calendário exige a entitlement `com.apple.security.personal-information.calendars`.
  O hardened runtime barra acesso a dados pessoais sem ela **mesmo fora do sandbox**, igual ao
  microfone, e barra **em silêncio**: em 24/08 o `requestFullAccessToEvents` devolveu false na
  hora, nenhum diálogo apareceu e o status ficou em `notDetermined`, o que parecia recusa do
  usuário. Tratar só a permissão de TCC não basta; a camada de assinatura vem antes. Conferir
  com `codesign -d --entitlements - /Applications/Alpiste.app`
- Permissão de calendário tem **três estados, não dois** (`MeetingCalendar.Access`, mapeamento
  puro coberto pelo `--selftest`): concedida, nunca perguntada, e bloqueada. Um booleano junta
  os dois últimos e foi o que produziu, em 24/08, um item de menu que mandava o usuário para o
  painel de Calendários dos Ajustes num caso em que o Alpiste sequer estava listado lá, porque
  nunca tinha sido perguntado. Cada estado pede uma ação oposta: um diálogo que o app ainda
  pode levantar, ou os Ajustes do Sistema. O `writeOnly` conta como bloqueado, já que não lê
  evento e nenhum prompt o promove
- O status é relido no tick do watcher, então conceder a permissão nos Ajustes reflete no menu
  em dois segundos, sem relançar
- O diálogo de permissão do Calendário aparece **uma vez só**. Pedir de novo depois de uma
  recusa devolve false sem perguntar nada a ninguém, então `requestAccess` checa
  `authorizationStatus` antes e diz no log que só os Ajustes do Sistema resolvem. E como o app
  é `LSUIElement`, o pedido chama `NSApp.activate` antes: em 24/08 o diálogo abriu atrás da
  janela e ficou sem resposta, deixando o watcher degradado em silêncio. Mesma pegadinha que o
  painel "About" já tratava
- **Nunca logar o título da reunião**: é conteúdo de reunião e a regra do log já proíbe. O log
  registra a decisão ("calendar event matched"), o bundle ID do app que segurou o mic, e tempos
- `Alpiste --prompt-demo` mostra o painel flutuante e diz qual botão foi clicado, sem gravar
  nada. Existe porque a única alternativa para ver o painel renderizar era esperar uma reunião
  de verdade
- Fallback do Gemini avaliado em 2026-08-18 e descartado: o Foundation Models da Apple (on-device,
  `import FoundationModels`) tem janela de contexto de só 4096 tokens (confirmado no `.swiftinterface`
  do SDK), insuficiente pra reunião longa — serviria no máximo de fallback pra reunião curta. Decisão:
  não implementar, deixar como está
