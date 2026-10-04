# CanonTalk Native

A native macOS application for real-time bidirectional translation during video calls.

One person runs CanonTalk Native alongside Zoom or Google Meet, and each participant hears only the audio translated into their own language.

## Requirements

- macOS 13 or later.
- Xcode 15.2 or later to build the application.
- Physical headphones, either USB or Bluetooth.
- An OpenAI API key with access to `gpt-realtime-translate`.
- [BlackHole 2ch and BlackHole 16ch](https://existential.audio/blackhole/) installed as separate audio devices.

BlackHole is not distributed with this project. According to its documentation, the driver is licensed under GPL-3.0. Any integration or redistribution as part of another application must comply with that license or be separately agreed upon with Existential Audio.

## Build and Run

```bash
./scripts/build-app.sh
open "build/CanonTalk Native.app"
```

On first launch, macOS will ask for permission to access the microphone.

The OpenAI API key is stored securely and exclusively in macOS Keychain.

## Audio Configuration

### Zoom or Google Meet

1. Select **BlackHole 16ch** as the microphone.
2. Select **BlackHole 2ch** as the speaker/output device.
3. Do **not** select **Same as System** or a Multi-Output Device.

### CanonTalk Native

1. Select your physical microphone as the input device.
2. Select your headphones as the local audio output.
3. Select **BlackHole 2ch** as **Call Audio**.
4. Select **BlackHole 16ch** as **Translated Microphone**.
5. Select the two languages and start the translation session.

The remote participant does **not** need to install CanonTalk Native.

They should use headphones or enable their calling application's echo cancellation to prevent acoustic feedback.

## Important Behavior

- Two independent OpenAI sessions are maintained, one for each translation direction.
- Audio is streamed as **24 kHz mono PCM16**, including silence.
- Source and translated captions are displayed live and cleared when the session ends.
- If an audio device becomes unavailable or one translation direction loses connection, the original audio is **not** passed through automatically.
- The red press-and-hold control provides a deliberate bypass for sending the original audio.
- If a speaker temporarily switches to the listener's language, the model may not return translated audio. Use the manual bypass control for that segment.

## Supported Languages

The interface includes the 13 output languages documented for the model:

- Spanish
- Portuguese
- French
- Japanese
- Russian
- Chinese
- German
- Korean
- Hindi
- Indonesian
- Vietnamese
- Italian
- English

## Privacy and Cost

While a translation session is active, CanonTalk Native sends conversation audio to OpenAI for real-time processing.

The application does **not** store:

- Audio recordings
- Transcripts
- Conversation history
- Telemetry

Review OpenAI's applicable privacy and data policies before using CanonTalk Native with third parties, and make sure all participants are informed that their audio is being processed by an external service.

The current pricing for `gpt-realtime-translate` should be verified before long sessions.

Bidirectional translation uses **two independent sessions**, meaning both audio directions are processed and billed separately according to their respective audio usage.

## Technical Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [OpenAI Realtime Translation](https://developers.openai.com/api/docs/guides/realtime-translation)
- [Live Translation Cookbook](https://developers.openai.com/cookbook/examples/voice_solutions/realtime_translation_guide)
- [gpt-realtime-translate Model](https://developers.openai.com/api/docs/models/gpt-realtime-translate)
- [Official BlackHole Support](https://existential.audio/blackhole/support/)
