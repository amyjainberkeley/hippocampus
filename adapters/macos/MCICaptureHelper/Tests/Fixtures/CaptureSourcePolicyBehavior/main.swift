import MCICaptureHelperKit

private struct SecureInput: SecureEventInputProbe {
    func isSecureEventInputEnabled() -> Bool { false }
}

private struct NonSecureAX: AXSecureSubroleProbe {
    func focusedHasSecureSubrole() -> Bool? { false }
}

private struct NoDenylist: DenylistProbe {
    func appIsDenied(bundleId _: String) -> Bool { false }
    func urlIsDenied(_: String) -> Bool { false }
    func windowTitleIsDenied(_: String) -> Bool { false }
}

private struct NoBlackRegion: BlackedRegionProbe {
    func hasBlackedRegion() -> Bool { false }
}

@main
struct CaptureSourcePolicyBehavior {
    static func main() {
        let cascade = SuppressionCascade(
            secureEventInput: SecureInput(),
            axSecureSubrole: NonSecureAX(),
            denylist: NoDenylist(),
            blackedRegion: NoBlackRegion(),
            knownSafeAppBundles: ["com.apple.Safari", "com.apple.Terminal"],
            rawPixelExcludedAppBundles: BrowserPixelCapturePolicy.excludedBundleIds
        )

        precondition(
            cascade.decide(context: WorkflowContext(appBundleId: "com.apple.Safari"))
                == .suppress(reason: .failsafeUnknown)
        )
        precondition(
            cascade.decide(context: WorkflowContext(appBundleId: "com.apple.Terminal"))
                == .allow
        )
    }
}
