import Foundation

/// Made-up events for trying the app without Claude Code: four folders, teammates, and every state.
/// Used by `swift run fake-events` and by the screenshot tests.
public enum FakeScenario {
    public static let root = "/Users/demo/work"

    public static var events: [HookEvent] {
        let shop = root + "/my-project"
        let overtime = root + "/web-app"
        let blog = root + "/blog"
        let prototype = root + "/prototype"
        return [
            // my-project: working, with three teammates in three states (Plan waits, so the session counts as
            // waiting), and a second session resting
            HookEvent(kind: .sessionStart, session: "demo-b1", cwd: shop),
            HookEvent(kind: .userPromptSubmit, session: "demo-b1", cwd: shop),
            HookEvent(kind: .subagentStart, session: "demo-b1", cwd: shop, agentID: "demo-r", agentType: "Explore"),
            HookEvent(kind: .subagentStart, session: "demo-b1", cwd: shop, agentID: "demo-v", agentType: "Plan"),
            HookEvent(
                kind: .subagentStart, session: "demo-b1", cwd: shop, agentID: "demo-p", agentType: "code-reviewer"),
            HookEvent(kind: .preToolUse, session: "demo-b1", cwd: shop, agentID: "demo-r", agentType: "Explore"),
            HookEvent(
                kind: .permissionRequest, session: "demo-b1", cwd: shop, agentID: "demo-v", agentType: "Plan"),
            HookEvent(
                kind: .notification, session: "demo-b1", cwd: shop, agentID: "demo-p", agentType: "code-reviewer",
                notification: "idle_prompt"),
            HookEvent(kind: .sessionStart, session: "demo-b2", cwd: shop),
            // web-app: waiting for the user's answer
            HookEvent(kind: .sessionStart, session: "demo-o1", cwd: overtime),
            HookEvent(kind: .userPromptSubmit, session: "demo-o1", cwd: overtime),
            HookEvent(kind: .permissionRequest, session: "demo-o1", cwd: overtime),
            // blog: working, with the default helper
            HookEvent(kind: .sessionStart, session: "demo-w1", cwd: blog),
            HookEvent(kind: .userPromptSubmit, session: "demo-w1", cwd: blog),
            HookEvent(kind: .subagentStart, session: "demo-w1", cwd: blog, agentID: "demo-h"),
            // prototype: came and went, so only its folder is left, among the recent folders
            HookEvent(kind: .sessionStart, session: "demo-s1", cwd: prototype),
            HookEvent(kind: .sessionEnd, session: "demo-s1", cwd: prototype),
        ]
    }
}
