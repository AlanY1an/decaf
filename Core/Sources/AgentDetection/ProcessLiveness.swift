// ProcessLiveness — kill(pid, 0) style process-existence probe (plan 02 §1.2).
//
// The PPID sweep is the hooks layer's only crash fallback: an agent killed with
// SIGKILL never sends SessionEnd, so each reconcile tick probes every tracked
// session's agent pid and removes sessions whose process is gone.
//
// PID-reuse risk is accepted (plan 02 R2): within a 30 s tick the reuse
// probability is negligible, and the grace period + idle_prompt channels bound
// any zombie hold.

import Darwin

public enum ProcessLiveness {

    /// Probe closure shape injected into `SessionRegistry` / `DetectionCoordinator`.
    public typealias Probe = (pid_t) -> Bool

    /// Returns true when a process with `pid` exists (signal 0 delivery check).
    ///
    /// - `kill(pid, 0) == 0` — process exists and is signalable.
    /// - `errno == ESRCH` — no such process: dead.
    /// - any other errno (notably `EPERM`) — the process exists but is not
    ///   ours to signal: alive.
    ///
    /// Non-positive pids are reported dead: 0 / negative values would address
    /// process groups, and a session with an unknown ppid must not become an
    /// unsweepable zombie hold.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
