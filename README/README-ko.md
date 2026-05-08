[English](../README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | **한국어** | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice

<p align="center"><img src="AppIcon-1024.png" width="128"></p>

<h3 align="center">누르고, 말하세요.</h3>
<p align="center">가볍고 프라이버시 우선의 음성 받아쓰기. 텍스트가 어떤 Mac 앱에든 직접 입력되며, 녹음 시간 제한이 없습니다.</p>



---

### 🔒 프라이버시 우선
음성 인식은 기본적으로 **기기 내에서 수행**됩니다 — Apple 음성 인식 또는 내장된 Sherpa-ONNX 로컬 엔진 중 선택. LLM 텍스트 최적화를 직접 활성화하지 않는 한 오디오는 Mac 밖으로 나가지 않습니다.

### ⚡ 가벼운 설계
앱 번들이 작고, 유휴 시 CPU 사용률은 거의 0이며, 백그라운드 데몬도 없습니다. Sherpa 모델은 필요할 때 다운로드되고 메모리 압박 시 자동으로 해제됩니다.

---

## 기능

### 녹음과 트리거
- **눌러서 말하기 / 한 번 눌러 말하기** — 원하는 모드를 선택, 무음 자동 정지와 결합 가능
- **트리거 키 사용자 지정** — 자기 키보드에 맞는 수정자 키 선택
- **녹음 중 단축키** — 한 번에 취소, LLM 건너뛰고 즉시 삽입, 또는 지정한 문장 부호로 마무리
- **앱 전환 시 자동 취소**(눌러서 말하기 모드에서만)

### 인식 엔진
- **Apple 음성 인식** — 스트리밍, 기기 내 인식 옵션, **롤링 분할**로 SFSpeechRecognizer의 1분 한계 돌파
- **Sherpa-ONNX** — 완전 오프라인 로컬 엔진, 첫 사용 시 모델 자동 다운로드, 문장 부호 모델 포함
- **8개 인식 언어** — English, 简体中文, 繁體中文, 日本語, 한국어, Español, Français, Deutsch

### 텍스트 출력
- **Apple 실시간 삽입** — 녹음 중 완성된 문장이 자동으로 삽입되어, 키를 놓을 때까지 기다릴 필요 없음
- **스마트 문장 부호** — 로컬 휴리스틱 엔진(언어별), 커서 뒤에 이미 문장 부호가 있으면 자동 건너뜀
- **CJK 입력기 호환** — 붙여넣기 전 임시로 ASCII 레이아웃으로 전환 후 복원
- **LLM 텍스트 최적화** — OpenAI 호환 프로토콜과 **Anthropic** 모두 지원, 스트리밍 미리보기, 10개 프리셋 + 자유 편집 가능한 커스텀 목록, 다국어 기본 system prompt 또는 사용자 prompt

### UI와 애니메이션
- **5 밴드 FFT 스펙트럼 파형** — 사람 음성에 맞춰 조정(100–4200 Hz), Accelerate 기반
- **3가지 애니메이션 스타일** — Dynamic Island(Spotlight 풍 스프링 + 가우시안 블러)/ 미니멀 / 없음, 3단계 속도, ProMotion 120Hz 지원
- **Liquid Glass**(macOS 26) / **Visual Effect 블러**(macOS 14/15)
- **8개 UI 언어**, 시스템 언어 자동 감지

### 시스템 통합
- **자동 업데이트** — GitHub Releases에서 가져오고 코드 서명 검증 포함(Beta 채널 옵션)
- **로그인 시 자동 시작**(SMAppService)
- **오디오 입력 장치 선택** — 임의의 시스템 마이크 선택 가능
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
make install
```

## ⚠️ 서명 안내

임시 서명, Apple 공증을 받지 않았습니다. 처음 열 때:

1. `AtomVoice.app` 우클릭 → **열기** → **열기** 클릭
2. 또는 **시스템 설정 → 개인 정보 보호 및 보안** → **그래도 열기**
3. 또는 터미널에서: `xattr -cr /Applications/AtomVoice.app`

## 사용법

| 동작 | 결과 |
|------|------|
| 트리거 키 길게 누르기 | 녹음 시작(눌러서 말하기 모드) |
| 트리거 키 떼기 | 녹음 종료 후 텍스트 삽입 |
| 트리거 키 한 번 누르기 | 녹음 시작 / 종료(한 번 누르기 모드) |
| 녹음 중 `ESC` | 취소, 텍스트 삽입 안 됨 |
| 녹음 중 `Space` / `Backspace` | 즉시 삽입, LLM 건너뜀 |
| 녹음 중 문장 부호 입력 | 즉시 삽입 후 해당 문장 부호 추가 |
| 메뉴 막대 아이콘 | 엔진 / 언어 / 모드 / 애니메이션 / LLM 전환 |

## LLM 최적화 설정

메뉴 막대 → **LLM 텍스트 최적화** → **설정** — 프리셋 선택 또는 커스텀 추가, API 키와 모델명 입력. 스트리밍 출력은 캡슐 안에서 실시간으로 미리 볼 수 있습니다.

내장 프리셋: **OpenAI** / **Anthropic** / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / **Ollama(로컬)** / 사용자 정의.

기본 system prompt는 받아쓰기 다듬기에 맞춰 조정(동음이의어, 잘못 인식된 제품명/API 이름, 군더더기, 문장 부호 수정)되며 인식 언어에 따라 자동 전환됩니다. 자신의 prompt로 덮어쓸 수도 있습니다.

## License

Apache License 2.0
