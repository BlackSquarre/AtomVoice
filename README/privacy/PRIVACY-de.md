# AtomVoice Datenschutzrichtlinie

Letzte Aktualisierung: 9. Mai 2026

AtomVoice ist ein Spracheingabe-Tool für die macOS-Menüleiste. Wir nehmen Ihre Privatsphäre sehr ernst. Diese Datenschutzrichtlinie erklärt, wie AtomVoice Daten verarbeitet, Berechtigungen nutzt und mit Drittanbietern interagiert.

## 1. Grundprinzipien

AtomVoice wurde entwickelt, um Daten lokal auf Ihrem Gerät zu verarbeiten und die Datenerhebung zu minimieren.

AtomVoice betreibt keine Benutzerkonten, zeigt keine Werbung an, bindet keine Analyse-SDKs ein, verfolgt kein Benutzerverhalten und verkauft, vermietet oder teilt keine persönlichen Informationen.

## 2. Welche Daten Wir Verarbeiten

AtomVoice kann während des Betriebs die folgenden Daten verarbeiten:

1. **Sprachaudio**
   Wenn Sie die Auswahltaste gedrückt halten, um die Aufnahme zu starten, greift AtomVoice auf das Mikrofon zu und verarbeitet das aufgezeichnete Audio für die Spracherkennung und Wellenformanzeige. Nach Ende der Aufnahme speichert AtomVoice das Audio nicht in lokalen Dateien und lädt es auch nicht auf einen AtomVoice-Server hoch.

2. **Erkannter Text**
   Die Spracherkennungsergebnisse werden vorübergehend in einem schwebenden Kapsel-Fenster angezeigt und nach Ende der Aufnahme in das aktuelle Eingabefeld injiziert. AtomVoice speichert keinen Verlauf des erkannten Textes.

3. **Zwischenablage-Inhalt**
   Um erkannten Text an der aktuellen Cursorposition einzugeben, verwendet AtomVoice vorübergehend die Systemzwischenablage für einen Einfügevorgang. Die Anwendung speichert vorübergehend den ursprünglichen Zwischenablage-Inhalt vor der Injektion und versucht, ihn danach wiederherzustellen. Der Zwischenablage-Inhalt wird nur kurzzeitig im lokalen Speicher gehalten und nicht auf einen AtomVoice-Server hochgeladen.

4. **Barrierefreiheits-bezogene Informationen**
   AtomVoice verwendet macOS-Barrierefreiheitsberechtigungen, um die Auswahltaste zu erkennen, die aktuelle Eingabeposition zu identifizieren und Einfügevorgänge zu simulieren. Die Anwendung protokolliert keine Tastatureingaben und liest nicht kontinuierlich Text aus anderen Anwendungen. Sie liest nur Informationen in der Nähe des Cursors im aktuell fokussierten Eingabefeld, wenn es notwendig ist, beispielsweise zur Vermeidung von doppelter Zeichensetzung.

5. **Lokale Einstellungen**
   AtomVoice speichert Anwendungseinstellungen lokal, wie Sprache, Erkennungsmotor, Auswahltaste, Eingabegerät, Animationsstil, Stille-Automatikstopp-Einstellungen, LLM-Anbieter-URL, Modellname, benutzerdefinierte Aufforderungen usw. Diese Einstellungen werden in den lokalen macOS-Einstellungen gespeichert.

6. **LLM API-Schlüssel**
   Wenn Sie die LLM-Textverfeinerung aktivieren und einen API-Schlüssel eingeben, speichert AtomVoice den API-Schlüssel in den lokalen Einstellungen und verwendet ihn ausschließlich für Anfragen an den gewählten LLM-Anbieter. AtomVoice lädt Ihren API-Schlüssel nicht auf einen AtomVoice-Server hoch.

## 3. Wie die Spracherkennung Funktioniert

AtomVoice unterstützt verschiedene Erkennungsmodi:

