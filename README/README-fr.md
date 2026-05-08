[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | **Français** | [Deutsch](README-de.md)

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">Appuie, parle.</h3>
<p align="center">Dictée vocale légère et axée sur la confidentialité, qui écrit dans n'importe quelle app de ton Mac, sans limite de durée.</p>



---

### 🔒 Confidentialité avant tout
La reconnaissance vocale s'exécute **sur l'appareil** par défaut — via la reconnaissance vocale d'Apple ou le moteur local Sherpa-ONNX intégré. Aucun audio ne quitte ton Mac à moins que tu n'actives explicitement l'optimisation par LLM.

### ⚡ Léger
Bundle compact, CPU quasi nul au repos, aucun démon en arrière-plan. Les modèles Sherpa sont téléchargés à la demande et libérés automatiquement en cas de pression mémoire.

---

## Fonctionnalités

### Enregistrement et déclenchement
- **Maintenir pour parler** ou **appuyer pour parler** — au choix, avec arrêt automatique sur silence en option
- **Touche de déclenchement personnalisable** — choisis le modificateur qui te convient
- **Raccourcis pendant l'enregistrement** — annuler la prise, insérer immédiatement en sautant le LLM, ou clore avec un signe de ponctuation en une seule touche
- **Annulation automatique au changement d'app** (mode maintenir uniquement)

### Moteurs de reconnaissance
- **Reconnaissance vocale Apple** — streaming, mode sur l'appareil optionnel, **segmentation glissante** qui dépasse la limite d'1 minute de SFSpeechRecognizer
- **Sherpa-ONNX** — moteur local entièrement hors ligne, modèles téléchargés automatiquement à la première utilisation, modèle de ponctuation inclus
- **8 langues de reconnaissance** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch

### Sortie texte
- **Insertion en direct Apple** — les phrases terminées sont injectées pendant l'enregistrement, sans attendre que tu relâches la touche
- **Ponctuation intelligente** — moteur heuristique local (par langue) ; ignoré automatiquement si le curseur est déjà suivi d'un signe de ponctuation
- **Compatible IME CJK** — bascule temporairement vers la disposition ASCII avant de coller, puis restaure
- **Optimisation par LLM** — APIs compatibles OpenAI **et Anthropic** avec aperçu en streaming ; 10 fournisseurs prédéfinis + liste personnalisée librement modifiable ; system prompt par défaut multilingue ou le tien

### UI et animation
- **Forme d'onde spectrale FFT à 5 bandes** réglée pour la voix humaine (100–4200 Hz), pilotée par Accelerate
- **Trois styles d'animation** — Dynamic Island (ressort façon Spotlight + flou gaussien), Minimal, Aucun — trois vitesses, ProMotion 120 Hz pris en charge
- **Liquid Glass** sur macOS 26, **flou Visual Effect** sur macOS 14/15
- **8 langues d'interface**, détectées automatiquement depuis le système

### Intégration système
- **Mise à jour automatique** depuis GitHub Releases avec vérification de signature (canal Beta optionnel)
- **Lancement à la connexion** (SMAppService)
- **Sélecteur de périphérique d'entrée** — choisis n'importe quel micro du système
- **Baisse du volume système pendant l'enregistrement** (optionnel)
- **Protection contre les doublons d'instance** — l'ancienne instance est fermée automatiquement au démarrage

## Configuration requise

- **macOS 14 Sonoma ou plus récent**
- Permissions : **Accessibilité**, **Microphone**, **Reconnaissance vocale**

## Installation

**Depuis Release (recommandé)**

Télécharge depuis [Releases](https://github.com/BlackSquarre/AtomVoice/releases), décompresse, glisse dans Applications. Chaque version publie trois architectures : Universal / Apple Silicon / Intel.

**Homebrew**

```bash
brew tap BlackSquarre/tap
brew install --cask atomvoice
```

**Compiler depuis les sources**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ Avertissement Gatekeeper

Signature ad-hoc (non notarisée). Au premier lancement :

1. Clic droit sur `AtomVoice.app` → **Ouvrir** → clique sur **Ouvrir**
2. Ou va dans **Réglages système → Confidentialité et sécurité** → **Ouvrir quand même**
3. Ou exécute : `xattr -cr /Applications/AtomVoice.app`

## Utilisation

| Action | Résultat |
|--------|----------|
| Maintenir la touche de déclenchement | Démarre l'enregistrement (mode maintenir) |
| Relâcher la touche de déclenchement | Arrête et insère le texte |
| Appuyer sur la touche de déclenchement | Démarre / arrête (mode appuyer) |
| `ESC` pendant l'enregistrement | Annule, aucun texte inséré |
| `Espace` / `Retour arrière` pendant l'enregistrement | Insère immédiatement, saute le LLM |
| Saisir un signe de ponctuation pendant l'enregistrement | Insère + ajoute ce signe |
| Icône dans la barre de menus | Changer moteur / langue / mode / animation / LLM |

## Configuration de l'optimisation par LLM

Barre de menus → **Optimisation par LLM** → **Réglages** — choisis un préréglage ou ajoute le tien, saisis ta clé API et le nom du modèle. La sortie en streaming est prévisualisée en direct dans la capsule.

Préréglages intégrés : **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (local)** / Personnalisé.

Le system prompt par défaut est ajusté pour le polissage de dictée (homophones, noms de produits/APIs mal transcrits, mots de remplissage, ponctuation) et bascule automatiquement selon la langue de reconnaissance. Tu peux le remplacer par le tien.

## License

Apache License 2.0
