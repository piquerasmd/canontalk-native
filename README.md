# CanonTalk Native

Aplicación macOS para traducción simultánea bidireccional. Una persona ejecuta
la aplicación junto a Zoom o Google Meet y cada participante recibe únicamente
el audio destinado a su idioma.

## Requisitos

- macOS 13 o posterior.
- Xcode 15.2 o posterior para compilar.
- Auriculares físicos, USB o Bluetooth.
- Una API key con acceso a `gpt-realtime-translate`.
- [BlackHole 2ch y BlackHole 16ch](https://existential.audio/blackhole/) instalados como dispositivos separados.

BlackHole no se distribuye con este proyecto. Su documentación indica que el
driver está bajo GPL-3.0 y que una integración dentro de otra aplicación debe
respetar esa licencia o acordarse con Existential Audio.

## Compilar y probar

```bash
cd /Users/carlos/Proyectos/canontalk-native
swift test
./scripts/build-app.sh
open "build/CanonTalk Native.app"
```

La primera ejecución solicitará permiso para usar el micrófono. La API key se
guarda exclusivamente en Keychain.

## Configuración de audio

En Zoom o Google Meet:

1. Selecciona **BlackHole 16ch** como micrófono.
2. Selecciona **BlackHole 2ch** como altavoz.
3. No selecciones “Same as System” ni un Multi-Output Device.

En CanonTalk Native:

1. Elige tu micrófono físico.
2. Elige tus auriculares como salida local.
3. Elige BlackHole 2ch como “Audio de la llamada”.
4. Elige BlackHole 16ch como “Micrófono traducido”.
5. Selecciona los dos idiomas e inicia la traducción.

La persona remota no necesita instalar CanonTalk. Debe usar auriculares o la
cancelación de eco de su cliente de llamada para evitar realimentación acústica.

## Comportamiento importante

- Se mantienen dos sesiones OpenAI independientes, una por dirección.
- El audio se transmite como PCM16 mono a 24 kHz, incluidos los silencios.
- Los subtítulos fuente y traducidos se muestran en vivo y se borran al finalizar.
- Si un dispositivo desaparece o una dirección pierde conexión, no se deja pasar audio original.
- El control rojo de mantener pulsado permite un bypass original deliberado.
- Si alguien cambia al idioma del oyente, el modelo puede no devolver audio. Usa el bypass manual para ese fragmento.

## Idiomas

La interfaz incluye los 13 idiomas de salida documentados para el modelo:
español, portugués, francés, japonés, ruso, chino, alemán, coreano, hindi,
indonesio, vietnamita, italiano e inglés.

## Privacidad y coste

La aplicación envía el audio de la conversación a OpenAI mientras la sesión está
activa. No guarda grabaciones, transcripciones ni telemetría. Consulta las
políticas de OpenAI antes de utilizarla con terceros y avisa a los participantes.

La tarifa documentada de `gpt-realtime-translate` debe comprobarse antes de cada
uso prolongado. Dos direcciones implican dos sesiones facturadas por duración de audio.

## Documentación técnica

- [Arquitectura](docs/ARCHITECTURE.md)
- [OpenAI Realtime Translation](https://developers.openai.com/api/docs/guides/realtime-translation)
- [Cookbook de traducción en vivo](https://developers.openai.com/cookbook/examples/voice_solutions/realtime_translation_guide)
- [Modelo gpt-realtime-translate](https://developers.openai.com/api/docs/models/gpt-realtime-translate)
- [Soporte oficial de BlackHole](https://existential.audio/blackhole/support/)
