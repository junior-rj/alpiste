# Alpiste

## O que é
App macOS nativo de notas de reunião com IA, no estilo do Granola: captura o áudio da reunião, transcreve e gera notas estruturadas.

## Tipo
Produto próprio

## Escopo
- App novo em SwiftUI, macOS 15+ (piso do `SCStreamConfiguration.captureMicrophone`)
- Captura de áudio da reunião (sistema + microfone) via ScreenCaptureKit
- Transcrição local com whisper.cpp (modelo medium), API só como fallback
- Notas geradas por IA a partir da transcrição (Gemini free tier)
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
- Alpiste/Notes.swift — mix ffmpeg, whisper, Gemini/Groq, escrita do markdown; `Tool` e `Env`
- Alpiste/Backfill.swift — varredura que regenera resumos que falharam (launch e agendada)
- Alpiste/AlpisteApp.swift — MenuBarExtra, máquina de estados, permissões, `SelfTest`
- scripts/setup.sh — brew deps + download do ggml-medium.bin + ~/.alpiste/.env
- scripts/make-icon.py — gera o AppIcon (grãos-onda) com Pillow, sem dependência externa
- scripts/release.sh — DMG assinado (Developer ID) e notarizado, perfil yourlaunch-notary.
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
- Resumo tem dois provedores em cadeia: **Groq primeiro** (`GROQ_API_KEY`, modelo padrão
  `openai/gpt-oss-120b`, override por `GROQ_MODEL`), Gemini como reserva. A ordem é por
  confiabilidade medida, não preferência: o free tier do Gemini tem cota de 20 requisições/dia e
  deixou 3 reuniões sem resumo em 2 dias, uma delas despercebida por um dia, enquanto o Groq
  respondeu todas as vezes. O Gemini fica em segundo porque a janela de contexto dele é muito
  maior, o que o torna a rede de segurança para reunião longa o bastante para estourar o Groq.
  A ordem é decisão testada em `Notes.summaryProviders` (função pura, coberta pelo `--selftest`):
  se for mudar, mude o teste junto e de propósito
- O catálogo do Groq muda rápido e a página de marketing atrasa em relação à API (em 19/08 a
  página listava Llama 3.3 70B que a API já não servia): conferir em
  `https://api.groq.com/openai/v1/models` com a chave antes de fixar nome de modelo
- Recuperação é automática: `Backfill` varre `~/MeetingNotes` atrás de .md dos últimos 7 dias que
  tenham transcript mas não tenham resumo, e regenera. Roda na abertura do app e em +5/+15/+45 min
  depois de uma gravação que terminou sem resumo; para assim que nada fica pendente. O mesmo sweep
  na mão: `Alpiste --backfill`
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
- Fallback do Gemini avaliado em 2026-08-18 e descartado: o Foundation Models da Apple (on-device,
  `import FoundationModels`) tem janela de contexto de só 4096 tokens (confirmado no `.swiftinterface`
  do SDK), insuficiente pra reunião longa — serviria no máximo de fallback pra reunião curta. Decisão:
  não implementar, deixar como está
