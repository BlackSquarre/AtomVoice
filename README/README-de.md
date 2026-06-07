<p align="center">
  <img src="atomvoicepreview-30fps.apng" alt="AtomVoice usage demo" width="960">
</p>

---

[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | **Deutsch**

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">Drücken, sprechen.</h3>
<p align="center">Leichte, datenschutzorientierte Sprachdiktierung, die in jede Mac-App tippt, ohne Zeitlimit.</p>



---

### 🔒 Datenschutz zuerst
AtomVoice macht jede Cloud-Nutzung explizit. Sherpa-ONNX ist vollständig offline, Apple Speech kann auf dem Gerät erzwungen werden, wenn die aktuelle Sprache das unterstützt, und Doubao Cloud ASR / LLM-Verfeinerung sind optional. AtomVoice betreibt keinen Server, bewahrt keine Aufnahmen auf und speichert keinen Transkriptverlauf.

### ⚡ Leichtgewichtig
Das Installationspaket ist unter 3 MB groß und startet keine Hintergrund-Daemons. Die lokale Sherpa-ONNX-Erkennung kann das CoreML-Backend nutzen, um CPU-Last und Stromverbrauch zu reduzieren; Sherpa-Runtime, ASR-Modelle und Satzzeichenmodelle werden bei Bedarf geladen; große lokale Modelle können nach Leerlaufzeit oder kritischem Speicherdruck freigegeben werden.

### ⌨️ Eingabemethodenfreundlich
AtomVoice übernimmt deine System-Eingabemethode nicht und ändert nicht, wie du tippst. Du kannst deine vertrauten Chinesisch-/Englisch-IMEs, Tastenkürzel und Einstellungen behalten; tippe, wenn du tippen willst, sprich, wenn du sprechen willst. Bei langen Sätzen, schnellen Ergänzungen oder Schreiben über mehrere Apps hinweg kann die Spracheingabe dort weitermachen, wo die Tastatur aufhört.

---

## Funktionen

### Aufnahme und Auslöser
- **Halten zum Sprechen** oder **Tippen zum Sprechen** — deine Wahl, mit ASR-textgesteuertem Stille-Auto-Stopp, um falsche Abbrüche bei leiser Sprache oder lauter Umgebung zu reduzieren
- **Anpassbare Auslösetaste** — wähle den Modifier, der zu deiner Tastatur passt
- **Tastenkürzel während der Aufnahme** — Aufnahme abbrechen, sofort einfügen ohne LLM, oder mit einem Satzzeichen abschließen — alles per Einzeltastendruck
- **Kopfhörer-Sprachsteuerung (Beta)** — nutze die Play/Pause-Taste der Kopfhörer für Spracheingabe; verifiziert mit USB-Headset- / DAC-Bedienelementen und 3,5-mm-Headset-Tasten: einfacher Druck folgt deinem Eingabemodus, langer Druck startet Aufnahme, Doppeldruck sendet Return
- **Auto-Abbruch beim App-Wechsel** (nur Halten-Modus)

### Erkennungs-Engines
- **Apple Spracherkennung** — System-Engine mit Streaming, optionalem On-Device-Modus und **rollender Segmentierung**, die das 1-Minuten-Limit von SFSpeechRecognizer umgeht
- **Sherpa-ONNX** — vollständig offline-fähige lokale Engine mit sprachspezifischen Modell-Presets, CPU/CoreML-Backends, On-Demand-Downloads für Runtime/ASR/Satzzeichen, Auto-Unload und Import von Drittanbieter-Modellen
- **Doubao Cloud ASR** — optionale Volcengine-Streaming-Erkennung mit API-Key im Schlüsselbund, ITN, smarten Satzzeichen, Textglättung, optionalem Final-Pass und Apple-Speech-Fallback bei Cloud-Fehlern
- **8 UI- und Erkennungssprachen** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch; Sherpa unterstützt außerdem importierte Drittanbieter-Modelle für Sprachen ohne integriertes Preset

### Textausgabe
- **Apple Live-Einfügen** — abgeschlossene Sätze werden während der Aufnahme eingefügt, ohne dass du die Taste loslassen musst
- **Smarte Satzzeichen** — lokaler heuristischer Satzzeichen-Generator (sprachabhängig); übersprungen, wenn der Cursor bereits von einem Satzzeichen gefolgt ist
- **CJK-IME-kompatibel** — wechselt vor dem Einfügen vorübergehend zur ASCII-Belegung und stellt sie danach wieder her
- **LLM-Verfeinerung (Beta)** — reine Nachbearbeitung des erkannten Texts mit OpenAI-kompatiblen **und Anthropic**-APIs, Streaming-Vorschau, 10 vorkonfigurierten Anbietern + frei editierbarer Liste, mehrsprachigem Standard-System-Prompt oder deinem eigenen

### UI und Animation
- **5-Band-FFT-Spektralwellenform**, abgestimmt auf die menschliche Stimme (100–4200 Hz), getrieben von Accelerate
- **Drei Animationsstile** — Dynamic Island (Spotlight-artige Federung + Gauß-Unschärfe), Minimal, Keine — drei Geschwindigkeiten, ProMotion-120-Hz-tauglich
- **Liquid Glass** auf macOS 26, **Visual Effect Blur** auf macOS 14/15
- **8 UI-Sprachen**, automatisch anhand der Systemsprache erkannt

### Systemintegration
- **Ersteinrichtung** führt durch Berechtigungen, Eingabemodus und Wahl der Erkennungs-Engine
- **Auto-Update** von GitHub Releases mit SHA256- und Code-Signatur-Prüfung (optionaler Beta-Kanal)
- **Beim Anmelden starten** (SMAppService)
- **Audio-Eingabegerät auswählen** — beliebiges Systemmikrofon möglich
- **Robuste Audio-Routen** — Aufnahmen können sich erholen, wenn Kopfhörer, AirPods oder Eingabegeräte währenddessen wechseln; Audio wird pro Engine neu abgetastet
- **Systemlautstärke beim Aufnehmen senken** (optional)
- **Single-Instance-Schutz** — alte Instanzen werden beim Start automatisch beendet, damit mehrere App-Kopien seltener um Kopfhörer-Tastenereignisse konkurrieren

## Anforderungen

- **macOS 14 Sonoma oder neuer**
- Berechtigungen: **Bedienungshilfen**, **Mikrofon**, **Spracherkennung**

## Installation

**Aus Release (empfohlen)**

Lade von [Releases](https://github.com/BlackSquarre/AtomVoice/releases) herunter, entpacke und ziehe in den Programme-Ordner. Jede Version stellt drei Architekturen bereit: Universal / Apple Silicon / Intel.

**Homebrew**

```bash
brew tap BlackSquarre/tap
brew install --cask atomvoice
```

**Aus dem Quellcode bauen**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make dev
open dist/Test/AtomVoice.app
```

Für Architektur- und Lokalisierungsabdeckungsprüfungen:

```bash
make test
make lint-loc
```

`make lint-loc` gleicht `loc("key")`-Verwendungen mit den 8 Lokalisierungsordnern ab, um fehlende UI-Übersetzungen zu finden.

Das Makefile bündelt und signiert die App mit der in `Makefile` konfigurierten Apple-Development-Identität; passe sie an, wenn du auf einem anderen Mac baust.

## ⚠️ Gatekeeper-Hinweis

Nicht notarisiert. Beim ersten Öffnen:

1. Rechtsklick auf `AtomVoice.app` → **Öffnen** → **Öffnen** klicken
2. Oder **Systemeinstellungen → Datenschutz & Sicherheit** → **Trotzdem öffnen**
3. Oder im Terminal: `xattr -cr /Applications/AtomVoice.app`

## Verwendung

| Aktion | Ergebnis |
|--------|----------|
| Auslösetaste halten | Aufnahme starten (Halten-Modus) |
| Auslösetaste loslassen | Aufnahme stoppen und Text einfügen |
| Auslösetaste tippen | Aufnahme starten / stoppen (Tippen-Modus) |
| Kapsel während der Aufnahme anklicken | Aufnahme stoppen und Text einfügen |
| `ESC` während Aufnahme | Abbrechen, kein Text eingefügt |
| `Leertaste` / `Rücktaste` während Aufnahme | Sofort einfügen, LLM überspringen |
| Satzzeichen während Aufnahme tippen | Sofort einfügen + dieses Zeichen anhängen |
| Kopfhörer-Play/Pause-Taste (optional, Beta) | Einfacher Druck folgt dem Modus, langer Druck nimmt auf, Doppeldruck sendet Return |
| Menüleisten-Symbol | Engine / Sprache / Eingabemodus / Animation / ASR-Einstellungen / LLM wechseln |

## Engine Einrichten

- **Apple Speech** funktioniert sofort. Aktiviere On-Device-Erkennung, wenn die gewählte Sprache sie unterstützt.
- **Sherpa-ONNX** wird unter **Erkennungs-Engine-Einstellungen → Sherpa lokal** konfiguriert. Wähle Sprache, Modell-Preset, CPU/CoreML-Backend, Auto-Unload-Verzögerung oder importiere ein Drittanbieter-Modellpaket.
- **Doubao Cloud ASR** wird unter **Erkennungs-Engine-Einstellungen → Doubao Cloud ASR** konfiguriert. Trage deinen Volcengine-API-Key ein, wähle die Modellversion und behalte oder ändere den WebSocket-Endpunkt. Beim ersten Wechsel zu Doubao wird Cloud-Audioverarbeitung bestätigt.

## LLM-Verfeinerung (Beta) einrichten

Menüleiste → **LLM-Verfeinerung (Beta)** → **Einstellungen** — wähle einen Anbieter-Preset oder füge eigene hinzu, trage API-Key und Modellnamen ein. Der Streaming-Output wird live in der Kapsel angezeigt.

Eingebaute Presets: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (lokal)** / Benutzerdefiniert.

Der Standard-System-Prompt ist auf Diktat-Politur abgestimmt (Homophone, falsch erkannte Produkt-/API-Namen, Füllwörter, Satzzeichen) und wechselt automatisch je nach Erkennungssprache. Du kannst ihn mit deinem eigenen Prompt überschreiben. Die LLM-Verfeinerung sendet erkannten Text, kein Audio, an den gewählten Anbieter.

## License

Apache License 2.0

Datenschutzerklärung: [Deutsch](privacy/PRIVACY-de.md) / [English](privacy/PRIVACY-en.md).