1. **Apple Spracherkennung**
   Standardmäßig verwendet AtomVoice das Apple Speech-Framework für die Spracherkennung. Abhängig von Ihrer macOS-Version, Sprache und Systemfähigkeiten kann die Spracherkennung auf dem Gerät oder über den Spracherkennungsdienst von Apple durchgeführt werden. Die zugehörige Datenverarbeitung unterliegt der Datenschutzrichtlinie von Apple.

2. **Apple Geräte-Erkennungsmodus**
   Wenn Sie „Apple Geräte-Erkennung" aktivieren und die aktuelle Sprache dies unterstützt, fordert AtomVoice das System an, die Erkennung nur geräteseitig durchzuführen.

3. **Sherpa ONNX Lokale Erkennung**
   Wenn Sie ein lokales Sherpa ONNX-Erkennungsmodell konfigurieren, wird die Audioerkennung vollständig auf Ihrem Gerät durchgeführt, ohne dass ein Upload in einen Cloud-Erkennungsdienst erforderlich ist.

4. **Volcengine (Doubao) Streaming-Cloud-Erkennung**
   Wenn Sie die Volcengine (Doubao) Streaming-Cloud-Erkennungs-Engine aktivieren und einen API-Schlüssel sowie eine Resource ID konfigurieren, sendet AtomVoice Ihre Sprachaudio an den Spracherkennungsdienst von Bytedance's Volcengine zur Echtzeit-Streaming-Erkennung. Ihre Audiodaten werden von Volcengine-Servern verarbeitet. Die zugehörige Datenverarbeitung unterliegt den Datenschutzrichtlinien von Bytedance und Volcengine. Diese Funktion erfordert eine Konfiguration in den Doubao-Einstellungen und ist standardmäßig deaktiviert.

## 4. LLM-Textverfeinerung

Die LLM-Textverfeinerung ist standardmäßig deaktiviert.

Wenn Sie diese Funktion aktivieren, sendet AtomVoice den erkannten Text an den konfigurierten LLM-Anbieter zur Fehlerkorrektur, Zeichensetzungsergänzung oder Sprachtranskriptionsverbesserung. Unterstützte Anbieter umfassen OpenAI, Anthropic, DeepSeek, Moonshot, Alibaba Cloud Bailian, Zhipu AI, Lingyi Wanwu, Groq, benutzerdefinierte OpenAI-kompatible APIs oder lokales Ollama.

Die an den LLM-Anbieter gesendeten Daten umfassen typischerweise:

1. Den erkannten Text der aktuellen Sitzung
2. Systemaufforderung oder benutzerdefinierte Aufforderung
3. Den konfigurierten Modellnamen
4. Den API-Schlüssel zur Authentifizierung

Wie diese Daten verarbeitet werden, hängt von dem gewählten LLM-Anbieter ab. Bitte überprüfen Sie die Datenschutzrichtlinie und die Datenutzungsbedingungen des jeweiligen Anbieters vor der Nutzung.

Wenn Sie die LLM-Textverfeinerung nicht aktivieren, sendet AtomVoice keinen erkannten Text an einen LLM-Anbieter.

## 5. Automatische Aktualisierungsprüfung

AtomVoice prüft auf neue Versionen über GitHub Releases. Bei der Aktualisierungsprüfung sendet die Anwendung eine Anfrage an GitHub, um die neueste Versionsinformationen zu erhalten. GitHub kann gemäß seinen eigenen Richtlinien Netzwerkanfrage-Informationen wie IP-Adresse, Gerätenetzwerkinformationen und User-Agent empfangen.

AtomVoice sendet bei der Aktualisierungsprüfung keine Aufnahmen, erkannten Text, Zwischenablage-Inhalte oder LLM API-Schlüssel.

## 6. Berechtigungen

AtomVoice benötigt die folgenden macOS-Berechtigungen:

