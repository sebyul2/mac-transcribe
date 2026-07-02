<p align="center">
  <img src="./public/assets/readme/hero.png" alt="Mac Whisper 히어로" width="720">
</p>

<h1 align="center">Mac Whisper</h1>

<p align="center">
  <em>⌃Fn을 누른 채 말하면, 지금 쓰는 앱에 받아쓴 문장이 붙여넣어집니다.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.0.3-111111?style=flat-square" alt="Version 0.0.3">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-111111?style=flat-square" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111111?style=flat-square" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-5.9-111111?style=flat-square" alt="Swift 5.9">
</p>

<p align="center">
  <sub><a href="./README.md">English</a> &middot; <a href="./README.ko.md">한국어</a></sub>
</p>

<p align="center">
  <a href="https://github.com/spooncast/mac-whisper/releases/latest/download/MacWhisper.dmg"><img src="./public/assets/readme/download-macos.png" alt="Mac OS용 MacWhisper.dmg 다운로드" width="270"></a>
</p>

---

<p align="center">
  <img src="./public/assets/readme/mac-whisper-demo.gif" alt="Mac Whisper 푸시 투 톡 받아쓰기 데모" width="100%">
</p>

Mac Whisper은 푸시 투 톡 받아쓰기를 위한 macOS 메뉴 막대 앱입니다. ⌃Fn(또는
설정한 트리거 키)을 누른 채 말하고 손을 떼면, 포커스가 있는 입력란에
전사문이 붙여넣어집니다.

회의용 긴 발화 녹음 모드도 있습니다. 긴 무음에도 끊기지 않는 핸즈프리
세션으로, 결과는 클립보드가 아니라 파일로 저장됩니다.

붙여넣기 전에 보수적인 LLM 정리 단계를 거칠 수도 있습니다. 이 기능은
선택 사항이며, LLM 요청이 실패하면 원본 전사문을 그대로 사용합니다.

> 창을 바꾸거나 녹음기를 열지 않고, 지금 쓰는 앱에서 바로 글을 넣기 위해
> 만들었습니다.

**앱은 키보드 HID와 NSEvent flagsChanged로 트리거 키를 읽어 —
Karabiner-Elements가 설치되어 있어도 modifier 트리거가 동작합니다 — Speech
framework로 음성을 인식하고, 말하는 동안 플로팅 HUD를 보여줍니다. 붙여넣기는
클립보드와 Cmd+V 시뮬레이션으로 처리합니다. 푸시 투 톡으로 받아쓰는 동안에는
내장 마이크를 우선 사용해 Bluetooth 헤드폰이 고품질 재생 모드를 유지하도록
합니다.**

## 왜 만들었나

macOS 받아쓰기는 쓸 만하지만, 모든 앱에서 짧게 눌러 말하고 바로 붙여넣는
흐름에는 맞지 않습니다. Mac Whisper의 흐름은 단순합니다.

- ⌃Fn(또는 트리거 키)을 누르면 시작
- 손을 떼면 종료
- 말하는 동안 실시간 전사 확인
- 포커스된 입력란에 붙여넣기
- 필요하면 LLM으로 인식 오류 정리

메시지, 메모, 프롬프트, 검색창, 이슈 댓글처럼 커서가 이미 놓인 곳에 짧게
글을 넣는 용도에 맞췄습니다. 회의나 강의, 브레인스토밍처럼 긴 내용은 긴 발화
녹음 모드로 전환해 계속 돌려두면 됩니다.

## 단축키

Fn 단독은 **더 이상** 트리거가 아니므로, Fn+화살표 / Fn+F키 조합에서
받아쓰기가 오발동하지 않습니다.

| 동작 | Apple 키보드 | 모든 키보드 (설정 가능) |
|---|---|---|
| 푸시 투 톡 | ⌃Fn 길게 누르기 | 트리거 키 길게 누르기 (기본: Left Ctrl) |
| 긴 발화 녹음 (토글) | ⌃⇧Fn | 트리거+Shift (기본: Left Ctrl+Shift), 또는 선택적 전용 키 |

두 키 모두 메뉴 → `Trigger Key…`에서 바꿀 수 있습니다(Change…를 누른 뒤
원하는 키를 누르면 캡처됩니다). Karabiner-Elements가 설치되어 있어도 modifier
트리거가 동작합니다. 트리거를 누른 채 다른 키를 누르면 — 단축키 조합으로
쓰는 상황 — 오발동한 받아쓰기 세션이 자동으로 취소됩니다.

