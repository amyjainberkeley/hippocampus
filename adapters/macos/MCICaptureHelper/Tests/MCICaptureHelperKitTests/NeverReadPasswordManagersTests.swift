import XCTest
@testable import MCICaptureHelperKit

/// Password managers and authenticator apps are never read (priv-1), on the
/// window in front and on every other window.
///
/// Every identifier below was read in October 2026 from one of:
/// - "macOS 26.5": the app's own Info.plist on this release;
/// - "App Store": Apple's catalogue (`itunes.apple.com/lookup?bundleId=`),
///   as a Mac app, or as an iPhone and iPad app it offers on Apple silicon Macs;
/// - "Homebrew": the cask that installs the app (`formulae.brew.sh/api/cask`),
///   which names the identifier in its quit, preferences, saved-state or
///   container paths;
/// - the developer's source, where the app is built from it.
final class NeverReadPasswordManagersTests: XCTestCase {
    /// (identifier, app, where it was read)
    static let verified: [(String, String, String)] = [
        ("com.apple.Passwords", "Passwords", "macOS 26.5: /System/Applications/Passwords.app"),
        ("com.apple.Passwords.MenuBarExtra", "Passwords in the menu bar", "macOS 26.5: Passwords.app LoginItems"),
        ("com.apple.keychainaccess", "Keychain Access", "macOS 26.5: /System/Library/CoreServices/Applications"),
        ("com.1password.1password", "1Password 8", "Homebrew 1password (quit)"),
        ("2BUA8C4S2C.com.1password.browser-helper", "1Password browser helper", "Homebrew 1password"),
        ("com.1password.safari", "1Password for Safari", "App Store (Mac)"),
        ("com.agilebits.onepassword7", "1Password 7", "App Store (Mac)"),
        ("com.bitwarden.desktop", "Bitwarden", "App Store (Mac); Homebrew bitwarden"),
        ("com.bitwarden.desktop.helper", "Bitwarden helper", "Homebrew bitwarden"),
        ("com.dashlane.dashlanephonefinal", "Dashlane", "App Store (iPhone and iPad app offered on Mac)"),
        ("com.lastpass.lastpassmacdesktop", "LastPass", "Homebrew lastpass (preferences)"),
        ("com.lastpass.LastPass", "LastPass, the earlier App Store app", "Homebrew lastpass (container)"),
        ("com.lastpass.lastpassforsafari", "LastPass for Safari", "App Store (Mac)"),
        ("org.keepassxc.keepassxc", "KeePassXC", "Homebrew keepassxc (quit)"),
        ("org.keepassx.keepassxc", "KeePassXC, older builds", "Homebrew keepassxc (preferences)"),
        ("com.keepersecurity.passwordmanager", "Keeper", "Homebrew keeper-password-manager (preferences)"),
        ("com.callpod.keepermac.lite", "Keeper, App Store", "App Store (Mac)"),
        ("com.keepersecurity.safari.keeperfill", "Keeper for Safari", "App Store (Mac)"),
        ("com.nordsec.nordpass", "NordPass", "Homebrew nordpass (quit)"),
        ("com.nordpass.safari.app.password.manager", "NordPass, App Store", "App Store (Mac)"),
        ("me.proton.pass.electron", "Proton Pass", "Homebrew proton-pass (preferences)"),
        ("me.proton.pass.catalyst", "Proton Pass for Safari", "App Store (Mac)"),
        ("me.proton.authenticator", "Proton Authenticator",
         "Proton's source (WebClients applications/authenticator tauri.conf.json); App Store"),
        ("in.sinew.Enpass-Desktop", "Enpass", "App Store (Mac); Homebrew enpass"),
        ("com.SiberSystems.RoboForm", "RoboForm", "Homebrew roboform"),
        ("com.sibersystems.RoboFormMac", "RoboForm, App Store", "App Store (Mac); Homebrew roboform"),
        ("com.markmcguill.strongbox", "Strongbox", "App Store (offered on Mac)"),
        ("com.markmcguill.strongbox.mac.pro", "Strongbox Pro", "App Store (Mac)"),
        ("com.markmcguill.strongbox.graphene", "Strongbox Zero", "App Store (offered on Mac)"),
        ("com.hicknhacksoftware.MacPass", "MacPass", "Homebrew macpass (quit)"),
        ("com.outercorner.Secrets", "Secrets", "App Store (offered on Mac)"),
        ("com.outercorner.Secrets-safari", "Secrets for Safari", "App Store (Mac)"),
        ("com.keepassium.ios", "KeePassium", "App Store (offered on Mac)"),
        ("com.keepassium.ios.pro", "KeePassium Pro", "App Store (offered on Mac)"),
        ("net.zetetic.Strip.mac", "Codebook", "App Store (Mac)"),
        ("com.safeincloud.Safe-In-Cloud.OSX", "SafeInCloud", "App Store (Mac); Homebrew safeincloud-password-manager"),
        ("com.mseven.msecuremac", "mSecure", "App Store (Mac)"),
        ("pw.buttercup.desktop", "Buttercup", "Homebrew buttercup (preferences)"),
        ("net.antelle.keeweb", "KeeWeb", "Homebrew keeweb (preferences)"),
        ("com.app77.pwsafemac", "pwSafe", "App Store (Mac)"),
        ("com.zoho.vault.mac", "Zoho Vault for Safari", "App Store (Mac)"),
        ("com.bitdefender.securepass", "Bitdefender SecurePass", "App Store (offered on Mac)"),
        ("com.symantec.NortonPasswordManager.combined", "Norton Safe Web Plus, with Norton's password manager",
         "App Store (Mac)"),
        ("com.avira.passwordmanager.PWMSafari", "Avira Password Manager for Safari", "App Store (Mac)"),
        ("com.eset.passwordmanager", "ESET Password Manager", "App Store (offered on Mac)"),
        ("com.keepsolid.passwarden", "Passwarden", "App Store (offered on Mac)"),
        ("com.pcloud.pcloudPass", "pCloud Pass", "App Store (offered on Mac)"),
        ("com.synology.c2.password", "Synology C2 Password", "App Store (offered on Mac)"),
        ("net.devolutions.authenticator", "Devolutions Password Manager", "App Store (offered on Mac)"),
        ("com.lockitsolutions.Lockit", "Lockit", "App Store (offered on Mac)"),
        ("design.codeux.authpass", "AuthPass", "App Store (Mac)"),
        ("com.onekeepass", "OneKeePass", "App Store (Mac)"),
        ("com.2stable.passwords", "Password Manager by 2Stable", "App Store (offered on Mac)"),
        ("app.elpass.macos", "Elpass", "App Store (Mac); Homebrew elpass"),
        ("app.bramble.desktop", "Bramble", "Homebrew bramble (quit)"),
        ("app.rowel.desktop", "Rowel", "Homebrew rowel (caches)"),
        ("com.jumpcloud.pwm.desktop.live", "JumpCloud Password Manager", "Homebrew jumpcloud-password-manager"),
        ("org.qtpass", "QtPass", "QtPass's Info.plist (github.com/IJHack/QtPass); Homebrew qtpass"),
        ("app.padloc", "Padloc", "Padloc's manifest (github.com/padloc/padloc assets/manifest.json)"),
        ("com.ascendo.DataVaultMac", "Data Vault", "App Store (Mac)"),
        ("com.logmeonce.app", "LogMeOnce for Safari", "App Store (Mac)"),
        ("com.softwareops.myeyesonlyprouniversal", "My Eyes Only", "App Store (offered on Mac)"),
        ("com.saaspass.Password-Manager-Authenticator", "SAASPASS", "App Store (Mac)"),
        ("com.NeilSardesai.Step-Two-Mac", "Step Two", "App Store (Mac)"),
        ("maccatalyst.de.cooperrs.Authenticator", "OTP Auth", "App Store (Mac)"),
        ("com.2stable.2fa", "Authenticator App by 2Stable", "App Store (offered on Mac)"),
        ("com.zoho.iamlogin", "Zoho OneAuth", "App Store (offered on Mac)"),
        ("com.yubico.yubioath", "Yubico Authenticator", "App Store (Mac); Homebrew yubico-authenticator"),
        ("io.ente.auth.mac", "Ente Auth", "Homebrew ente-auth (container)"),
        ("com.twofas.org.browser", "2FAS Auth for Safari", "App Store (Mac)"),
        ("com.twofas.org.passbrowser", "2FAS Pass for Safari", "App Store (Mac)"),
        ("me.tij.Raivo-MacOS", "Raivo", "App Store (Mac)"),
        ("com.okta.mobile", "Okta Verify", "App Store (offered on Mac)"),
        ("com.symantec.VIP-Access", "Symantec VIP Access", "Homebrew vip-access (preferences)"),
        ("com.pingidentity.pingid.pcclient", "PingID", "Homebrew pingid (saved state)"),
        ("com.secureauth.SecureAuth-OTP", "SecureAuth Passcode", "App Store (Mac)"),
    ]

