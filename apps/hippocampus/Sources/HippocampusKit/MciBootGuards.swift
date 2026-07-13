// SPDX-License-Identifier: TBD-private
import Foundation

/// Boot-time hardware architecture guard.
///
/// Hippocampus's local-AI stack (Core ML brief-author, on-device
/// embeddings, Neural Engine inference) is Apple Silicon-only by
/// design. On Intel Macs — including Rosetta-translated launches on
/// otherwise-unsupported machines — Core ML backends silently degrade
/// or crash. Cycle 8.44 product-readiness audit flagged this as a
/// cheap high-leverage fail-fast: hard block at boot with a clear
/// NSAlert rather than let the user hit a mid-session crash.
///
/// We check the HOST hardware (`hw.optional.arm64`), not the running
/// process arch — a native Intel binary and a Rosetta-translated
/// arm64 binary both surface the host CPU here, so a user running
/// Hippocampus under Rosetta on an Intel Mac is correctly flagged
/// as "Intel host". No env-override / bypass flag: Intel is
/// unsupported, period.
public enum MciBootGuards {
    /// `true` when the running Mac has Apple Silicon (M-series) hardware.
    /// `false` on Intel Macs regardless of the running process's arch.
    public static func hostIsAppleSilicon() -> Bool {
        // Primary: sysctl `hw.optional.arm64` — returns 1 on Apple Silicon
        // hosts (including when queried by an arm64 process under Rosetta,
        // which cannot happen, and by an x86_64 process under Rosetta,
        // which does surface the true host value).
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }

        // Fallback: uname().machine — on Apple Silicon this is "arm64".
        var info = utsname()
        guard uname(&info) == 0 else { return false }
        let machine = withUnsafePointer(to: &info.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return machine.hasPrefix("arm64")
    }
}
