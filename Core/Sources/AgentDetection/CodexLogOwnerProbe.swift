import Darwin
import Foundation
import TranscriptSupport

/// A currently open writable rollout, identified by both path and vnode.
/// No command line, environment, or transcript contents are inspected.
public struct CodexLogOwner: Equatable, Sendable {
    public let url: URL
    public let pid: pid_t
    public let identity: TranscriptFileStat

    public init(url: URL, pid: pid_t, identity: TranscriptFileStat) {
        self.url = url.standardizedFileURL
        self.pid = pid
        self.identity = identity
    }
}

public protocol CodexLogOwnerProbing {
    func openLogs() -> [CodexLogOwner]
}

/// libproc is read-only and needs no helper process or extra privileges.
/// Failed/partial probes simply omit evidence; a running app alone is never
/// enough to prolong a hold. The monitor calls this at most once per 30 s.
public struct CodexLogOwnerProbe: CodexLogOwnerProbing {
    private let prefixes: [String]

    public init(activityRoots: [URL]) {
        prefixes = activityRoots.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        }
    }

    public func openLogs() -> [CodexLogOwner] {
        guard !prefixes.isEmpty else { return [] }
        // Explicit bounds keep process churn or an enormous fd table cheap.
        var pids = [pid_t](repeating: 0, count: 16_384)
        let pidBytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, pidBytes) }
        guard count > 0 else { return [] }
        var result: [CodexLogOwner] = []
        var runtimes = 0
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            // PROC_PIDPATHINFO_MAXSIZE is a C expression unavailable in Swift.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathBytes = UInt32(path.count)
            guard proc_pidpath(pid, &path, pathBytes) > 0,
                  URL(fileURLWithPath: String(cString: path)).lastPathComponent == "codex"
            else { continue }
            runtimes += 1
            if runtimes > 64 { break }
            result.append(contentsOf: writableLogs(pid: pid))
        }
        // Two descriptors can refer to the same recorder. Choose one witness.
        var seen: Set<URL> = []
        return result.sorted { $0.url.path < $1.url.path }.filter {
            seen.insert($0.url).inserted
        }
    }

    private func writableLogs(pid: pid_t) -> [CodexLogOwner] {
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 4096)
        let fdBytes = Int32(fds.count * MemoryLayout<proc_fdinfo>.stride)
        let bytes = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, fdBytes)
        }
        guard bytes > 0 else { return [] }
        var result: [CodexLogOwner] = []
        for fd in fds.prefix(min(Int(bytes) / MemoryLayout<proc_fdinfo>.stride, fds.count))
        where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size,
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard (path as NSString).pathExtension == "jsonl" else { continue }
            // libproc spells temp paths /private/var; Foundation commonly
            // spells the same path /var. Normalize both ends identically.
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard prefixes.contains(where: { url.path.hasPrefix($0) }) else { continue }
            let stat = info.pvip.vip_vi.vi_stat
            result.append(CodexLogOwner(
                url: url, pid: pid,
                identity: TranscriptFileStat(size: UInt64(max(0, stat.vst_size)),
                                            deviceID: UInt64(bitPattern: Int64(Int32(bitPattern: stat.vst_dev))),
                                            inode: stat.vst_ino)
            ))
        }
        return result
    }
}
