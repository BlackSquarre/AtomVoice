# AtomVoice Privacy Policy

Last updated: May 13, 2026

AtomVoice is a macOS menu bar voice input tool. We take your privacy seriously. This Privacy Policy explains how AtomVoice handles data, uses permissions, and interacts with third-party services.

## 1. Core Principles

AtomVoice is designed to process data locally on your device and minimize data collection.

AtomVoice does not operate user accounts, serve advertisements, embed analytics SDKs, track user behavior, or sell, rent, or share personal information.

## 2. What Data We Process

AtomVoice may process the following data during operation:

1. **Voice Audio**
   When you press and hold the trigger key to start recording, AtomVoice accesses the microphone and processes the recorded audio for speech recognition and waveform display. After recording ends, AtomVoice does not save the audio to local files or upload it to any AtomVoice server.

2. **Recognized Text**
   Speech recognition results are temporarily displayed in a floating capsule window and injected into the current input field after recording ends. AtomVoice does not save your recognized text history.

3. **Clipboard Content**
   To input recognized text at the current cursor position, AtomVoice temporarily uses the system clipboard to perform a paste operation. The app temporarily saves the original clipboard content before injection and attempts to restore it afterward. Clipboard content is only briefly held in local memory and is not uploaded to any AtomVoice server.

4. **Accessibility-Related Information**
   AtomVoice uses macOS accessibility permissions to listen for trigger key events, detect the current input position, and simulate paste operations. The app does not log your keystrokes or continuously read text from other applications. It only reads information near the cursor in the currently focused input field when necessary, for features like duplicate punctuation avoidance.

5. **Local Settings**
   AtomVoice stores app settings locally, such as language, recognition engine, trigger key, input device UID, animation style, silence auto-stop settings, LLM provider URL, model name, custom prompts, imported Sherpa model records, and more. These settings are stored in macOS local preferences.

6. **LLM API Key**
   If you enable LLM text refinement and enter an API key, AtomVoice stores the API key in local preferences and uses it solely to make requests to your chosen LLM provider. AtomVoice does not upload your API key to any AtomVoice server.

7. **Doubao ASR API Key**
   If you configure Volcengine (Doubao) streaming cloud recognition, AtomVoice stores the Doubao ASR API key in the macOS Keychain and uses it only to authenticate requests to Volcengine/Doubao.

## 3. How Speech Recognition Works

AtomVoice supports different recognition modes:

1. **Apple Speech Recognition**
   By default, AtomVoice uses the Apple Speech framework for speech recognition. Depending on your macOS version, language, and system capabilities, speech recognition may be performed on-device or through Apple's speech recognition service. Related data handling is governed by Apple's privacy policy.

2. **Apple On-Device Recognition Mode**
   If you enable "Apple On-Device Recognition" and the current language supports it, AtomVoice requests the system to perform device-side recognition only.

3. **Sherpa ONNX Local Recognition**
   If you configure a local Sherpa ONNX recognition model, audio recognition is performed entirely on your device without uploading to any cloud recognition service.

4. **Volcengine (Doubao) Streaming Cloud Recognition**
   If you enable the Volcengine (Doubao) streaming cloud recognition engine and configure an API key and Resource ID, AtomVoice sends your voice audio to Bytedance's Volcengine speech recognition service for real-time streaming recognition. Your audio data is processed by Volcengine's servers. Related data handling is governed by Bytedance's and Volcengine's privacy policies. This feature requires configuration in Doubao settings and is disabled by default.

## 4. LLM Text Refinement

LLM text refinement is disabled by default.

If you enable this feature, AtomVoice sends the recognized text to your configured LLM provider for error correction, punctuation completion, or speech transcription improvement. Supported providers include OpenAI, Anthropic, DeepSeek, Moonshot, Alibaba Cloud Bailian, Zhipu AI, Lingyi Wanwu, Groq, custom OpenAI-compatible APIs, or local Ollama.

Data sent to the LLM provider typically includes:

1. The recognized text from the current session
2. System prompt or custom prompt
3. Your configured model name
4. The API key for authentication

How this data is handled depends on the LLM provider you choose. Please review the privacy policy and data usage terms of the respective provider before use.

If you do not enable LLM text refinement, AtomVoice will not send recognized text to any LLM provider.

## 5. Automatic Update Check and Model Downloads

AtomVoice checks for new versions via GitHub Releases. When checking for updates, the app sends a request to GitHub for the latest version information. GitHub may receive network request information, such as IP address, device network information, and User-Agent, in accordance with its own policies.

If you choose to download Sherpa ONNX runtime files, speech recognition models, or punctuation models, AtomVoice downloads those files from GitHub releases or configured mirror URLs. The download host may receive normal network request information, such as IP address and User-Agent. Imported local Sherpa models are copied to AtomVoice's local support directory and are not uploaded by AtomVoice.

AtomVoice does not send your recordings, recognized text, clipboard content, or LLM API keys during update checks.

## 6. Permissions

AtomVoice requires the following macOS permissions:

1. **Microphone Permission**
   Used to record your voice for speech recognition.

2. **Speech Recognition Permission**
   Used to invoke the Apple Speech framework to convert speech to text.

3. **Accessibility Permission**
   Used to listen for trigger key events, detect input positions, and inject recognized text into the current application.

AtomVoice may also read available audio input device names and UIDs so you can choose a microphone. If "Lower Volume While Recording" is enabled, AtomVoice reads the current system output volume, temporarily lowers it during recording, and restores it afterward.

You can revoke these permissions at any time in macOS System Settings. Revoking permissions may prevent related features from functioning.

## 7. Data Storage and Deletion

AtomVoice does not save audio recordings, speech recognition history, or create user accounts.

Debug builds may write local diagnostic logs to `~/Library/Logs/AtomVoice/debug.log`. These logs are used for development troubleshooting, stay on your device, and are not uploaded to any AtomVoice server. Release builds do not write this debug log.

Locally stored data consists mainly of app settings. You can delete related data by:

1. Clearing or modifying LLM settings within the app
2. Deleting AtomVoice app preferences in macOS
3. Deleting the app and its related local support files

If you use third-party LLM services or Apple speech recognition, please manage or delete related data according to the respective provider's policies.

## 8. Data Sharing

AtomVoice does not sell, rent, or trade your personal data.

Data may be sent to third parties only in the following situations:

1. When using Apple speech recognition, audio or recognition requests may be processed by Apple
2. When using the Volcengine (Doubao) streaming cloud recognition engine, voice audio is processed by Volcengine's servers
3. When LLM text refinement is enabled, recognized text is sent to your chosen LLM provider
4. When checking for updates, the app accesses GitHub Releases
5. When using a custom API endpoint, data is sent to the server you configured

## 9. Security Measures

AtomVoice minimizes data processing and prioritizes on-device operations. Online requests are typically sent over HTTPS. However, if you configure a custom API endpoint, such as a local Ollama instance or other HTTP address, please verify the security of that service yourself.

Please safeguard your LLM API key and avoid storing sensitive credentials on untrusted devices or in shared account environments.

## 10. Children's Privacy

AtomVoice is intended for general macOS users and is not specifically directed at children. We do not knowingly collect personal information from children.

## 11. Policy Changes

We may update this Privacy Policy as application features change. Significant changes will be communicated through the project page, release notes, or in-app notices.

## 12. Contact Us

If you have questions about this Privacy Policy or how AtomVoice handles data, you can reach us at:

- Email: [atomvoice@outlook.com](mailto:atomvoice@outlook.com)
- GitHub: https://github.com/BlackSquarre/AtomVoice
