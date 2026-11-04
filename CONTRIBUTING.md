# Contributing

Thanks for helping. Agent Overtime is maintained by one person; we'll reply as soon as we can. English or Korean are both fine (한국어로 써도 돼요).

- Bugs and ideas: open an issue (there is a form for each). For a bigger change, please open an issue first so we agree on it before you write code.
- Security problems: not in a public issue. See [SECURITY.md](SECURITY.md).

## Pull requests

- One change per pull request. Title: `<type>: <summary>`, where type is `feat`, `fix`, `docs`, `refactor`, `test`, `style`, `perf`, `build` or `chore`. Example: `fix: empty office after waking from sleep`. Pull requests are squash-merged, so the title becomes the commit on main.
- If you change the README, change both files: `README.md` (English) and `README.ko.md` (Korean). A test checks that they keep the same sections and commands.
- No new dependencies. The only network access in the app is the update check and the download after the user clicks Update.
- Code comments in English.

## Before you open one

macOS with Xcode 16 or later. Run these three; the pull request runs them again on GitHub Actions.

```
swift format lint --recursive App AppTests Helper Sources Tests tools Package.swift
swift test
xcodebuild -project AgentOvertime.xcodeproj -scheme AgentOvertime -configuration Release -derivedDataPath build build
```

`swift format --in-place --recursive …` with the same paths fixes most lint warnings. If you changed what the app shows, attach screenshots: `xcodebuild -project AgentOvertime.xcodeproj -scheme AgentOvertime -derivedDataPath build test` saves them in `captures/`.
