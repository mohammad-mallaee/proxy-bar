import Darwin
import Foundation

struct ProcInfo: Hashable, Sendable {
    let pid: pid_t
    let ppid: pid_t
    let path: String
    let startedAtSeconds: Int
    let startedAtMicroseconds: Int32
    var name: String { (path as NSString).lastPathComponent }
}

/// Reads the process table and per-process environment with sysctl / libproc.
enum ProcessInspector {
    /// All processes owned by the current user.
    static func userProcesses() -> [ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between the two calls; leave some slack.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        return procs.prefix(size / stride).compactMap(processInfo)
    }

    /// Revalidates the original process identity before sending either signal.
    static func signal(_ signal: Int32, to target: ProcInfo) -> Bool {
        guard target.pid > 1, target.pid != getpid() else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, target.pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              processInfo(process) == target else { return false }
        return kill(target.pid, signal) == 0
    }

    private static func processInfo(_ process: kinfo_proc) -> ProcInfo? {
        let pid = process.kp_proc.p_pid
        let start = process.kp_proc.p_un.__p_starttime
        guard pid > 0, start.tv_sec > 0, process.kp_eproc.e_ucred.cr_uid == getuid(),
              let path = executablePath(of: pid) else { return nil }
        return ProcInfo(pid: pid, ppid: process.kp_eproc.e_ppid, path: path,
                        startedAtSeconds: start.tv_sec, startedAtMicroseconds: start.tv_usec)
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        return len > 0 ? String(cString: buf) : nil
    }

    /// The environment a process was started with, or nil if macOS won't show it.
    static func environment(of pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }

        // Layout: argc (int32), exec path, NUL padding, argv[argc], envp..., NUL
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // exec path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var seen: Int32 = 0
        while i < size && seen < argc {            // argv
            while i < size && buf[i] != 0 { i += 1 }
            i += 1
            seen += 1
        }

        var env: [String: String] = [:]
        while i < size && buf[i] != 0 {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if let entry = String(bytes: buf[start..<i], encoding: .utf8),
               let eq = entry.firstIndex(of: "=") {
                env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            }
            i += 1
        }
        return env
    }
}
