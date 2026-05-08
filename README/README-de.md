[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | **Deutsch**

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">Drücken, sprechen.</h3>
<p align="center">Leichte, datenschutzorientierte Sprachdiktierung, die in jede Mac-App tippt, ohne Zeitlimit.</p>



---

### 🔒 Datenschutz zuerst
Spracherkennung läuft standardmäßig **auf dem Gerät** — entweder über Apples Spracherkennung oder die mitgelieferte Sherpa-ONNX-Lokal-Engine. Audio verlässt deinen Mac nur, wenn du die LLM-Textverfeinerung explizit aktivierst.

### ⚡ Leichtgewichtig
Kleines App-Bundle, nahezu null CPU-Last im Leerlauf, keine Hintergrund-Daemons. Sherpa-Modelle werden bei Bedarf geladen und unter Speicherdruck automatisch freigegeben.

---

## Funktionen

### Aufnahme und Auslöser
- **Halten zum Sprechen** oder **Tippen zum Sprechen** — deine Wahl, mit optionalem Stille-Auto-Stopp
- **Anpassbare Auslösetaste** — wähle den Modifier, der zu deiner Tastatur passt
- **Tastenkürzel während der Aufnahme** — Aufnahme abbrechen, sofort einfügen ohne LLM, oder mit einem Satzzeichen abschließen — alles per Einzeltastendruck
- **Auto-Abbruch beim App-Wechsel** (nur Halten-Modus)

### Erkennungs-Engines
- **Apple Spracherkennung** — Streaming, optionaler On-Device-Modus, **rollende Segmentierung** umgeht das 1-Minuten-Limit von SFSpeechRecognizer
- **Sherpa-ONNX** — vollständig offline-fähige lokale Engine, Modelle werden beim ersten Gebrauch automatisch geladen, Satzzeichen-Modell inklusive
- **8 Erkennungssprachen** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch

### Textausgabe
- **Apple Live-Einfügen** — abgeschlossene Sätze werden während der Aufnahme eingefügt, ohne dass du die Taste loslassen musst
- **Smarte Satzzeichen** — lokaler heuristischer Satzzeichen-Generator (sprachabhängig); übersprungen, wenn der Cursor bereits von einem Satzzeichen gefolgt ist
- **CJK-IME-kompatibel** — wechselt vor dem Einfügen vorübergehend zur ASCII-Belegung und stellt sie danach wieder her
- **LLM-Verfeinerung** — OpenAI-kompatible **und Anthropic**-APIs mit Streaming-Vorschau; 10 vorkonfigurierte Anbieter + frei editierbare Liste; mehrsprachiger Standard-System-Prompt oder dein eigener

### UI und Animation
- **5-Band-FFT-Spektralwellenform**, abgestimmt auf die menschliche Stimme (100–4200 Hz), getrieben von Accelerate
- **Drei Animationsstile** — Dynamic Island (Spotlight-artige Federung + Gauß-Unschärfe), Minimal, Keine — drei Geschwindigkeiten, ProMotion-120-Hz-tauglich
- **Liquid Glass** auf macOS 26, **Visual Effect Blur** auf macOS 14/15
- **8 UI-Sprachen**, automatisch anhand der Systemsprache erkannt

### Systemintegration
- **Auto-Update** von GitHub Releases mit Code-Signatur-Prüfung (optionaler Beta-Kanal)
- **Beim Anmelden starten** (SMAppService)
- **Audio-Eingabegerät auswählen** — beliebiges Systemmikrofon möglich
- **Systemlautstärke beim Aufnehmen senken** (optional)
- **Single-Instance-Schutz** — alte Instanzen werden beim Start automatisch beendet

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
make install
```

## ⚠️ Gatekeeper-Hinweis

Ad-hoc-signiert (nicht notarisiert). Beim ersten Öffnen:

1. Rechtsklick auf `AtomVoice.app` → **Öffnen** → **Öffnen** klicken
2. Oder **Systemeinstellungen → Datenschutz & Sicherheit** → **Trotzdem öffnen**
3. Oder im Terminal: `xattr -cr /Applications/AtomVoice.app`

## Verwendung

| Aktion | Ergebnis |
|--------|----------|
| Auslösetaste halten | Aufnahme starten (Halten-Modus) |
| Auslösetaste loslassen | Aufnahme stoppen und Text einfügen |
| Auslösetaste tippen | Aufnahme starten / stoppen (Tippen-Modus) |
| `ESC` während Aufnahme | Abbrechen, kein Text eingefügt |
| `Leertaste` / `Rücktaste` während Aufnahme | Sofort einfügen, LLM überspringen |
| Satzzeichen während Aufnahme tippen | Sofort einfügen + dieses Zeichen anhängen |
| Menüleisten-Symbol | Engine / Sprache / Modus / Animation / LLM wechseln |

## LLM-Verfeinerung einrichten

Menüleiste → **LLM-Verfeinerung** → **Einstellungen** — wähle einen Anbieter-Preset oder füge eigene hinzu, trage API-Key und Modellnamen ein. Der Streaming-Output wird live in der Kapsel angezeigt.

Eingebaute Presets: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (lokal)** / Benutzerdefiniert.

Der Standard-System-Prompt ist auf Diktat-Politur abgestimmt (Homophone, falsch erkannte Produkt-/API-Namen, Füllwörter, Satzzeichen) und wechselt automatisch je nach Erkennungssprache. Du kannst ihn mit deinem eigenen Prompt überschreiben.

## License

Apache License 2.0
