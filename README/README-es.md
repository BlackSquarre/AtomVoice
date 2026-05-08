[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | **Español** | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">Pulsa, habla.</h3>
<p align="center">Dictado por voz ligero y centrado en la privacidad, que escribe en cualquier app de tu Mac, sin límite de tiempo.</p>



---

### 🔒 Privacidad ante todo
El reconocimiento de voz se ejecuta **en el dispositivo** por defecto, ya sea con el reconocimiento de voz de Apple o con el motor local Sherpa-ONNX integrado. El audio nunca sale de tu Mac salvo que actives explícitamente el refinamiento por LLM.

### ⚡ Ligero
Bundle pequeño, uso de CPU casi nulo en reposo, sin demonios en segundo plano. Los modelos Sherpa se descargan bajo demanda y se liberan automáticamente cuando hay presión de memoria.

---

## Funciones

### Grabación y activación
- **Mantener para hablar** o **pulsar para hablar** — a tu elección, con parada automática por silencio opcional
- **Tecla de activación personalizable** — elige el modificador que mejor se adapte a tu teclado
- **Atajos durante la grabación** — cancelar la toma, insertar de inmediato saltándose el LLM o cerrar con un signo de puntuación con una sola tecla
- **Cancelación automática al cambiar de app** (solo modo mantener)

### Motores de reconocimiento
- **Reconocimiento de voz de Apple** — streaming, modo en el dispositivo opcional, **segmentación rodante** que rompe el límite de 1 minuto de SFSpeechRecognizer
- **Sherpa-ONNX** — motor local totalmente offline, los modelos se descargan automáticamente al primer uso e incluyen un modelo de puntuación
- **8 idiomas de reconocimiento** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch

### Salida de texto
- **Inserción en vivo de Apple** — las frases completas se insertan durante la grabación, sin esperar a soltar la tecla
- **Puntuación inteligente** — motor heurístico local (por idioma); se omite automáticamente si el cursor ya tiene un signo de puntuación detrás
- **Compatible con IME CJK** — cambia temporalmente al diseño ASCII antes de pegar y lo restaura después
- **Refinamiento por LLM** — APIs compatibles con OpenAI **y Anthropic** con vista previa en streaming; 10 proveedores predefinidos + lista personalizada totalmente editable; system prompt por defecto multilingüe o el tuyo propio

### UI y animación
- **Forma de onda de espectro FFT de 5 bandas** ajustada a la voz humana (100–4200 Hz), impulsada por Accelerate
- **Tres estilos de animación** — Dynamic Island (resorte estilo Spotlight + desenfoque gaussiano), Minimal, Ninguna — tres velocidades, compatible con ProMotion 120 Hz
- **Liquid Glass** en macOS 26, **Visual Effect blur** en macOS 14/15
- **8 idiomas de UI**, detectados automáticamente desde el sistema

### Integración con el sistema
- **Actualización automática** desde GitHub Releases con verificación de firma (canal Beta opcional)
- **Inicio al iniciar sesión** (SMAppService)
- **Selector de dispositivo de entrada** — elige cualquier micrófono del sistema
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
make install
```

## ⚠️ Aviso de Gatekeeper

Firma ad-hoc (no notarizada). En la primera apertura:

1. Clic derecho en `AtomVoice.app` → **Abrir** → **Abrir**
2. O ve a **Ajustes del sistema → Privacidad y seguridad** → **Abrir de todos modos**
3. O ejecuta: `xattr -cr /Applications/AtomVoice.app`

## Uso

| Acción | Resultado |
|--------|-----------|
| Mantener tecla de activación | Inicia grabación (modo mantener) |
| Soltar tecla de activación | Detiene e inserta texto |
| Pulsar tecla de activación | Inicia / detiene grabación (modo pulsar) |
| `ESC` durante grabación | Cancela, no se inserta texto |
| `Espacio` / `Retroceso` durante grabación | Inserta de inmediato, salta LLM |
| Escribir un signo de puntuación durante grabación | Inserta + añade ese signo |
| Icono de la barra de menús | Cambiar motor / idioma / modo / animación / LLM |

## Configuración del refinamiento por LLM

Barra de menús → **Refinamiento por LLM** → **Ajustes** — elige un proveedor predefinido o añade el tuyo, introduce la API key y el nombre del modelo. La salida en streaming se previsualiza en vivo dentro de la cápsula.

Predefinidos integrados: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (local)** / Personalizado.

El system prompt por defecto está afinado para pulir dictado (corregir homófonos, nombres de productos/APIs mal transcritos, muletillas, puntuación) y cambia automáticamente según el idioma de reconocimiento. Puedes sobrescribirlo con tu propio prompt.

## License

Apache License 2.0
