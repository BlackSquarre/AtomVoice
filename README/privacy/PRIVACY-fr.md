# Politique de Confidentialité d'AtomVoice

Dernière mise à jour : 13 mai 2026

AtomVoice est un outil de saisie vocale dans la barre de menus de macOS. Nous prenons votre vie privée très au sérieux. Cette Politique de Confidentialité explique comment AtomVoice traite les données, utilise les autorisations et interagit avec les services tiers.

## 1. Principes Fondamentaux

AtomVoice est conçu pour traiter les données localement sur votre appareil et minimiser la collecte de données.

AtomVoice ne gère pas de comptes utilisateurs, n'affiche pas de publicités, n'intègre pas de SDK d'analyse, ne suit pas le comportement des utilisateurs, et ne vend, ne loue ni ne partage d'informations personnelles.

## 2. Quelles Données Nous Traitons

AtomVoice peut traiter les données suivantes lors de son fonctionnement :

1. **Audio vocal**
   Lorsque vous maintenez la touche de déclenchement enfoncée pour commencer l'enregistrement, AtomVoice accède au microphone et traite l'audio enregistré pour la reconnaissance vocale et l'affichage de la forme d'onde. Une fois l'enregistrement terminé, AtomVoice ne sauvegarde pas l'audio dans des fichiers locaux et ne le télécharge sur aucun serveur AtomVoice.

2. **Texte reconnu**
   Les résultats de la reconnaissance vocale sont temporairement affichés dans une fenêtre capsule flottante et injectés dans le champ de saisie actuel après la fin de l'enregistrement. AtomVoice ne sauvegarde pas l'historique du texte reconnu.

3. **Contenu du presse-papiers**
   Pour saisir le texte reconnu à la position actuelle du curseur, AtomVoice utilise temporairement le presse-papiers du système pour effectuer une opération de collage. L'application sauvegarde temporairement le contenu original du presse-papiers avant l'injection et tente de le restaurer après. Le contenu du presse-papiers n'est conservé que brièvement en mémoire locale et n'est téléchargé sur aucun serveur AtomVoice.

4. **Informations liées à l'accessibilité**
   AtomVoice utilise les autorisations d'accessibilité de macOS pour détecter la touche de déclenchement, identifier la position de saisie actuelle et simuler des opérations de collage. L'application n'enregistre pas vos frappes au clavier et ne lit pas en continu le texte d'autres applications. Elle ne lit les informations à proximité du curseur dans le champ de saisie focalisé que lorsque c'est nécessaire, pour des fonctionnalités telles que l'évitement de la ponctuation en double.

5. **Paramètres locaux**
   AtomVoice stocke les paramètres de l'application localement, tels que la langue, le moteur de reconnaissance, la touche de déclenchement, l'UID du périphérique d'entrée, le style d'animation, les paramètres d'arrêt automatique par silence, l'URL du fournisseur LLM, le nom du modèle, les invites personnalisées, les enregistrements de modèles Sherpa importés, etc. Ces paramètres sont stockés dans les préférences locales de macOS.

6. **Clé API LLM**
   Si vous activez le raffinement de texte LLM et saisissez une clé API, AtomVoice stocke la clé API dans les préférences locales et l'utilise uniquement pour effectuer des requêtes vers le fournisseur LLM choisi. AtomVoice ne télécharge pas votre clé API sur un serveur AtomVoice.

7. **Clé API Doubao ASR**
   Si vous configurez la reconnaissance cloud en streaming Volcengine (Doubao), AtomVoice stocke la clé API Doubao ASR dans le trousseau macOS et l'utilise uniquement pour authentifier les requêtes vers Volcengine/Doubao.

## 3. Comment Fonctionne la Reconnaissance Vocale

AtomVoice prend en charge différents modes de reconnaissance :

