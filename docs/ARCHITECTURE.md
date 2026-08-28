# Arquitectura

CanonTalk Native implementa dos pipelines sin mezclar las pistas de los participantes:

```text
micrófono físico -> local→remoto -> OpenAI -> BlackHole 16ch -> micrófono de la llamada
salida de llamada -> BlackHole 2ch -> remoto→local -> OpenAI -> auriculares físicos
```

## Componentes

- `AudioDeviceService` enumera los dispositivos Core Audio y conserva sus UIDs estables.
- `DeviceAudioCapture` abre una entrada concreta y la convierte a PCM16 mono, 24 kHz.
- `DeviceAudioPlayback` reproduce PCM16/24 kHz en una salida concreta.
- `RealtimeTranslationSession` mantiene un WebSocket en el endpoint dedicado de traducción.
- `TranslationPipeline` conecta entrada, sesión y salida, e implementa el bypass manual.
- `AppViewModel` valida la topología y coordina las dos direcciones.

## Protocolo OpenAI

Cada dirección abre una sesión `gpt-realtime-translate` en
`/v1/realtime/translations`. Tras `session.update`, el cliente envía
`session.input_audio_buffer.append` continuamente y procesa:

- `session.output_audio.delta`
- `session.input_transcript.delta`
- `session.output_transcript.delta`
- `session.closed`
- `error`

Al detenerse se envía `session.close`, se drena el audio pendiente y se cierra el
socket después de `session.closed` o de un timeout de cinco segundos.

## Aislamiento y fallos

- No existe ruta directa de audio original en modo normal.
- Durante un fallo de red, el audio de entrada se descarta y la salida afectada queda en silencio.
- Al reconectar se empieza desde el audio actual; nunca se reproduce una cola antigua.
- Si desaparece un dispositivo seleccionado se detienen ambos pipelines.
- El bypass requiere mantener pulsado el control visible y envía silencio a la sesión mientras enruta el original.

## Datos

La API key reside en Keychain. Audio y subtítulos solo viven en memoria. Los
subtítulos se borran al detener la sesión y la aplicación no implementa grabación
ni historial.
