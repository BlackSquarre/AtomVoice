[English](README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | [Français](README-fr.md) | **Deutsch**

# AtomVoice

<p align="center"><img src="../AppIcon-1024.png" width="128"></p>

Eine leichtgewichtige macOS Menüleiste-Spracheingabe-App. **Fn** gedrückt halten um aufzunnehmen, loslassen um den transkribierten Text in das aktive Eingabefeld einzufügen.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

### 🔒 Datenschutz zuerst
Die gesamte Spracherkennung läuft **lokal** über das Apple Speech Recognition Framework. Es werden keine Audiodaten an Server gesendet, solange die LLM-Optimierung nicht explizit aktiviert ist.

### ⚡ Leichtgewicht
App-Paket ca. 3 MB. CPU nahezu null im Leerlauf. Keine Hintergrund-Daemonen.

---

## Funktionen

- **Fn gedrückt halten** zum Aufnehmen, loslassen zum Einfügen des Textes
- **Streaming-Transkription** — Apple Spracherkennung, Standard: Vereinfachtes Chinesisch
- **5-Band FFT-Spektrum-Wellenform** — 100–6000 Hz, niedrig→hoch von links nach rechts, angetrieben durch Accelerate
- **Automatische Interpunktion** — Lokale Regel-Engine fügt Satzzeichen hinzu, kein Internet erforderlich
- **LLM-Optimierung** — OpenAI-kompatible API korrigiert falsch erkannte Begriffe (z.B. 配森→Python); 9 vordefinierte Anbieter + bearbeitbare benutzerdefinierte Liste
- **Dynamic Island Animation** — Reale Federphysik mit 120 Hz und Gaußschem Weichzeichner
- **Dunkel/Hell Modus** — Liquid Glass auf macOS 26, Visueller-Effekt-Weichzeichner auf älteren Systemen
- **7 UI-Sprachen** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch
- **CJK IME-kompatibel** — Wechselt automatisch zur ASCII-Eingabequelle vor dem Einfügen

## Voraussetzungen

- macOS 13 Ventura oder höher
- Benötigte Berechtigungen: **Bedienungshilfen**, **Mikrofon**, **Spracherkennung**

## Installation

**Aus Release (empfohlen)**

Herunterladen von [Releases](https://github.com/BlackSquarre/AtomVoice/releases), entpacken, in Programme ziehen.

**Aus Quellcode kompilieren**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ Gatekeeper-Warnung

Ad-hoc-signiert (nicht notarized). Beim ersten Öffnen:

1. Rechtsklick auf `AtomVoice.app` → **Öffen** → **Öffen** klicken
2. Oder zu **Systemeinstellungen → Datenschutz & Sicherheit** → **Trotzdem öffnen** gehen
3. Oder im Terminal ausführen: `xattr -cr /Applications/AtomVoice.app`

## Verwendung

| Aktion | Ergebnis |
|--------|----------|
| Fn gedrückt halten | Aufnahme starten |
| Fn loslassen | Aufnahme stoppen und Text einfügen |
| Menüleistensymbol | Sprache / Animation / LLM-Einstellungen wechseln |

## LLM-Optimierung Einrichtung

Menüleiste → **LLM-Optimierung** → **Einstellungen** — Wähle einen vordefinierten Anbieter oder füge deinen eigenes hinzu, gib API-Schlüssel und Modellname ein.

Vordefinierte Anbieter: OpenAI / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / Ollama (lokal)

## Build-Befehle

```bash
make build    # .app Bundle kompilieren
make run      # Kompilieren und starten
make install  # In /Applications installieren
make release  # Universal + AppleSilicon + Intel Pakete kompilieren
make clean    # Build-Artefakte bereinigen
```

## License

MIT
