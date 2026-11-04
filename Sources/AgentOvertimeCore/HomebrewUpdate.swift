import Foundation

/// Update for an app Homebrew installed: Terminal runs brew in plain view, and the app reopens when the number on
/// disk changes. The script is fixed text, one for each language: no version, no path of this Mac and nothing the
/// app received goes into it, so this file has no string interpolation (a test keeps it that way).
public enum HomebrewUpdate {
    private static let prefixes = ["/opt/homebrew", "/usr/local"]
    private static let caskFolder = "/Caskroom/agent-overtime"

    /// Whether Homebrew put this app here. When unsure the answer is no, and Update opens the release page instead.
    public static func manages(
        location: AppLocation,
        isFolder: (String) -> Bool = { path in
            var folder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
        },
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        location == .ok && prefixes.contains { isFolder($0 + caskFolder) && isExecutable($0 + "/bin/brew") }
    }

    /// The version in the app on disk, read as a file: Bundle.main keeps the one this process started with.
    public static func installedVersion(bundlePath: String) -> ReleaseVersion? {
        guard let data = FileManager.default.contents(atPath: bundlePath + "/Contents/Info.plist"),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let number = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return ReleaseVersion(tag: "v" + number)
    }

    /// The `.command` file. It finds brew itself, at the same two fixed places, and the last line keeps the words on
    /// screen even in a Terminal profile that closes the window when a script ends.
    public static func script(korean: Bool) -> String {
        opening + (korean ? koreanWords : englishWords) + steps
    }

    private static let opening = """
        #!/bin/sh
        rm -f -- "$0"

        """

    private static let englishWords = """
        not_found="Homebrew was not found. Please download the new version from the Releases page."
        not_yet="Homebrew does not have the new version yet. Please try again in a little while."
        updated="Updated. The app reopens in a few seconds. If it does not, open it from Applications."
        blocked="If macOS blocks it: System Settings > Privacy & Security > Open Anyway."
        no_sessions="Until you allow it, sessions will not show in the office."
        failed="The update did not finish, and the app stays as it is. See the lines above."
        finish="Press Return to finish. "

        """

    private static let koreanWords = """
        not_found="Homebrew 를 찾지 못했어요. Releases 페이지에서 새 버전을 받아 주세요"
        not_yet="Homebrew 에 아직 안 올라왔어요. 조금 뒤 다시 해 주세요"
        updated="새 버전을 설치했어요. 앱이 몇 초 뒤 다시 켜져요. 켜지지 않으면 응용 프로그램 폴더에서 열어 주세요"
        blocked="macOS 가 막으면: 시스템 설정 > 개인정보 보호 및 보안 > 그래도 열기"
        no_sessions="허용하기 전에는 세션이 사무실에 안 보여요"
        failed="올리지 못했어요. 지금 앱은 그대로예요. 위 내용을 확인해 주세요"
        finish="Return 키를 누르면 끝나요. "

        """

    private static let steps = """
        run() {
            echo "$*"
            "$@"
        }

        for prefix in /opt/homebrew /usr/local; do
            if [ -d "$prefix/Caskroom/agent-overtime" ] && [ -x "$prefix/bin/brew" ]; then
                room="$prefix/Caskroom/agent-overtime"
                brew="$prefix/bin/brew"
                break
            fi
        done

        if [ -z "$room" ]; then
            echo "$not_found"
        else
            before=$(ls "$room")
            if run "$brew" update && run "$brew" upgrade --cask ykwimk/tap/agent-overtime; then
                if [ "$before" = "$(ls "$room")" ]; then
                    echo "$not_yet"
                else
                    echo "$updated"
                    echo "$blocked"
                    echo "$no_sessions"
                fi
            else
                echo "$failed"
            fi
        fi

        echo
        printf '%s' "$finish"
        read -r _

        """
}