1. **Reconnaissance vocale Apple**
   Par défaut, AtomVoice utilise le framework Apple Speech pour la reconnaissance vocale. Selon votre version de macOS, la langue et les capacités du système, la reconnaissance vocale peut être effectuée sur l'appareil ou via le service de reconnaissance vocale d'Apple. Le traitement des données associées est soumis à la politique de confidentialité d'Apple.

2. **Mode de reconnaissance sur appareil Apple**
   Si vous activez la « Reconnaissance sur appareil Apple » et que la langue actuelle le prend en charge, AtomVoice demande au système d'effectuer la reconnaissance uniquement sur l'appareil.

3. **Reconnaissance locale Sherpa ONNX**
   Si vous configurez un modèle de reconnaissance local Sherpa ONNX, la reconnaissance audio est entièrement effectuée sur votre appareil sans nécessiter de téléchargement vers un service de reconnaissance cloud.

4. **Reconnaissance cloud en streaming Volcengine (Doubao)**
   Si vous activez le moteur de reconnaissance cloud en streaming Volcengine (Doubao) et configurez une clé API et un Resource ID, AtomVoice envoie votre audio vocal au service de reconnaissance vocale Volcengine de Bytedance pour une reconnaissance en streaming en temps réel. Vos données audio sont traitées par les serveurs de Volcengine. Le traitement des données associées est régi par les politiques de confidentialité de Bytedance et Volcengine. Cette fonctionnalité nécessite une configuration dans les paramètres Doubao et est désactivée par défaut.

## 4. Raffinement de Texte LLM

Le raffinement de texte LLM est désactivé par défaut.

Si vous activez cette fonctionnalité, AtomVoice envoie le texte reconnu au fournisseur LLM configuré pour la correction d'erreurs, le complètement de la ponctuation ou l'amélioration de la transcription vocale. Les fournisseurs pris en charge incluent OpenAI, Anthropic, DeepSeek, Moonshot, Alibaba Cloud Bailian, Zhipu AI, Lingyi Wanwu, Groq, une API personnalisée compatible OpenAI ou Ollama local.

Les données envoyées au fournisseur LLM incluent typiquement :

1. Le texte reconnu de la session en cours
2. L'invite système ou l'invite personnalisée
3. Le nom du modèle configuré
4. La clé API pour l'authentification

La façon dont ces données sont traitées dépend du fournisseur LLM que vous choisissez. Veuillez consulter la politique de confidentialité et les conditions d'utilisation des données du fournisseur concerné avant utilisation.

Si vous n'activez pas le raffinement de texte LLM, AtomVoice n'enverra pas de texte reconnu à un fournisseur LLM.

## 5. Vérification Automatique des Mises à Jour et Téléchargements de Modèles

AtomVoice vérifie les nouvelles versions via GitHub Releases. Lors de la vérification des mises à jour, l'application envoie une requête à GitHub pour obtenir les informations de la dernière version. GitHub peut recevoir des informations de requête réseau, telles que l'adresse IP, les informations réseau de l'appareil et le User-Agent, conformément à ses propres politiques.

Si vous choisissez de télécharger les fichiers d'exécution Sherpa ONNX, des modèles de reconnaissance vocale ou des modèles de ponctuation, AtomVoice télécharge ces fichiers depuis GitHub Releases ou des URL miroir configurées. L'hôte de téléchargement peut recevoir des informations normales de requête réseau, telles que l'adresse IP et le User-Agent. Les modèles Sherpa locaux importés manuellement sont copiés dans le répertoire de support local d'AtomVoice et ne sont pas téléversés par AtomVoice.

AtomVoice n'envoie pas vos enregistrements, texte reconnu, contenu du presse-papiers ou clés API LLM lors des vérifications de mise à jour.

## 6. Autorisations

AtomVoice nécessite les autorisations macOS suivantes :

1. **Autorisation microphone**
   Utilisée pour enregistrer votre voix pour la reconnaissance vocale.

