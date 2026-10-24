import Darwin
import Foundation

/// Thin wrappers over libproc / sysctl. No `ps` subprocesses, no special permissions.
public enum Proc {
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    public static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 128)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    public struct BSDInfo {
        public var ppid: pid_t
        public var uid: uid_t
        public var startSec: UInt64
    }

    public static func bsdInfo(_ pid: pid_t) -> BSDInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return BSDInfo(ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid, startSec: info.pbi_start_tvsec)
    }

    /// Controlling terminal, e.g. "/dev/ttys003", or nil for processes without one.
    public static func tty(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev != UInt32(bitPattern: -1), info.e_tdev != 0,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s.hasPrefix("tty") ? "/dev/" + s : nil
    }

    public static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Total user+system CPU time in nanoseconds.
    public static func cpuTime(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // On Apple Silicon these are mach ticks, not ns.
        let ticks = info.pti_total_user + info.pti_total_system
        return ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    public static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let s = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return s.isEmpty ? nil : s
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public static func arguments(_ pid: pid_t) -> [String] {
        // Most argument lists fit in 16 KB; only fall back to the 1 MB system maximum when they don't.
        var buf = [UInt8](repeating: 0, count: 16_384)
        var size = buf.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        if sysctl(&mib, 3, &buf, &size, nil, 0) != 0 {
            guard errno == ENOMEM else { return [] }
            var argmax: Int32 = 0
            var asize = MemoryLayout<Int32>.size
            var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
            guard sysctl(&mibMax, 2, &argmax, &asize, nil, 0) == 0, argmax > 0 else { return [] }
            buf = [UInt8](repeating: 0, count: Int(argmax))
            size = buf.count
            guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        }
        guard size > 4 else { return [] }

        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 } // exec path
        while i < size && buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

public struct AgentProcess: Sendable {
    public var pid: pid_t
    public var kind: AgentKind
    public var cwd: String?
    /// CPU % of the agent plus everything it spawned (tool runs, builds, ...), since the last scan.
    public var cpu: Double
    public var started: Date
    /// App-embedded helper (see AgentKind.helperPaths): not a session by itself.
    public var isHelper: Bool
}

/// Finds running agents and measures how busy they are. Keep one instance; it remembers
/// previous CPU samples to compute rates.
public final class ProcessScanner {
    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevTime: TimeInterval = 0
    private var matchCache: [pid_t: (start: UInt64, kind: AgentKind?)] = [:]

    public init() {}

    public func scan(kinds: [AgentKind]) -> [AgentProcess] {
        let me = getuid()
        var info: [pid_t: Proc.BSDInfo] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for pid in Proc.allPIDs() {
            guard let bi = Proc.bsdInfo(pid), bi.uid == me else { continue }
            info[pid] = bi
            children[bi.ppid, default: []].append(pid)
        }

        var matched: [pid_t: AgentKind] = [:]
        var newCache: [pid_t: (start: UInt64, kind: AgentKind?)] = [:]
        for (pid, bi) in info {
            let kind: AgentKind?
            if let c = matchCache[pid], c.start == bi.startSec {
                kind = c.kind
            } else {
                kind = Proc.path(pid).flatMap { AgentCatalog.match(path: $0, pid: pid, kinds: kinds) }
            }
            newCache[pid] = (bi.startSec, kind)
            if let kind { matched[pid] = kind }
        }
        matchCache = newCache

        // Drop wrappers/children of the same agent (e.g. a node shim that execs `claude`).
        let roots = matched.filter { pid, kind in
            var p = info[pid]?.ppid ?? 0
            var hops = 0
            while p > 1, hops < 32 {
                if matched[p]?.id == kind.id { return false }
                p = info[p]?.ppid ?? 0
                hops += 1
            }
            return true
        }

        let now = Date().timeIntervalSince1970
        let dt = prevTime > 0 ? now - prevTime : 0
        var nextCPU: [pid_t: UInt64] = [:]
        var result: [AgentProcess] = []
        for (pid, kind) in roots {
            var total = 0.0
            var stack = [pid]
            var seen = Set<pid_t>()
            while let p = stack.popLast() {
                guard seen.insert(p).inserted else { continue }
                if let t = Proc.cpuTime(p) {
                    nextCPU[p] = t
                    if let old = prevCPU[p], t >= old { total += Double(t - old) }
                }
                stack.append(contentsOf: children[p] ?? [])
            }
            let pct = dt > 0 ? total / (dt * 1e9) * 100 : 0
            let started = Date(timeIntervalSince1970: TimeInterval(info[pid]?.startSec ?? 0))
            let path = Proc.path(pid) ?? ""
            let helper = (kind.helperPaths ?? []).contains { path.contains($0) }
            result.append(AgentProcess(pid: pid, kind: kind, cwd: Proc.cwd(pid), cpu: pct, started: started, isHelper: helper))
        }
        prevCPU = nextCPU
        prevTime = now
        return result
    }

    /// Walk up from `pid` to find the agent process that (indirectly) launched it. Used by hooks.
    public static func agentAncestor(of pid: pid_t, agentID: String, kinds: [AgentKind]) -> pid_t? {
        var p = pid
        for _ in 0..<12 {
            guard p > 1, let path = Proc.path(p) else { break }
            if AgentCatalog.match(path: path, pid: p, kinds: kinds)?.id == agentID { return p }
            guard let bi = Proc.bsdInfo(p) else { break }
            p = bi.ppid
        }
        return nil
    }
}
