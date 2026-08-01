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
- Falha em qualquer etapa ainda grava o .md e mantém o áudio. Nunca perder a gravação
- Check único: `Alpiste.app/Contents/MacOS/Alpiste --selftest` (roda ffmpeg de verdade no mixer)
