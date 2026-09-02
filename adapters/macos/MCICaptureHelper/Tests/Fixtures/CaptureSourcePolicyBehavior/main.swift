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
        let qualificationArguments = [
            "mci-capture-helper",
            "--capture",
            "--probe-debug",
            LiveOCRQualification.flag,
        ]
        let qualificationEnvironment = [
            "MCI_DEVELOPMENT_FILE_KEY": "1",
            "MCI_OCR_TRACE": "1",
        ]
        precondition(LiveOCRQualification.isAuthorized(
            arguments: qualificationArguments,
            environment: qualificationEnvironment
        ))
        for omittedArgument in qualificationArguments.dropFirst() {
            precondition(!LiveOCRQualification.isAuthorized(
                arguments: qualificationArguments.filter { $0 != omittedArgument },
                environment: qualificationEnvironment
            ))
        }
        for omittedVariable in qualificationEnvironment.keys {
            precondition(!LiveOCRQualification.isAuthorized(
                arguments: qualificationArguments,
                environment: qualificationEnvironment.filter { $0.key != omittedVariable }
            ))
        }

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
