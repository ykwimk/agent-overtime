// agent-overtime-hook: run by the plugin's hooks for every Claude Code session on this Mac.
// Reads the hook JSON from stdin, keeps only the allowlisted state fields, sends one line to the app's socket.
import Darwin
import Foundation

// Claude Code hands an async hook's output to the model on the next turn, so this tool never prints anything.
let devNull = open("/dev/null", O_RDWR)
if devNull >= 0 {
    dup2(devNull, STDOUT_FILENO)
    dup2(devNull, STDERR_FILENO)
}
signal(SIGPIPE, SIG_IGN)
// Hard stop after 0.5 s, always with exit 0: a hook must never hold up or fail a session.
signal(SIGALRM) { _ in _exit(0) }
var timer = itimerval(it_interval: timeval(), it_value: timeval(tv_sec: 0, tv_usec: 500_000))
setitimer(ITIMER_REAL, &timer, nil)

func readInput() -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(STDIN_FILENO, &buffer, buffer.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 { return data }
        data.append(buffer, count: n)
        if data.count > Limits.hookInput { return nil }
    }
}

/// The Claude Code process: our parent, or the first non-shell above us if a shell sits in between.
func sessionPID() -> Int32? {
    var pid = getppid()
    for _ in 0..<3 {
        guard pid > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !["sh", "bash", "zsh", "dash", "fish"].contains(name) { return pid }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

if let input = readInput(), let event = HookEvent.fromHookInput(input, pid: sessionPID()) {
    EventClient.send(event.wireLine(), to: Paths.socket())
}
exit(0)
