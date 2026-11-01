# Agent Overtime

**Your agents' office, lights on all night.** · **불 꺼지지 않는 에이전트 사무실**

A small macOS app that shows your Claude Code sessions and their subagents working in a pixel office:
who is working, who is waiting for your answer, who is resting, and who has gone home.
Works with Claude Code. Not affiliated with Anthropic.

[한국어](#한국어) · [English](#english)

---

## 한국어

Claude Code 세션을 여럿 돌릴 때 터미널을 하나씩 들여다보지 않고 "누가 일하고, 쉬고, 내 답을 기다리나"를 봅니다.
로그인이 없고, 모든 것이 이 맥 안에서만 돕니다. Claude Code 와 함께 써요. Anthropic 과 관계없는 오픈소스 앱입니다.

| 상태 | 뜻 | 그림 |
|---|---|---|
| 일하는 중 | 답을 만드는 중 | 책상에서 타자, 점 세 개 |
| 답 기다림 · n분째 | 내가 허락하거나 답해야 다음으로 감 | 일어나 손 듦, `!` 말풍선 |
| 쉬는 중 | 할 일을 끝내고 다음 지시를 기다림 | 의자에 기대 졸음, `z` |
| 퇴근 | 세션이 꺼짐 | 빈 책상, 흐린 이름표 |

- 책상 섬 하나 = 세션을 켠 폴더 하나 (이름표 = 폴더 이름). 같은 폴더의 두 번째 세션은 옆자리 "이름 2"
- 서브에이전트는 그 섬의 팀원 (이름표 = 에이전트 이름, 이름 없는 기본 에이전트는 "도우미")
- 메뉴바: 답 기다리는 세션이 있으면 `! 2` 처럼 바뀝니다
- 출근 버튼 (선택): 등록한 폴더에서 등록한 명령 하나를 새 터미널 창으로 켭니다 (예: `claude`, 여러 세션을 켜는 내 스크립트 `./start.sh`)

### 설치
1. [Releases](https://github.com/ykwimk/agent-overtime/releases) 에서 `.dmg` 를 받아 `AgentOvertime.app` 을 **응용 프로그램** 폴더로 끕니다. 이름은 그대로 둡니다 (플러그인이 `/Applications/AgentOvertime.app` 또는 `~/Applications/AgentOvertime.app` 에서 앱을 찾습니다).
2. 처음 열면 맥이 막습니다 (Apple 공증을 받지 않은 앱). **시스템 설정 > 개인정보 보호 및 보안** 맨 아래의 **Open Anyway (그래도 열기)** 를 누르고, 다시 뜨는 창에서 **열기**. macOS 13·14 는 Finder 에서 우클릭 > 열기 도 됩니다. macOS 15 부터는 시스템 설정 길 하나뿐입니다.
3. 처음 여는 창의 **연결 명령 복사** 를 누르고, Claude Code 에 아래 두 줄을 붙여 넣습니다.

```
/plugin marketplace add ykwimk/agent-overtime
/plugin install agent-overtime@agent-overtime
```

4. Claude Code 에 한 마디 보내면 사무실 자리에 캐릭터가 들어와 앉습니다. 앱보다 먼저 켠 세션은 다음에 움직일 때 나타납니다.

### 끊기
Claude Code 에서 `/plugin` 으로 `agent-overtime` 을 끄거나 지웁니다. 앱은 Claude Code 설정 파일을 읽지도 고치지도 않습니다.

### 무엇을 받고 무엇을 남기나
- 플러그인 훅 (`plugin/hooks/hooks.json`, 이 저장소에 공개) 이 앱 안의 작은 도우미 `agent-overtime-hook` 을 부릅니다.
- 도우미는 Claude Code 가 주는 소식에서 **이벤트 이름, 세션 구분값, 폴더 경로, 서브에이전트 구분값·이름, 알림 종류, 질문 도구인지 여부, Claude Code 프로세스 번호** 만 뽑아 앱에 넘깁니다. 도구 입력·프롬프트·파일 내용·대화 기록은 읽자마자 버립니다.
- 도우미는 아무것도 출력하지 않고 (출력은 Claude 대화에 섞일 수 있어서), 0.5초 안에 언제나 정상 종료합니다.
- 앱과 도우미는 내 사용자만 열 수 있는 유닉스 소켓 (`~/Library/Application Support/AgentOvertime/events.sock`, 폴더 0700·파일 0600) 으로만 이야기합니다. 네트워크 포트를 열지 않고, 인터넷으로 아무것도 보내지 않습니다 (업데이트 확인·사용 통계·오류 보고 없음).
- 받은 소식으로는 그림만 바뀝니다. 소식으로는 어떤 명령도 실행하지 않습니다.
- 디스크에는 기억한 자리 (폴더 경로) 와 출근 명령만 `config.json` (0600) 에 남습니다. 지우기는 설정 > 자리.
- 화면에는 상태만 보입니다. 도구 이름·명령·파일 경로는 띄우지 않습니다.

### 출근 버튼
- 등록 시트가 곧 실행 확인입니다. 폴더와 인자를 한 줄에 하나씩, 자르지 않고 보이고, 보이지 않는 글자 (예: `⟨U+200B⟩`) 는 드러내 표시합니다.
- 승인한 명령의 지문은 설정 파일 밖에 둡니다. `config.json` 이 앱 밖에서 바뀌면 다음 출근 때 원문을 다시 보이고 확인받습니다.
- 명령은 셸이 다시 읽지 않도록 인자마다 작은따옴표로 감싼 `.command` 파일 (0700, 실행하자마자 스스로 지움) 로 만들어 터미널이 엽니다. 앱은 명령에 옵션을 덧붙이지 않습니다.
- 등록한 폴더 (또는 그 안) 에 이미 켜진 세션이 있으면 "이미 출근했어요. 하나 더 켤까요?" 를 묻습니다.

### 직접 빌드
Xcode 16 이상, macOS 13 이상.

```
swift test                                   # 핵심 로직 (허용 목록, 상태, 따옴표, 소켓, 플러그인 파일)
xcodebuild -project AgentOvertime.xcodeproj -scheme AgentOvertime -configuration Release -derivedDataPath build build
xcodebuild -project AgentOvertime.xcodeproj -scheme AgentOvertime -derivedDataPath build test   # 앱 안 시험 + captures/ 캡처
swift run fake-events                        # 켜 둔 앱에 가짜 소식 보내기 (Claude Code 없이 네 상태 보기)
```

### 남은 일 (v0.1 공개 전)
- 실제 Claude Code 에 플러그인을 설치한 시험: 이벤트가 오는지, 퇴근 판정 (프로세스 번호) 이 맞는지
- `.dmg`·ad-hoc 서명·`codesign --verify --deep --strict`·SHA-256, Apple 칩 맥 실기
- 이 README 의 Open Anyway 캡처, 앱 아이콘

---

## English

See who is working, who is waiting for you, and who is resting across all your Claude Code sessions, without checking each terminal.
No login. Everything stays on this Mac. Works with Claude Code. Not affiliated with Anthropic.

| State | Meaning | Picture |
|---|---|---|
| Working | Producing an answer | Typing at the desk, three dots |
| Waiting · n min | Needs your permission or answer | Standing, hand raised, `!` bubble |
| Resting | Finished, waiting for the next instruction | Leaning back, `z` |
| Off duty | Session ended | Empty desk, dimmed name |

- One desk island per folder a session started in. A second session in the same folder sits next to it as "name 2".
- Subagents are teammates at that island (named by agent type; the default one is "Helper").
- The menu bar icon turns into `! 2` while sessions wait for you.
- Start Work (optional): runs one command you register, in a folder you choose, in a new Terminal window.

### Install
1. Download the `.dmg` from [Releases](https://github.com/ykwimk/agent-overtime/releases) and drag `AgentOvertime.app` into **Applications**. Keep its name: the plugin looks for `/Applications/AgentOvertime.app` or `~/Applications/AgentOvertime.app`.
2. The first launch is blocked because the app is not notarized. Open **System Settings > Privacy & Security**, click **Open Anyway**, then **Open**. On macOS 13 and 14, right-click > Open in Finder also works; from macOS 15 the System Settings route is the only one.
3. Click **Copy Connect Commands** in the first window and paste the two lines into Claude Code:

```
/plugin marketplace add ykwimk/agent-overtime
/plugin install agent-overtime@agent-overtime
```

4. Send Claude Code a message. Your character walks in and sits down. Sessions started before the app appear when they next move.

### Disconnect
Turn off or remove `agent-overtime` with `/plugin` in Claude Code. The app never reads or edits Claude Code's settings files.

### Privacy and security
- The plugin's hooks (`plugin/hooks/hooks.json`, public in this repo) call a small helper inside the app, `agent-overtime-hook`.
- The helper keeps only: event name, session id, folder path, subagent id and name, notification type, whether the tool is AskUserQuestion, and the Claude Code process id. Tool input, prompts, file contents and transcripts are discarded unread.
- The helper prints nothing (async hook output can reach the conversation) and always exits 0 within 0.5 s.
- App and helper talk only over a unix socket that only your user can open (`~/Library/Application Support/AgentOvertime/events.sock`, folder 0700, file 0600). No network ports, nothing sent over the internet, no update checks, analytics or crash reports.
- Incoming events only change the picture; nothing in them is ever executed.
- On disk: remembered desks (folder paths) and the start command, in `config.json` (0600). Clear desks in Settings.
- The screen shows states only, never tool names, commands or file paths.

### Start Work
- The setup sheet is the confirmation: folder and each argument on their own line, never truncated, hidden characters spelled out (e.g. `⟨U+200B⟩`).
- The approved fingerprint lives outside the config file; if `config.json` changes outside the app, the next start shows the command again for confirmation.
- The command is written as a single-quoted `.command` file (0700, deletes itself first) and opened by Terminal. The app never adds options to your command.

### Build it yourself
Xcode 16+, macOS 13+. See the commands in the Korean section above.

## License
MIT. The pixel art is drawn in code for this app (MIT); no third-party art.
