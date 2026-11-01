import Foundation

/// Made-up events for trying the app without Claude Code: four desks, teammates, and every state.
/// Used by `swift run fake-events` and by the screenshot tests.
public enum FakeScenario {
    public static let root = "/Users/demo/work"

    public static var events: [HookEvent] {
        let shop = root + "/web-shop"
        let overtime = root + "/agent-overtime"
        let blog = root + "/blog"
        let prototype = root + "/prototype"
        return [
            // web-shop: working, with three teammates in three states (the verifier waits, so the session
            // counts as waiting), and a second session resting
            HookEvent(kind: .sessionStart, session: "demo-b1", cwd: shop),
            HookEvent(kind: .userPromptSubmit, session: "demo-b1", cwd: shop),
            HookEvent(kind: .subagentStart, session: "demo-b1", cwd: shop, agentID: "demo-r", agentType: "researcher"),
            HookEvent(kind: .subagentStart, session: "demo-b1", cwd: shop, agentID: "demo-v", agentType: "verifier"),
            HookEvent(kind: .subagentStart, session: "demo-b1", cwd: shop, agentID: "demo-p", agentType: "planner"),
            HookEvent(kind: .preToolUse, session: "demo-b1", cwd: shop, agentID: "demo-r", agentType: "researcher"),
            HookEvent(
                kind: .permissionRequest, session: "demo-b1", cwd: shop, agentID: "demo-v", agentType: "verifier"),
            HookEvent(
                kind: .notification, session: "demo-b1", cwd: shop, agentID: "demo-p", agentType: "planner",
                notification: "idle_prompt"),
            HookEvent(kind: .sessionStart, session: "demo-b2", cwd: shop),
            // agent-overtime: waiting for the user's answer
            HookEvent(kind: .sessionStart, session: "demo-o1", cwd: overtime),
            HookEvent(kind: .userPromptSubmit, session: "demo-o1", cwd: overtime),
            HookEvent(kind: .permissionRequest, session: "demo-o1", cwd: overtime),
            // blog: working, with the default helper
            HookEvent(kind: .sessionStart, session: "demo-w1", cwd: blog),
            HookEvent(kind: .userPromptSubmit, session: "demo-w1", cwd: blog),
            HookEvent(kind: .subagentStart, session: "demo-w1", cwd: blog, agentID: "demo-h"),
            // prototype: came and went, so its desk is off duty
            HookEvent(kind: .sessionStart, session: "demo-s1", cwd: prototype),
            HookEvent(kind: .sessionEnd, session: "demo-s1", cwd: prototype),
        ]
    }
}
