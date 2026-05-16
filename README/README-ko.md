[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | **한국어** | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">누르고, 말하세요.</h3>
<p align="center">가볍고 프라이버시 우선의 음성 받아쓰기. 텍스트가 어떤 Mac 앱에든 직접 입력되며, 녹음 시간 제한이 없습니다.</p>



---

### 🔒 프라이버시 우선
AtomVoice는 클라우드 처리를 명시적인 선택으로 둡니다. Sherpa-ONNX는 완전 오프라인이고, Apple 음성 인식은 현재 언어가 지원할 때 기기 내 인식을 강제할 수 있으며, Doubao Cloud ASR와 LLM 텍스트 최적화는 직접 켜야 합니다. AtomVoice 자체는 서버를 운영하지 않고 녹음이나 전사 기록을 저장하지 않습니다.

### ⚡ 가벼운 설계
앱 번들이 작고, 유휴 시 CPU 사용률은 거의 0이며, 백그라운드 데몬도 없습니다. Sherpa 런타임, ASR 모델, 문장 부호 모델은 필요할 때 다운로드되며, 큰 로컬 모델은 유휴 시간 이후나 심각한 메모리 압박 시 해제할 수 있습니다.

---

## 기능

### 녹음과 트리거
- **눌러서 말하기 / 한 번 눌러 말하기** — 원하는 모드를 선택, 무음 자동 정지와 결합 가능
- **트리거 키 사용자 지정** — 자기 키보드에 맞는 수정자 키 선택
- **녹음 중 단축키** — 한 번에 취소, LLM 건너뛰고 즉시 삽입, 또는 지정한 문장 부호로 마무리
- **헤드폰 음성 제어 (Beta)** — 헤드폰 재생/일시정지 버튼으로 음성 입력 제어: 한 번 누름은 현재 입력 모드 따름, 길게 누름은 녹음, 두 번 누름은 Return 전송
- **앱 전환 시 자동 취소**(눌러서 말하기 모드에서만)

### 인식 엔진
- **Apple 음성 인식** — 시스템 엔진, 스트리밍과 선택적 기기 내 인식, SFSpeechRecognizer의 1분 한계를 넘는 **롤링 분할** 지원
- **Sherpa-ONNX** — 완전 오프라인 로컬 엔진, 언어별 모델 프리셋, CPU/Core ML 백엔드, 런타임/ASR/문장 부호 모델 온디맨드 다운로드, 자동 언로드, 서드파티 모델 가져오기 지원
- **Doubao Cloud ASR** — 선택적 Volcengine 스트리밍 인식, API Key는 키체인에 저장, ITN, 스마트 문장 부호, 텍스트 정리, 선택적 최종 패스 인식, 클라우드 실패 시 Apple Speech fallback 지원
- **8개 UI 및 인식 언어** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch; Sherpa는 내장 프리셋이 없는 언어도 가져온 서드파티 모델을 사용할 수 있습니다

### 텍스트 출력
- **Apple 실시간 삽입** — 녹음 중 완성된 문장이 자동으로 삽입되어, 키를 놓을 때까지 기다릴 필요 없음
- **스마트 문장 부호** — 로컬 휴리스틱 엔진(언어별), 커서 뒤에 이미 문장 부호가 있으면 자동 건너뜀
- **CJK 입력기 호환** — 붙여넣기 전 임시로 ASCII 레이아웃으로 전환 후 복원
- **LLM 텍스트 최적화 (Beta)** — 인식 텍스트만 후처리하며 OpenAI 호환 프로토콜과 **Anthropic** 모두 지원, 스트리밍 미리보기, 10개 프리셋 + 자유 편집 가능한 커스텀 목록, 다국어 기본 system prompt 또는 사용자 prompt

### UI와 애니메이션
- **5 밴드 FFT 스펙트럼 파형** — 사람 음성에 맞춰 조정(100–4200 Hz), Accelerate 기반
- **3가지 애니메이션 스타일** — Dynamic Island(Spotlight 풍 스프링 + 가우시안 블러)/ 미니멀 / 없음, 3단계 속도, ProMotion 120Hz 지원
- **Liquid Glass**(macOS 26) / **Visual Effect 블러**(macOS 14/15)
- **8개 UI 언어**, 시스템 언어 자동 감지

### 시스템 통합
- **첫 실행 설정** — 권한, 입력 모드, 인식 엔진 선택 안내
- **자동 업데이트** — GitHub Releases에서 가져오고 SHA256 및 코드 서명 검증 포함(Beta 채널 옵션)
- **로그인 시 자동 시작**(SMAppService)
- **오디오 입력 장치 선택** — 임의의 시스템 마이크 선택 가능
- **오디오 경로 복구** — 녹음 중 헤드폰, AirPods, 입력 장치가 바뀌어도 복구 가능하며 인식 엔진별로 오디오를 자동 리샘플링
- **녹음 중 시스템 볼륨 낮추기**(옵션)
- **단일 인스턴스 보호** — 시작 시 이전 인스턴스 자동 종료

## 시스템 요구 사항

- **macOS 14 Sonoma 이상**
- 필요 권한: **손쉬운 사용**, **마이크**, **음성 인식**

## 설치

**Release에서 다운로드(권장)**

[Releases](https://github.com/BlackSquarre/AtomVoice/releases)에서 해당 아키텍처의 zip을 다운로드, 압축 해제 후 응용 프로그램 폴더로 드래그. 매 릴리스마다 Universal / Apple Silicon / Intel 3가지 아키텍처 제공.

**Homebrew**

```bash
brew tap BlackSquarre/tap
brew install --cask atomvoice
```

**소스에서 빌드**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make dev
open dist/Test/AtomVoice.app
```

아키텍처 검사는 다음을 실행합니다:

```bash
make test
```

Makefile은 `Makefile`에 설정된 Apple Development 서명 ID로 앱을 번들링하고 서명합니다. 다른 Mac에서 빌드한다면 자신의 서명 ID로 바꿔야 합니다.

## ⚠️ 서명 안내

Apple 공증을 받지 않았습니다. 처음 열 때:

1. `AtomVoice.app` 우클릭 → **열기** → **열기** 클릭
2. 또는 **시스템 설정 → 개인 정보 보호 및 보안** → **그래도 열기**
3. 또는 터미널에서: `xattr -cr /Applications/AtomVoice.app`

## 사용법

| 동작 | 결과 |
|------|------|
| 트리거 키 길게 누르기 | 녹음 시작(눌러서 말하기 모드) |
| 트리거 키 떼기 | 녹음 종료 후 텍스트 삽입 |
| 트리거 키 한 번 누르기 | 녹음 시작 / 종료(한 번 누르기 모드) |
| 녹음 중 캡슐 클릭 | 녹음 종료 후 텍스트 삽입 |
| 녹음 중 `ESC` | 취소, 텍스트 삽입 안 됨 |
| 녹음 중 `Space` / `Backspace` | 즉시 삽입, LLM 건너뜀 |
| 녹음 중 문장 부호 입력 | 즉시 삽입 후 해당 문장 부호 추가 |
| 헤드폰 재생/일시정지 버튼(선택, Beta) | 한 번 누름은 모드 따름, 길게 누름은 녹음, 두 번 누름은 Return |
| 메뉴 막대 아이콘 | 엔진 / 언어 / 입력 모드 / 애니메이션 / ASR 설정 / LLM 전환 |

## 인식 엔진 설정

- **Apple Speech**는 바로 사용할 수 있습니다. 선택한 언어가 지원하면 기기 내 인식을 켤 수 있습니다.
- **Sherpa-ONNX**는 **인식 엔진 설정 → Sherpa 로컬**에서 설정합니다. 언어, 모델 프리셋, CPU/Core ML 백엔드, 자동 언로드 지연 시간을 선택하거나 서드파티 모델 패키지를 가져올 수 있습니다.
- **Doubao Cloud ASR**는 **인식 엔진 설정 → Doubao Cloud ASR**에서 설정합니다. Volcengine API Key를 입력하고 모델 버전을 선택하며 WebSocket endpoint를 유지하거나 수정할 수 있습니다. 처음 Doubao로 전환할 때 클라우드 오디오 처리 확인이 표시됩니다.

## LLM 최적화 (Beta) 설정

메뉴 막대 → **LLM 텍스트 최적화 (Beta)** → **설정** — 프리셋 선택 또는 커스텀 추가, API 키와 모델명 입력. 스트리밍 출력은 캡슐 안에서 실시간으로 미리 볼 수 있습니다.

내장 프리셋: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama(로컬)** / 사용자 정의.

기본 system prompt는 받아쓰기 다듬기에 맞춰 조정(동음이의어, 잘못 인식된 제품명/API 이름, 군더더기, 문장 부호 수정)되며 인식 언어에 따라 자동 전환됩니다. 자신의 prompt로 덮어쓸 수도 있습니다. LLM 텍스트 최적화는 오디오가 아니라 인식 텍스트를 선택한 제공업체로 보냅니다.

## License

Apache License 2.0

개인정보 처리방침: [한국어](privacy/PRIVACY-ko.md) / [English](privacy/PRIVACY-en.md).