    /// System sign-in and consent windows, read from their bundles on macOS 26.5.
    static let systemSignIn = [
        "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.NetAuthAgent",
        "com.apple.security.Keychain-Circle-Notification", "com.apple.loginwindow",
    ]

    private struct Secure: SecureEventInputProbe {
        func isSecureEventInputEnabled() -> Bool { false }
    }

    private struct AX: AXSecureSubroleProbe {
        func focusedHasSecureSubrole() -> Bool? { false }
    }

    private struct Blacked: BlackedRegionProbe {
        func hasBlackedRegion() -> Bool { false }
    }

    private let cascade = SuppressionCascade(
        secureEventInput: Secure(), axSecureSubrole: AX(),
        denylist: SensitiveCaptureDenylist(entries: []), blackedRegion: Blacked(),
        browserAppBundles: BrowserPixelCapturePolicy.browserBundleIds,
        admissionPolicy: .ordinaryApplications,
        privateWindows: PrivateBrowserWindows()
    )

    func testEveryVerifiedIdentifierIsNeverReadOnEitherPath() {
        let denylist = SensitiveCaptureDenylist(entries: [])
        for (bundle, app, source) in Self.verified {
            for spelling in [bundle, bundle.lowercased(), bundle.uppercased()] {
                XCTAssertTrue(SensitiveCaptureDenylist.isNeverReadApp(spelling), "\(app) (\(spelling), \(source))")
                XCTAssertTrue(denylist.appIsDenied(bundleId: spelling), "\(app) (\(spelling))")
            }
            // The window in front: suppressed before any pixel is read.
            XCTAssertEqual(cascade.decide(context: WorkflowContext(appBundleId: bundle)),
                           .suppress(reason: .denylistSource), app)
            // Never bound to the window stream, and kept out of a display filter.
            XCTAssertNil(SCContentFilterFactory.selectFocusedWindow(
                from: [.init(windowId: 9, bundleId: bundle)], windowId: 9, denylist: Denylist(entries: [])), app)
            XCTAssertEqual(SCContentFilterFactory.excludedBundleIDs(
                runningBundleIDs: [bundle, "com.apple.TextEdit"], denylist: Denylist(entries: [])), [bundle], app)
            // Every other window, on every display: out of the pixels and never attributed.
            XCTAssertTrue(BackgroundCapturePolicy.isExcluded(bundle, from: []), app)
        }
    }