1. **Mikrofonberechtigung**
   Wird verwendet, um Ihre Stimme für die Spracherkennung aufzunehmen.

2. **Spracherkennungsberechtigung**
   Wird verwendet, um das Apple Speech-Framework aufzurufen und Sprache in Text umzuwandeln.

3. **Barrierefreiheitsberechtigung**
   Wird verwendet, um Auswahltasten zu erkennen, Eingabepositionen zu identifizieren und erkannten Text in die aktuelle Anwendung zu injizieren.

Sie können diese Berechtigungen jederzeit in den macOS-Systemeinstellungen widerrufen. Der Widerruf von Berechtigungen kann dazu führen, dass zugehörige Funktionen nicht mehr ordnungsgemäß funktionieren.

## 7. Datenspeicherung und -löschung

AtomVoice speichert keine Audioaufnahmen, keinen Spracherkennungsverlauf und erstellt keine Benutzerkonten.

Lokal gespeicherte Daten bestehen hauptsächlich aus Anwendungseinstellungen. Sie können zugehörige Daten löschen durch:

1. Löschen oder Ändern der LLM-Einstellungen in der Anwendung
2. Löschen der AtomVoice-Anwendungseinstellungen in macOS
3. Löschen der Anwendung und zugehöriger lokaler Support-Dateien

Wenn Sie Drittanbieter-LLM-Dienste oder Apple-Spracherkennung verwenden, verwalten oder löschen Sie zugehörige Daten gemäß den Richtlinien des jeweiligen Anbieters.

## 8. Datenfreigabe

AtomVoice verkauft, vermietet oder handelt nicht mit Ihren persönlichen Daten.

Daten können nur in folgenden Situationen an Dritte gesendet werden:

1. Bei Verwendung der Apple-Spracherkennung können Audio oder Erkennungsanfragen von Apple verarbeitet werden
2. Bei Verwendung der Volcengine (Doubao) Streaming-Cloud-Erkennungs-Engine wird die Sprachaudio von Volcengine-Servern verarbeitet
3. Wenn die LLM-Textverfeinerung aktiviert ist, wird der erkannte Text an den gewählten LLM-Anbieter gesendet
4. Bei der Aktualisierungsprüfung greift die Anwendung auf GitHub Releases zu
5. Bei Verwendung eines benutzerdefinierten API-Endpunkts werden Daten an den von Ihnen konfigurierten Server gesendet

## 9. Sicherheitsmaßnahmen

AtomVoice minimiert die Datenverarbeitung und bevorzugt geräteinterne Operationen. Online-Anfragen werden typischerweise über HTTPS gesendet. Wenn Sie jedoch einen benutzerdefinierten API-Endpunkt konfigurieren, wie eine lokale Ollama-Instanz oder eine andere HTTP-Adresse, überprüfen Sie bitte selbst die Sicherheit dieses Dienstes.

Schützen Sie Ihren LLM API-Schlüssel und vermeiden Sie die Speicherung sensibler Anmeldedaten auf nicht vertrauenswürdigen Geräten oder in geteilten Kontoumgebungen.

## 10. Datenschutz von Kindern

AtomVoice richtet sich an allgemeine macOS-Benutzer und ist nicht speziell an Kinder gerichtet. Wir sammeln wissentlich keine persönlichen Informationen von Kindern.

## 11. Richtlinienänderungen

Wir können diese Datenschutzrichtlinie aktualisieren, wenn sich die Anwendungsfunktionen ändern. Wesentliche Änderungen werden über die Projektseite, Versionshinweise oder In-App-Mitteilungen kommuniziert.

## 12. Kontakt

Wenn Sie Fragen zu dieser Datenschutzrichtlinie oder zur Datenverarbeitung durch AtomVoice haben, erreichen Sie uns unter:

- E-Mail: [atomvoice@outlook.com](mailto:atomvoice@outlook.com)
- GitHub: https://github.com/BlackSquarre/AtomVoice