2. **Autorisation de reconnaissance vocale**
   Utilisée pour invoquer le framework Apple Speech et convertir la voix en texte.

3. **Autorisation d'accessibilité**
   Utilisée pour détecter les touches de déclenchement, identifier les positions de saisie et injecter le texte reconnu dans l'application actuelle.

AtomVoice peut également lire les noms et UID des périphériques d'entrée audio disponibles afin que vous puissiez choisir un microphone. Si « Baisser le volume pendant l'enregistrement » est activé, AtomVoice lit le volume de sortie actuel du système, le baisse temporairement pendant l'enregistrement, puis le restaure ensuite.

Vous pouvez révoquer ces autorisations à tout moment dans les Réglages Système de macOS. La révocation des autorisations peut empêcher les fonctionnalités associées de fonctionner.

## 7. Stockage et Suppression des Données

AtomVoice ne sauvegarde pas les enregistrements audio, l'historique de reconnaissance vocale et ne crée pas de comptes utilisateurs.

Les builds de débogage peuvent écrire des journaux de diagnostic locaux dans `~/Library/Logs/AtomVoice/debug.log`. Ces journaux servent au dépannage pendant le développement, restent sur votre appareil et ne sont téléversés sur aucun serveur AtomVoice. Les builds de publication n'écrivent pas ce journal de débogage.

Les données stockées localement consistent principalement en les paramètres de l'application. Vous pouvez supprimer les données associées en :

1. Effaçant ou modifiant les paramètres LLM dans l'application
2. Supprimant les préférences de l'application AtomVoice dans macOS
3. Supprimant l'application et ses fichiers de support locaux associés

Si vous utilisez des services LLM tiers ou la reconnaissance vocale Apple, gérez ou supprimez les données associées conformément aux politiques du fournisseur concerné.

## 8. Partage de Données

AtomVoice ne vend, ne loue ni n'échange vos données personnelles.

Les données peuvent être envoyées à des tiers uniquement dans les situations suivantes :

1. Lors de l'utilisation de la reconnaissance vocale Apple, l'audio ou les requêtes de reconnaissance peuvent être traités par Apple
2. Lors de l'utilisation du moteur de reconnaissance cloud en streaming Volcengine (Doubao), l'audio vocal est traité par les serveurs de Volcengine
3. Lorsque le raffinement de texte LLM est activé, le texte reconnu est envoyé au fournisseur LLM choisi
4. Lors de la vérification des mises à jour, l'application accède à GitHub Releases
5. Lors de l'utilisation d'un point de terminaison API personnalisé, les données sont envoyées au serveur que vous avez configuré

## 9. Mesures de Sécurité

AtomVoice minimise le traitement des données et privilégie les opérations sur l'appareil. Les requêtes en ligne sont généralement envoyées via HTTPS. Cependant, si vous configurez un point de terminaison API personnalisé, tel qu'une instance Ollama locale ou une autre adresse HTTP, veuillez vérifier vous-même la sécurité de ce service.

Protégez votre clé API LLM et évitez de stocker des identifiants sensibles sur des appareils non fiables ou dans des environnements de comptes partagés.

## 10. Vie Privée des Enfants

AtomVoice est destiné aux utilisateurs généraux de macOS et n'est pas spécifiquement destiné aux enfants. Nous ne collectons pas sciemment d'informations personnelles d'enfants.

## 11. Modifications de la Politique

Nous pouvons mettre à jour cette Politique de Confidentialité à mesure que les fonctionnalités de l'application évoluent. Les modifications significatives seront communiquées via la page du projet, les notes de version ou les avis dans l'application.

## 12. Nous Contacter

Si vous avez des questions concernant cette Politique de Confidentialité ou la façon dont AtomVoice traite les données, vous pouvez nous contacter à :

- Email : [atomvoice@outlook.com](mailto:atomvoice@outlook.com)
- GitHub : https://github.com/BlackSquarre/AtomVoice
