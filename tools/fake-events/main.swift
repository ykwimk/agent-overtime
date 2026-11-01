// Sends made-up events to a running Agent Overtime, so you can see every state without Claude Code.
//   swift run fake-events
import AgentOvertimeCore
import Foundation

let path = Paths.socket()
var sent = 0
for event in FakeScenario.events {
    if EventClient.send(event.wireLine(), to: path) { sent += 1 }
    usleep(150_000)
}
print(
    sent == FakeScenario.events.count
        ? "Sent \(sent) events to \(path)"
        : "Sent \(sent) of \(FakeScenario.events.count) events. Is Agent Overtime open?")
