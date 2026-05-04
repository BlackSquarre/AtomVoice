[English](README.md) | [简体中文](README-zh-Hans.md) | [繁體中文](README-zh-Hant.md) | [日本語](README-ja.md) | **한국어** | [Español](README-es.md) | [Français](README-fr.md) | [Deutsch](README-de.md)

# AtomVoice（原子微語）

<p align="center"><img src="../AppIcon-1024.png" width="128"></p>

경량 macOS 메뉴 바 음성 입력 앱. **Fn** 키를 눌러 녹음하고, 놓으면 텍스트가 현재 입력 필드에 자동 주입됩니다.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

---

### 🔒 개인정보 보호 우선
모든 음성 인식은 Apple의 음성 인식 프레임워크를 사용하여 **기기에서 완전히 처리**됩니다. LLM 최적화를 명시적으로 활성화하지 않는 한 오디오가 서버로 전송되지 않습니다.

### ⚡ 경량
앱 번들 약 3 MB. 유휴 시 CPU 사용량 거의 제로. 백그라운드 데몬 없음.

---

## 기능

- **Fn 키를 눌러** 녹음, 놓으면 텍스트가 입력 필드에 자동 주입
- **스트리밍 전사** — Apple 음성 인식, 기본 중국어(간체)
- **5밴드 FFT 스펙트럼 파형** — 100–6000 Hz, 왼쪽 저주파→오른쪽 고주파, Accelerate 프레임워크 기반
- **자동 문장 부호** — 로컬 규칙 엔진이 문장 끝에 문장 부호 추가, 인터넷 불필요
- **LLM 최적화** — OpenAI 호환 API로 오인식된 단어 자동 수정 (예: 配森→Python); 9개 프로바이더 프리셋 + 커스텀 목록
- **다이나믹 아일랜드 애니메이션** — 120Hz 스프링 물리 시뮬레이션 + 가우시안 블러
- **다크/라이트 모드 자동 전환** — macOS 26에서는 Liquid Glass, 이전 시스템에서는 Visual Effect 블러
- **7개 UI 언어** — 简体中文, 繁體中文, English, 日本語, 한국어, Español, Français, Deutsch
- **CJK IME 호환** — 붙여넣기 전 자동으로 ASCII 입력 소스로 전환

## 시스템 요구 사항

- macOS 13 Ventura 이상
- 필요 권한: **접근성**, **마이크**, **음성 인식**

## 설치

**Release에서 다운로드 (권장)**

[Releases](https://github.com/BlackSquarre/AtomVoice/releases)에서 다운로드 후 zip을 풀고 Applications로 드래그.

**소스에서 빌드**

```bash
git clone https://github.com/BlackSquarre/AtomVoice.git
cd AtomVoice
make install
```

## ⚠️ Gatekeeper 경고

임시 서명 (공증 미완료). 첫 실행 시:

1. `AtomVoice.app` 우클릭 → **열기** → **열기** 클릭
2. 또는 **시스템 설정 → 개인정보 보호 및 보안** → **그래도 열기**
3. 터미널에서 실행: `xattr -cr /Applications/AtomVoice.app`

## 사용법

| 동작 | 결과 |
|------|------|
| Fn 키 누르기 | 녹음 시작 |
| Fn 키 놓기 | 녹음 중지 후 텍스트 주입 |
| 메뉴 바 아이콘 | 언어 / 애니메이션 / LLM 설정 전환 |

## LLM 최적화 설정

메뉴 바 → **LLM 최적화** → **설정** — 프로바이더 프리셋 선택 또는 커스텀 추가, API 키와 모델명 입력.

프리셋: OpenAI / DeepSeek / Moonshot (Kimi) / Qwen / GLM / Yi / Groq / Ollama (로컬)

## 빌드 명령어

```bash
make build    # .app 번들 빌드
make run      # 빌드 후 실행
make install  # /Applications에 설치
make release  # Universal + AppleSilicon + Intel 3개 패키지 빌드
make clean    # 빌드 아티팩트 정리
```

## License

MIT