## 상태

| 영역 | 동작 | 메모 |
|---|---|---|
| 트리거 | ⌃Fn 또는 설정 가능한 트리거 키 길게 누르기 | 키보드 HID + NSEvent flagsChanged로 읽음, Karabiner 호환 |
| 음성 | 실시간 스트리밍 인식 | 영어, 한국어, 중국어, 일본어 지원 |
| 긴 발화 | 잠금(회의) 녹음 모드 | macOS 26 SpeechAnalyzer 엔진, 긴 무음에도 안정적 |
| HUD | 플로팅 전사 패널 | macOS 26에서 Liquid Glass 사용 |
| 자막 | 자막 오버레이 + 전사 창 | 화면 하단에 마지막 두 문장, 마우스오버 시 닫기 |
| 오디오 | 내장 마이크 우선 (푸시 투 톡) | 긴 발화는 시스템 기본 입력 사용, 원본 오디오 백업 |
| 붙여넣기 | 클립보드와 Cmd+V | 800ms 뒤 changeCount 확인 후 이전 클립보드 복원 |
| LLM | 선택적 정리 | API 키 제공자 또는 ChatGPT Plus/Pro 구독 로그인(OAuth) |
| 용어집 | 사용자 용어 목록 | 음성 인식 힌트와 LLM 프롬프트 양쪽에 반영 |
| 안정성 | 자동 복구 | 연속 에러 시 인식기 재구축, 에러 백오프, 조합 키 취소 |

메뉴에서 할 수 있는 일:

- `Language`로 인식 언어를 바꿉니다.
- `LLM Refinement`로 정리 기능을 켜고 설정(제공자, 모델, ChatGPT 로그인, 용어집)을 엽니다.
- `Auto-stop on Silence`로 조용한 구간 뒤 녹음을 끝냅니다.
- `Start Locked Recording` / `Stop Locked Recording & Save`로 긴 발화 세션을 토글합니다.
- `Transcript Window…`로 긴 발화 실시간 전사 창을 엽니다.
- `Subtitle Overlay`로 긴 발화 세션의 자막 오버레이를 켜고 끕니다.
- `Trigger Key…`에서 받아쓰기 키와 긴 발화 키를 설정합니다.
- `Permissions...`에서 마이크, 음성 인식, 입력 모니터링, 접근성 상태를 봅니다.

## 긴 발화(잠금) 녹음

⌃⇧Fn(또는 트리거+Shift, 또는 전용 긴 발화 키)을 누르면 핸즈프리 세션이
시작되고, 다시 누르면 종료 후 저장됩니다. 녹음 중에는 메뉴바 아이콘이 ⏺로
바뀌고, 시작/종료 사운드와 자막 배지가 표시되어 토글이 확실히 눌렸는지 바로
알 수 있습니다.

- macOS 26의 **SpeechAnalyzer** 장시간 전사 엔진으로 동작해, 회의 시작 전
  조용한 구간이나 발화자 사이의 긴 무음에도 세션이 끊기지 않습니다.
- 전사문은 `~/Documents/MacWhisper/transcript-<날짜>.txt`에 저장됩니다 —
  클립보드는 절대 건드리지 않습니다.
- 원본 오디오는 항상 `recording-<날짜>.m4a`로 백업되므로, 전사가 완전히
  실패해도 녹음 자체는 유실되지 않습니다.
- 부분 전사문은 크래시 복구를 위해 2초마다 자동 저장됩니다.
- 무음만 있던 세션은 통째로 폐기됩니다 — 잔여 파일이 남지 않습니다.
- 실시간 `Transcript Window`(메뉴에서 열기)와 화면 하단의 자막 스타일
  오버레이가 텍스트를 실시간으로 보여줍니다. 오버레이는 마지막 두 문장을
  표시하고, 마우스오버 시 닫기 버튼이 나타나며, 메뉴에서 켜고 끌 수 있습니다.
  오버레이를 닫아도 녹음은 계속됩니다.
- LLM 정리를 켜 두면 원본 전사문을 먼저 저장한 뒤 백그라운드에서 청크 단위로
  보정합니다 — 보정이 실패해도 원본 텍스트는 그대로 남습니다.

## 설치

