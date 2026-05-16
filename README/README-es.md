[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | **Español** | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">Pulsa, habla.</h3>
<p align="center">Dictado por voz ligero y centrado en la privacidad, que escribe en cualquier app de tu Mac, sin límite de tiempo.</p>



---

### 🔒 Privacidad ante todo
AtomVoice hace explícito cualquier uso de la nube. Sherpa-ONNX es totalmente offline, Apple Speech puede forzarse en el dispositivo cuando el idioma lo permite, y Doubao Cloud ASR / el refinamiento por LLM son opcionales. AtomVoice no opera servidores, no conserva grabaciones ni guarda historial de transcripciones.

### ⚡ Ligero
Bundle pequeño, uso de CPU casi nulo en reposo, sin demonios en segundo plano. El runtime de Sherpa, los modelos ASR y los modelos de puntuación se descargan bajo demanda, y los modelos locales grandes pueden liberarse tras inactividad o presión crítica de memoria.

---

## Funciones

### Grabación y activación
- **Mantener para hablar** o **pulsar para hablar** — a tu elección, con parada automática por silencio opcional
- **Tecla de activación personalizable** — elige el modificador que mejor se adapte a tu teclado
- **Atajos durante la grabación** — cancelar la toma, insertar de inmediato saltándose el LLM o cerrar con un signo de puntuación con una sola tecla
- **Control de voz con auriculares (Beta)** — usa el botón reproducir/pausa de los auriculares para la entrada por voz: pulsación simple según tu modo, pulsación larga para hablar, doble pulsación para enviar Return
- **Cancelación automática al cambiar de app** (solo modo mantener)

### Motores de reconocimiento
- **Reconocimiento de voz de Apple** — motor del sistema con streaming, modo en el dispositivo opcional y **segmentación rodante** que rompe el límite de 1 minuto de SFSpeechRecognizer
- **Sherpa-ONNX** — motor local totalmente offline con preajustes por idioma, backends CPU/Core ML, descargas bajo demanda de runtime/modelos ASR/puntuación, descarga automática de memoria e importación de modelos de terceros
- **Doubao Cloud ASR** — reconocimiento cloud opcional de Volcengine con API Key guardada en el llavero, ITN, puntuación inteligente, suavizado de texto, pase final opcional y fallback a Apple Speech ante fallos cloud
- **8 idiomas de interfaz y reconocimiento** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch; Sherpa también admite modelos de terceros importados para idiomas sin preajuste integrado

### Salida de texto
- **Inserción en vivo de Apple** — las frases completas se insertan durante la grabación, sin esperar a soltar la tecla
- **Puntuación inteligente** — motor heurístico local (por idioma); se omite automáticamente si el cursor ya tiene un signo de puntuación detrás
- **Compatible con IME CJK** — cambia temporalmente al diseño ASCII antes de pegar y lo restaura después
- **Refinamiento por LLM (Beta)** — postprocesamiento solo del texto reconocido con APIs compatibles con OpenAI **y Anthropic**, vista previa en streaming, 10 proveedores predefinidos + lista personalizada totalmente editable, system prompt por defecto multilingüe o el tuyo propio

### UI y animación
- **Forma de onda de espectro FFT de 5 bandas** ajustada a la voz humana (100–4200 Hz), impulsada por Accelerate
- **Tres estilos de animación** — Dynamic Island (resorte estilo Spotlight + desenfoque gaussiano), Minimal, Ninguna — tres velocidades, compatible con ProMotion 120 Hz
- **Liquid Glass** en macOS 26, **Visual Effect blur** en macOS 14/15
- **8 idiomas de UI**, detectados automáticamente desde el sistema

### Integración con el sistema
- **Configuración inicial** para guiar permisos, modo de entrada y elección del motor de reconocimiento
- **Actualización automática** desde GitHub Releases con verificación SHA256 y de firma (canal Beta opcional)
- **Inicio al iniciar sesión** (SMAppService)
- **Selector de dispositivo de entrada** — elige cualquier micrófono del sistema
- **Resiliencia de ruta de audio** — la grabación puede recuperarse al conectar/desconectar auriculares, AirPods o cambiar dispositivo de entrada; el audio se remuestrea por motor
- **Bajar el volumen del sistema mientras grabas** (opcional)
- **Protección de instancia única** — la instancia anterior se cierra automáticamente al iniciar

## Requisitos

- **macOS 14 Sonoma o posterior**
- Permisos: **Accesibilidad**, **Micrófono**, **Reconocimiento de voz**

## Instalación

**Desde Release (recomendado)**

Descarga desde [Releases](https://github.com/BlackSquarre/AtomVoice/releases), descomprime y arrastra a Aplicaciones. Cada versión publica tres arquitecturas: Universal / Apple Silicon / Intel.

**Homebrew**

```bash
brew tap BlackSquarre/tap
brew install --cask atomvoice
```

**Compilar desde el código fuente**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make dev
open dist/Test/AtomVoice.app
```

Para comprobaciones de arquitectura:

```bash
make test
```

El Makefile empaqueta y firma la app con la identidad Apple Development configurada en `Makefile`; cámbiala si compilas en otro Mac.

## ⚠️ Aviso de Gatekeeper

No notarizada. En la primera apertura:

1. Clic derecho en `AtomVoice.app` → **Abrir** → **Abrir**
2. O ve a **Ajustes del sistema → Privacidad y seguridad** → **Abrir de todos modos**
3. O ejecuta: `xattr -cr /Applications/AtomVoice.app`

## Uso

| Acción | Resultado |
|--------|-----------|
| Mantener tecla de activación | Inicia grabación (modo mantener) |
| Soltar tecla de activación | Detiene e inserta texto |
| Pulsar tecla de activación | Inicia / detiene grabación (modo pulsar) |
| Hacer clic en la cápsula durante grabación | Detiene e inserta texto |
| `ESC` durante grabación | Cancela, no se inserta texto |
| `Espacio` / `Retroceso` durante grabación | Inserta de inmediato, salta LLM |
| Escribir un signo de puntuación durante grabación | Inserta + añade ese signo |
| Botón reproducir/pausa de auriculares (opcional, Beta) | Pulsación simple según el modo, larga para grabar, doble para Return |
| Icono de la barra de menús | Cambiar motor / idioma / modo de entrada / animación / ajustes ASR / LLM |

## Configuración del motor

- **Apple Speech** funciona sin configuración. Activa el reconocimiento en el dispositivo cuando el idioma seleccionado lo admite.
- **Sherpa-ONNX** se configura en **Ajustes del motor de reconocimiento → Sherpa local**. Elige idioma, preajuste de modelo, backend CPU/Core ML, retardo de descarga automática o importa un modelo de terceros.
- **Doubao Cloud ASR** se configura en **Ajustes del motor de reconocimiento → Doubao Cloud ASR**. Introduce tu API Key de Volcengine, elige la versión del modelo y conserva o edita el endpoint WebSocket. El primer cambio a Doubao pide confirmación de audio en la nube.

## Configuración del refinamiento por LLM (Beta)

Barra de menús → **Refinamiento por LLM (Beta)** → **Ajustes** — elige un proveedor predefinido o añade el tuyo, introduce la API key y el nombre del modelo. La salida en streaming se previsualiza en vivo dentro de la cápsula.

Predefinidos integrados: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (local)** / Personalizado.

El system prompt por defecto está afinado para pulir dictado (corregir homófonos, nombres de productos/APIs mal transcritos, muletillas, puntuación) y cambia automáticamente según el idioma de reconocimiento. Puedes sobrescribirlo con tu propio prompt. El refinamiento por LLM envía texto reconocido, no audio, al proveedor que selecciones.

## License

Apache License 2.0

Política de privacidad: [Español](privacy/PRIVACY-es.md) / [English](privacy/PRIVACY-en.md).
