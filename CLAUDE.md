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
- Alpiste/Notes.swift — mix ffmpeg, whisper, Gemini, escrita do markdown; `Tool` e `Env`
- Alpiste/AlpisteApp.swift — MenuBarExtra, máquina de estados, permissões, `SelfTest`
- scripts/setup.sh — brew deps + download do ggml-medium.bin + ~/.alpiste/.env
- scripts/make-icon.py — gera o AppIcon (grãos-onda) com Pillow, sem dependência externa
- scripts/release.sh — DMG assinado (Developer ID) e notarizado, perfil yourlaunch-notary

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
- `Tool.run` é assíncrono e tem timeout (default 30 min, whisper usa 4h): nunca bloqueia o
  cooperative pool do Swift Concurrency, e um processo pendurado não trava o pipeline pra sempre
- Check único: `Alpiste.app/Contents/MacOS/Alpiste --selftest` (assíncrono; roda ffmpeg de verdade no mixer)
