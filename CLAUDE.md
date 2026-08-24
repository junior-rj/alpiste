# Alpiste

## O que é
App macOS nativo de notas de reunião com IA, no estilo do Granola: captura o áudio da reunião, transcreve e gera notas estruturadas.

## Tipo
Produto próprio

## Escopo
- App novo em SwiftUI, macOS 15+ (piso do `SCStreamConfiguration.captureMicrophone`)
- Captura de áudio da reunião (sistema + microfone) via ScreenCaptureKit
- Transcrição local com whisper.cpp (modelo medium), API só como fallback
- Notas geradas por IA a partir da transcrição, por **dois provedores em cadeia** cuja ordem
  depende do tamanho do transcript: Groq lidera até 29.000 chars, Gemini acima disso, e o que
  não lidera fica de reserva. Detalhe e motivo em "Regras específicas"
- Saída em `~/MeetingNotes/YYYY-MM-DD-HHMM.md` + `.m4a` ao lado

## Contexto
- Referência de produto: Granola (granola.ai)
- Sem prazo, projeto pessoal
- Seguir a skill ios-swift-guidelines
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
- Alpiste/Log.swift — registro persistente em `~/Library/Logs/Alpiste/alpiste.log`
- Alpiste/AlpisteApp.swift — MenuBarExtra, máquina de estados, permissões, `SelfTest`
- scripts/setup.sh — brew deps + download do ggml-medium.bin + ~/.alpiste/.env
- scripts/make-icon.py — gera o AppIcon (grãos-onda) com Pillow, sem dependência externa
- scripts/release.sh — DMG assinado (Developer ID) e notarizado, perfil yourlaunch-notary.
  No fim ele pergunta ao LaunchServices quais `Alpiste.app` estão registrados e desregistra tudo
  que não seja o instalado. É por consulta, e não por caminho fixo, porque o `.app` intermediário
  do archive muda de lugar dentro do DerivedData entre releases (`BuildProductsPath` numa vez,
  `InstallationBuildProductsLocation` noutra). DerivedData continua FORA do repo de propósito:
  dentro do Documents o iCloud recarimba atributos e o codesign rejeita como detritus.
  **Gerou DMG, instala em /Applications na sequência, sempre.** DMG parado em `build/` não serve
  de nada: o app da barra de menu continua na versão velha e o que foi testado não é o que roda.
  Encerrar o Alpiste em execução antes (conferindo que não há gravação em andamento em
  `~/Library/Application Support/Alpiste/captures/`), substituir o .app e relançar. A permissão
  de TCC sobrevive porque a identidade Developer ID é a mesma

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
- Captura em andamento mora em `~/Library/Application Support/Alpiste/captures/`, não no temp dir
  do sistema (que o macOS pode purgar sob pressão de disco numa reunião longa)
- Quit (Cmd-Q) durante gravação ou processamento é interceptado por `AppDelegate.applicationShouldTerminate`:
  segura o quit (`.terminateLater`), deixa o pipeline salvar, e só então libera a saída
- Stream do SCK que morre sozinho no meio da reunião (display desconectado, sleep/wake) é reportado
  via callback e salva o que foi capturado até ali, em vez de deixar a UI travada em "Recording"
- `Alpiste --regenerate <file.md>`: re-sumariza um .md já salvo, no lugar, reaproveitando o transcript
  (recuperação para quando o LLM falhou ou a chave não estava configurada na hora da gravação)
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
  nunca corte reunião viva. `Stop Recording` na mão sempre vence
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