    /// No family may stand for an identifier nobody read: each one must be,
    /// or be a whole-label ancestor of, an identifier in `verified`.
    func testEveryFamilyIsBackedByAVerifiedIdentifier() {
        let read = Self.verified.map { $0.0.lowercased() }
        for family in SensitiveCaptureDenylist.passwordManagerFamilies {
            XCTAssertTrue(read.contains { $0 == family || $0.hasPrefix(family + ".") },
                          "\(family) covers no identifier in the verified list")
        }
    }

    func testTheSixAppsOfTheEarlierListAreStillCovered() {
        for bundle in ["com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7",
                       "com.agilebits.onepassword-osx", "com.bitwarden.desktop", "com.dashlane.dashlane",
                       "com.lastpass.lastpass", "com.apple.keychainaccess", "com.apple.passwords"] {
            XCTAssertTrue(SensitiveCaptureDenylist.isNeverReadApp(bundle), bundle)
        }
    }

    func testSystemSignInWindowsAreNeverRead() {
        for bundle in Self.systemSignIn {
            XCTAssertTrue(SensitiveCaptureDenylist.isNeverReadApp(bundle), bundle)
            XCTAssertEqual(cascade.decide(context: WorkflowContext(appBundleId: bundle)),
                           .suppress(reason: .denylistSource), bundle)
            XCTAssertTrue(BackgroundCapturePolicy.isExcluded(bundle, from: []), bundle)
        }
    }

