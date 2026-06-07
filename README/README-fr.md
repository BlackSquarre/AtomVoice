<p align="center">
  <img src="atomvoicepreview.webp" alt="AtomVoice usage demo" width="960">
</p>

---

[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | **Français** | [Deutsch](README-de.md)

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">Appuie, parle.</h3>
<p align="center">Dictée vocale légère et axée sur la confidentialité, qui écrit dans n'importe quelle app de ton Mac, sans limite de durée.</p>



---

### 🔒 Confidentialité avant tout
AtomVoice rend tout traitement cloud explicite. Sherpa-ONNX est entièrement hors ligne, Apple Speech peut être forcé sur l'appareil quand la langue le permet, et Doubao Cloud ASR / l'optimisation LLM sont optionnels. AtomVoice n'exploite pas de serveur, ne conserve pas les enregistrements et ne stocke pas l'historique des transcriptions.

### ⚡ Léger
Le paquet d'installation fait moins de 3 MB et ne lance aucun démon en arrière-plan. La reconnaissance locale Sherpa-ONNX peut utiliser le backend CoreML pour réduire la charge CPU et la consommation d'énergie ; le runtime Sherpa, les modèles ASR et les modèles de ponctuation sont téléchargés à la demande, et les gros modèles locaux peuvent être libérés après inactivité ou forte pression mémoire.

### ⌨️ Compatible avec tes habitudes de saisie
AtomVoice ne prend pas le contrôle de la méthode de saisie système et ne change pas ta façon d'écrire. Tu peux garder tes IME chinois/anglais, raccourcis et préférences ; tape quand tu veux, parle quand tu veux. Pour les longues phrases, les ajouts rapides ou l'écriture entre plusieurs apps, la saisie vocale peut prendre le relais là où le clavier s'arrête.

---

## Fonctionnalités

### Enregistrement et déclenchement
- **Maintenir pour parler** ou **appuyer pour parler** — au choix, avec arrêt automatique sur silence piloté par le texte reconnu pour réduire les coupures à tort avec une voix faible ou un environnement bruyant
- **Touche de déclenchement personnalisable** — choisis le modificateur qui te convient
- **Raccourcis pendant l'enregistrement** — annuler la prise, insérer immédiatement en sautant le LLM, ou clore avec un signe de ponctuation en une seule touche
- **Contrôle vocal au casque (Beta)** — utilisez le bouton lecture/pause du casque pour la saisie vocale ; vérifié avec les commandes de casques USB / DAC et les boutons de casques 3,5 mm : appui simple selon le mode choisi, appui long pour parler, double appui pour envoyer Return
- **Annulation automatique au changement d'app** (mode maintenir uniquement)

### Moteurs de reconnaissance
- **Reconnaissance vocale Apple** — moteur système avec streaming, mode sur l'appareil optionnel et **segmentation glissante** qui dépasse la limite d'1 minute de SFSpeechRecognizer
- **Sherpa-ONNX** — moteur local entièrement hors ligne avec préréglages par langue, backends CPU/CoreML, téléchargements à la demande du runtime, des modèles ASR et de ponctuation, déchargement automatique et import de modèles tiers
- **Doubao Cloud ASR** — moteur cloud Volcengine optionnel avec API Key stockée dans le trousseau, ITN, ponctuation intelligente, lissage du texte, passe finale optionnelle et repli Apple Speech en cas d'échec cloud
- **8 langues d'interface et de reconnaissance** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch ; Sherpa accepte aussi des modèles tiers importés pour les langues sans préréglage intégré

### Sortie texte
- **Insertion en direct Apple** — les phrases terminées sont injectées pendant l'enregistrement, sans attendre que tu relâches la touche
- **Ponctuation intelligente** — moteur heuristique local (par langue) ; ignoré automatiquement si le curseur est déjà suivi d'un signe de ponctuation
- **Compatible IME CJK** — bascule temporairement vers la disposition ASCII avant de coller, puis restaure
- **Optimisation par LLM (Beta)** — post-traitement du texte reconnu uniquement, avec APIs compatibles OpenAI **et Anthropic**, aperçu en streaming, 10 fournisseurs prédéfinis + liste personnalisée librement modifiable, system prompt par défaut multilingue ou le tien

### UI et animation
- **Forme d'onde spectrale FFT à 5 bandes** réglée pour la voix humaine (100–4200 Hz), pilotée par Accelerate
- **Trois styles d'animation** — Dynamic Island (ressort façon Spotlight + flou gaussien), Minimal, Aucun — trois vitesses, ProMotion 120 Hz pris en charge
- **Liquid Glass** sur macOS 26, **flou Visual Effect** sur macOS 14/15
- **8 langues d'interface**, détectées automatiquement depuis le système

### Intégration système
- **Configuration initiale** pour guider les permissions, le mode de saisie et le choix du moteur de reconnaissance
- **Mise à jour automatique** depuis GitHub Releases avec vérification SHA256 et signature (canal Beta optionnel)
- **Lancement à la connexion** (SMAppService)
- **Sélecteur de périphérique d'entrée** — choisis n'importe quel micro du système
- **Résilience audio** — l'enregistrement peut récupérer lors du branchement/retrait d'un casque, d'AirPods ou d'un changement d'entrée ; l'audio est rééchantillonné pour chaque moteur
- **Baisse du volume système pendant l'enregistrement** (optionnel)
- **Protection contre les doublons d'instance** — l'ancienne instance est fermée automatiquement au démarrage, ce qui réduit la concurrence entre plusieurs copies pour les événements du bouton du casque

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
make dev
open dist/Test/AtomVoice.app
```

Pour les vérifications d'architecture et de couverture de localisation :

```bash
make test
make lint-loc
```

`make lint-loc` compare les usages de `loc("key")` aux 8 dossiers de localisation afin de repérer les traductions d'interface manquantes.

Le Makefile empaquette et signe l'app avec l'identité Apple Development configurée dans `Makefile` ; change-la si tu construis sur un autre Mac.

## ⚠️ Avertissement Gatekeeper

Non notarisée. Au premier lancement :

1. Clic droit sur `AtomVoice.app` → **Ouvrir** → clique sur **Ouvrir**
2. Ou va dans **Réglages système → Confidentialité et sécurité** → **Ouvrir quand même**
3. Ou exécute : `xattr -cr /Applications/AtomVoice.app`

## Utilisation

| Action | Résultat |
|--------|----------|
| Maintenir la touche de déclenchement | Démarre l'enregistrement (mode maintenir) |
| Relâcher la touche de déclenchement | Arrête et insère le texte |
| Appuyer sur la touche de déclenchement | Démarre / arrête (mode appuyer) |
| Cliquer la capsule pendant l'enregistrement | Arrête et insère le texte |
| `ESC` pendant l'enregistrement | Annule, aucun texte inséré |
| `Espace` / `Retour arrière` pendant l'enregistrement | Insère immédiatement, saute le LLM |
| Saisir un signe de ponctuation pendant l'enregistrement | Insère + ajoute ce signe |
| Bouton lecture/pause du casque (optionnel, Beta) | Appui simple selon le mode, appui long pour enregistrer, double appui pour Return |
| Icône dans la barre de menus | Changer moteur / langue / mode de saisie / animation / réglages ASR / LLM |

## Configuration des moteurs

- **Apple Speech** fonctionne sans configuration. Active la reconnaissance sur l'appareil quand la langue sélectionnée la prend en charge.
- **Sherpa-ONNX** se configure dans **Réglages du moteur de reconnaissance → Sherpa local**. Choisis la langue, le modèle, le backend CPU/CoreML, le délai de déchargement, ou importe un modèle tiers.
- **Doubao Cloud ASR** se configure dans **Réglages du moteur de reconnaissance → Doubao Cloud ASR**. Saisis ta clé API Volcengine, choisis la version du modèle et conserve ou modifie l'endpoint WebSocket. Le premier passage à Doubao demande une confirmation de traitement audio cloud.

## Configuration de l'optimisation par LLM (Beta)

Barre de menus → **Optimisation par LLM (Beta)** → **Réglages** — choisis un préréglage ou ajoute le tien, saisis ta clé API et le nom du modèle. La sortie en streaming est prévisualisée en direct dans la capsule.

Préréglages intégrés : **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama (local)** / Personnalisé.

Le system prompt par défaut est ajusté pour le polissage de dictée (homophones, noms de produits/APIs mal transcrits, mots de remplissage, ponctuation) et bascule automatiquement selon la langue de reconnaissance. Tu peux le remplacer par le tien. L'optimisation LLM envoie le texte reconnu, pas l'audio, au fournisseur choisi.

## License

Apache License 2.0

Politique de confidentialité : [Français](privacy/PRIVACY-fr.md) / [English](privacy/PRIVACY-en.md).