[Releases](https://github.com/spooncast/mac-whisper/releases/latest)에서 최신
`MacWhisper.dmg`를 내려받아 열고, **Mac Whisper**를 Applications로 옮기세요.

로컬에서 빌드할 수도 있습니다.

```bash
git clone https://github.com/spooncast/mac-whisper.git
cd mac-whisper
make app
open "build/Mac Whisper.app"
```

요구 사항:

- macOS 26+
- Xcode command-line tools
- 마이크 권한
- 음성 인식 권한
- 입력 모니터링 권한
- 접근성 권한

로컬 리빌드 후에도 권한을 유지하려면 자체 서명 인증서를 한 번 만드세요.

```bash
make cert
make app
```

이 인증서가 없으면 임시 서명 때문에 macOS가 리빌드할 때마다 입력 모니터링과
접근성 권한을 다시 요구할 수 있습니다.

## 작동 방식

트리거가 눌리면 앱이 새 음성 세션을 만듭니다.

```text
⌃Fn key down -> start audio engine -> stream recognition -> update HUD
⌃Fn key up   -> stop recognition -> optionally refine -> paste text
```

### LLM 정리

인증 방법은 두 가지입니다.

- **ChatGPT Plus/Pro 구독** — LLM Settings에서 `Sign in with ChatGPT`를
  누르면 브라우저 OAuth로 로그인합니다(API 키 불필요). 모델:
  `gpt-5.4-mini`(기본), `gpt-5.5`, `gpt-5.4`.
- **API 키 제공자** (OpenAI 호환, Anthropic 호환 엔드포인트) — 키는 환경
  변수에서 읽습니다.

```bash
cp .env.example .env
# .env 편집:
#   MACWHISPER_LLM_API_KEY=sk-...
make run
```

Finder에서 실행하는 설치 앱은 아래 명령을 사용할 수 있습니다.

```bash
launchctl setenv MACWHISPER_LLM_API_KEY sk-...
```

같은 내용을 `~/.config/macwhisper/.env`에 넣어도 됩니다.

### 용어집

LLM Settings → Glossary에서 텍스트 파일을 첨부하거나 편집합니다. 한 줄에
용어 하나, `잘못된표기 -> 올바른표기` 줄은 자주 틀리는 전사를 올바른 표기로
매핑하고, `#` 줄은 주석입니다. 등록한 용어는 음성 인식기의 문맥 힌트와 LLM
보정 프롬프트 양쪽에 반영됩니다.

## 빌드

컴파일:

```bash
make build
```

빌드 후 실행:

```bash
make run
```

DMG 생성:

```bash
make dmg
```

## 에이전트용

한 번 빌드하고 실행하려면:

```bash
cd /path/to/mac-whisper
make app
open "build/Mac Whisper.app"
```

빠른 컴파일 확인:

```bash
swift build
```

## 보안

- 앱은 음성을 전사하려고 마이크와 음성 인식 권한을 요청합니다.
- 입력 모니터링은 트리거 키(Fn/Globe와 설정한 키)를 읽는 데만 씁니다.
- 접근성 권한은 포커스된 앱에 텍스트를 붙여넣는 데 씁니다.
- 진단 로그에는 전사문을 쓰지 않습니다.
- LLM API 키는 UserDefaults가 아니라 환경 변수에서 읽습니다.
- ChatGPT OAuth 토큰은 소유자 전용 권한으로 `~/.config/macwhisper/chatgpt-oauth.json`에 저장됩니다.
- 긴 발화 전사문과 오디오 백업은 `~/Documents/MacWhisper`에 로컬로만 남습니다.
- LLM 정리가 실패하면 원본 전사문을 붙여넣거나 그대로 보존합니다.

## 테스트

```bash
swift build
```

macOS 권한, HID 입력, 붙여넣기, 오디오 라우팅은 시스템 상태의 영향을 받으므로
수동 확인도 필요합니다.

## 릴리스

현재 태그: [`0.0.3`](https://github.com/spooncast/mac-whisper/releases/tag/0.0.3)

`0.0.3` 릴리스는 푸시 투 톡 트리거를 ⌃Fn과 설정 가능한 트리거 키로 옮기고,
긴 발화 잠금 녹음 모드(SpeechAnalyzer, 파일 저장, 오디오 백업, 자막 오버레이,
전사 창), LLM 정리를 위한 ChatGPT Plus/Pro 구독 로그인, 사용자 용어집,
인식기와 클립보드 붙여넣기의 안정성 수정을 추가합니다.

## 라이선스

MIT