    func testAFamilyCoversOnlyWholeLabelsBeneathIt() {
        for lookalike in ["com.bitwardenfan.notes", "com.apple.passwordsx", "com.apple.password", "org.keepassxcx",
                          "com.lastpassword.app", "com.agilebitsfan.app", "me.proton.passport", "com.1passwordly",
                          "com.dashlanes.app", "com.okta.mobilex", "io.ente.authority", "com", "", "."] {
            XCTAssertFalse(SensitiveCaptureDenylist.isNeverReadApp(lookalike), lookalike)
        }
    }

    func testOrdinaryAppsFromTheSameMakersAreStillRead() {
        for bundle in ["com.apple.TextEdit", "com.apple.Safari", "com.google.Chrome", "com.microsoft.VSCode",
                       "com.apple.mail", "com.tinyspeck.slackmacgap", "com.apple.Notes", "com.apple.Terminal",
                       "com.protonmail.bridge", "me.proton.mail", "ch.protonmail.drive", "com.nordvpn.macos",
                       "com.zoho.mail", "com.keepersecurity.chat.mac", "com.okta.creds.experience",
                       "com.yubico.ykman", "io.ente.frame", "ai.hippocampus.CaptureOverlapCorpus"] {
            XCTAssertFalse(SensitiveCaptureDenylist.isNeverReadApp(bundle), bundle)
            XCTAssertFalse(BackgroundCapturePolicy.isExcluded(bundle, from: []), bundle)
            XCTAssertEqual(cascade.decide(context: WorkflowContext(appBundleId: bundle)), .allow, bundle)
        }
    }

    func testFamiliesAndExactEntriesAreLowercaseDottedIdentifiers() {
        for entry in SensitiveCaptureDenylist.passwordManagerFamilies.union(SensitiveCaptureDenylist.appBundles) {
            XCTAssertEqual(entry, entry.lowercased(), entry)
            XCTAssertFalse(entry.hasPrefix(".") || entry.hasSuffix(".") || entry.contains(".."), entry)
        }
        for family in SensitiveCaptureDenylist.passwordManagerFamilies {
            XCTAssertGreaterThanOrEqual(family.split(separator: ".").count, 2, family)
        }
    }

    func testAPasswordManagerLaunchedAfterTheFilterWasBuiltMakesTheFilterStale() {
        let vault = VisibleWindow(windowId: 4, ownerPid: 77, bundleId: "me.proton.pass.electron", title: "Proton Pass",
                                  bounds: CGRect(x: 0, y: 30, width: 600, height: 400), layer: 0)
        let excluded = BackgroundCapturePolicy.excludedBundleIds(userEntries: [])
        XCTAssertTrue(BackgroundCapturePolicy.filterIsStale(windows: [vault], excludedBundleIds: excluded, filteredPids: []))
        XCTAssertFalse(BackgroundCapturePolicy.filterIsStale(windows: [vault], excludedBundleIds: excluded, filteredPids: [77]))
    }

    func testPasswordManagersWebVaultsAreNeverRead() {
        let denylist = SensitiveCaptureDenylist(entries: [])
        for url in ["https://my.1password.ca/vaults", "https://my.1password.eu/", "https://vault.bitwarden.eu/#/vault",
                    "https://vault.bitwarden.com/", "https://lastpass.eu/vault", "https://passwords.google.com/",
                    "https://pass.proton.me/", "https://keepersecurity.com/vault/", "https://www.keepersecurity.eu/vault",
                    "https://app.nordpass.com/", "https://vault.zoho.com/app", "https://vault.zoho.eu/",
                    "https://online.roboform.com/"] {
            XCTAssertTrue(denylist.urlIsDenied(url), url)
        }
        for url in ["https://proton.me/mail", "https://www.google.com/search?q=passwords", "https://www.zoho.com/mail/",
                    "https://www.roboform.com.example.org/"] {
            XCTAssertFalse(denylist.urlIsDenied(url), url)
        }
    }
}
