# Alpiste

A macOS menu bar app that records a meeting, transcribes it, and writes structured notes
to `~/MeetingNotes/`. Granola-style, but everything stays on your machine.

No accounts, no cloud storage, no telemetry. The only network call is the one that turns
the transcript into notes, and even that is optional.

## What it does

1. Records system audio and your microphone with ScreenCaptureKit.
2. Mixes them into one `.m4a` with ffmpeg.
3. Transcribes with a local whisper.cpp `medium` model.
4. Sends the transcript to Gemini for a 5-bullet summary, decisions, and action items.
5. Writes `~/MeetingNotes/YYYY-MM-DD-HHMM.md` with the notes on top, the full transcript
   below a divider, and the audio alongside as `YYYY-MM-DD-HHMM.m4a`.

## Install

```sh
./scripts/setup.sh          # ffmpeg, whisper-cpp, the ~1.5 GB medium model, and ~/.alpiste/.env
xcodegen                    # generates Alpiste.xcodeproj from project.yml
xcodebuild -scheme Alpiste -configuration Release build
```

Then copy the built `Alpiste.app` to `/Applications` and open it. It lives in the menu bar
only, with no Dock icon.

Requires macOS 15 or later. `SCStreamConfiguration.captureMicrophone`, which is how the app
gets your voice and the meeting audio from a single capture stream, does not exist before
that.

## Permissions to grant

Both are requested on your first **Start Recording**.

| Permission | Why | Where |
|---|---|---|
| **Screen Recording** | The only supported way to capture system audio on macOS. No video is ever written; the app captures a 2x2 pixel surface and throws every frame away. | System Settings > Privacy & Security > Screen Recording |
| **Microphone** | Records your side of the conversation. | System Settings > Privacy & Security > Microphone |

**Screen Recording only takes effect after you quit and reopen the app.** macOS applies it
at launch, so granting it mid-session silently does nothing. Alpiste tells you this when it
asks.

If you decline the microphone, recording still works; you just get the other side of the
call and not your own voice.

## Configuration

`~/.alpiste/.env`, created by `setup.sh`. Real environment variables override the file.

```sh
GEMINI_API_KEY=...        # notes generation, free tier at https://aistudio.google.com/apikey
# GEMINI_MODEL=           # defaults to gemini-flash-latest

# Transcription fallback. Only used when the local model is missing.
# GROQ_API_KEY=
# OPENAI_API_KEY=
```

The path is absolute and fixed rather than relative to this repo, because the `.app` needs
to find it from wherever you install it.

## Offline

With `ggml-medium.bin` in place, transcription never touches the network. Leave
`GEMINI_API_KEY` empty (or just stay offline) and you still get a complete file with the
full transcript; it simply notes that no summary was generated.

The local model always wins. The Whisper API is a fallback for when the model file is
missing, not a preference.

If a step fails, the meeting is still saved. The markdown gets written with whatever
succeeded plus a note about what broke, and the audio is always kept.

## Checks

```sh
Alpiste.app/Contents/MacOS/Alpiste --selftest
```

Asserts the `.env` parser, the markdown assembly (including the degraded no-notes path),
and that `ffmpeg` resolves without a login shell PATH. Exits non-zero on failure.

To exercise transcription without recording anything, whisper-cpp ships a sample:

```sh
whisper-cli -m ~/Library/Application\ Support/Alpiste/models/ggml-medium.bin \
            -f $(brew --prefix)/share/whisper-cpp/jfk.wav
```

## Release

```sh
./scripts/release.sh
```

Regenerates the icon, archives, signs with Developer ID, packages a DMG, notarizes it with
Apple, and staples the ticket. Output lands in `build/Alpiste.dmg`. Uses the
`yourlaunch-notary` keychain profile; override with `NOTARY_PROFILE=...`.

## The icon

`scripts/make-icon.py` draws it with Pillow and writes the whole `AppIcon.appiconset`.
No design tool and no external renderer involved, so the icon is reproducible from source:

```sh
python3 scripts/make-icon.py
```

Birdseed grains whose heights trace an audio waveform, in the Sparrow palette (navy tile,
sand grains, ivory crest). Five grains rather than seven because seven collapse into
hairlines once macOS scales the icon to 32px.

## Notes on the build

- `project.yml` is the source of truth. Run `xcodegen` after changing it; the `.xcodeproj`
  is gitignored.
- No app sandbox, hardened runtime on. The app shells out to `ffmpeg` and `whisper-cli`,
  which the sandbox would block. Same posture as the sibling `menubar-hide` project.
- Homebrew binaries are located by probing `/opt/homebrew/bin` and `/usr/local/bin`
  directly. An app launched from Finder does not inherit your shell's PATH.

## Not included

Speaker diarization, a notes browser, live transcription, calendar integration, and any
settings UI. Configuration is the `.env` file and the model directory.
