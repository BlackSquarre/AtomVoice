[English](README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | [한국어](README-ko.md) | [Español](README-es.md) | **Français** | [Deutsch](README-de.md)

# AtomVoice

<p align="center"><img src="../AppIcon-1024.png" width="128"></p>

Une application légère de saisie vocale pour la barre de menus macOS. Appuie sur **Fn** pour enregistrer, relâche pour injecter le texte transcrit dans le champ de saisie actif.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

### 🔒 Vie privée d'abord
Toute la reconnaissance vocale s'exécute **localement** via le framework de reconnaissance vocale d'Apple. Aucun audio n'est envoyé à un serveur tant que l'Optimisation LLM n'est pas activée explicitement.

### ⚡ Léger
Package d'environ 3 Mo. CPU quasi nul au repos. Aucun daemon en arrière-plan.

---

## Fonctionnalités

- **Maintiens Fn** pour enregistrer, relâche pour injecter le texte
- **Transcription en streaming** — Reconnaissance vocale Apple, chinois simplifié par défaut
- **Forme d'onde spectrale 5 bandes FFT** — 100–6000 Hz, bas→haut de gauche à droite, propulsé par Accelerate
- **Ponctuation automatique** — Moteur de règles local qui ajoute les marques de fin de phrase, sans connexion internet
- **Optimisation LLM** — API compatible OpenAI corrige les termes mal reconnus (ex: 配森→Python) ; 9 fournisseurs prédéfinis + liste personnalisable
- **Animation Dynamic Island** — Physique de ressort réelle à 120 Hz avec flou gaussien
- **Mode sombre/clair** — Liquid Glass sur macOS 26, flou d'effet visuel sur les systèmes plus anciens
- **7 langues d'interface** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch
- **Compatible IME CJK** — Bascule automatiquement vers la source de saisie ASCII avant le collage

## Prérequis

- macOS 13 Ventura ou ultérieur
- Permissions requises : **Accessibilité**, **Microphone**, **Reconnaissance vocale**

## Installation

**Depuis Release (recommandé)**

Télécharger depuis [Releases](https://github.com/BlackSquarre/AtomVoice/releases), décompresser, glisser dans Applications.

**Compiler depuis les sources**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ Avertissement Gatekeeper

Signature ad-hoc (non notariée). À la première ouverture :

1. Clic droit sur `AtomVoice.app` → **Ouvrir** → cliquer **Ouvrir**
2. Ou aller dans **Réglages du Système → Confidentialité et sécurité** → **Ouvrir quand même**
3. Ou exécuter : `xattr -cr /Applications/AtomVoice.app`

## Utilisation

| Action | Résultat |
|--------|----------|
| Maintenir Fn | Démarrer l'enregistrement |
| Relâcher Fn | Arrêter et injecter le texte |
| Icône de la barre de menus | Changer la langue / animation / paramètres LLM |

## Configuration de l'optimisation LLM

Barre de menus → **Optimisation LLM** → **Paramètres** — sélectionner un fournisseur prédéfini ou ajouter le vôtre, entrer la clé API et le nom du modèle.

Fournisseurs prédéfinis : OpenAI / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / Ollama (local)

## Commandes de compilation

```bash
make build    # Compiler le bundle .app
make run      # Compiler et lancer
make install  # Installer dans /Applications
make release  # Compiler les paquets Universal + AppleSilicon + Intel
make clean    # Nettoyer les artefacts de compilation
```

## License

MIT
