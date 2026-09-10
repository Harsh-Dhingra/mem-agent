import Foundation

/// Onboarding profiles: curated, deliberately conservative sets of process-
/// name prefixes that are safe to manage (suspend when idle). A profile is
/// only ever intersected with what has actually been OBSERVED on this
/// machine, then filtered against the protected list and the user's own
/// recent usage — the suggestion is grounded, never a blind template.
///
/// Everything here is a suggestion surface: nothing enters the manageable
/// allowlist without the user approving it in the onboarding dialog.
public enum Profiles {
    /// Media & leisure — safe under suspension for any profile (frozen music
    /// resumes exactly where it stopped; nothing here holds unsaved work).
    static let common = [
        "Spotify", "Music", "Podcasts", "TV", "Books", "News", "Stocks",
        "Weather", "Chess", "Freeform", "Photo Booth",
    ]

    /// Chat/collab helpers and dev-adjacent tools. Helper renderers
    /// (\"Slack Helper (Renderer)\") match by prefix; the main app windows
    /// stay protected by the frontmost/dwell rules anyway.
    static let developer = [
        "Slack Helper", "Discord Helper", "Microsoft Teams WebView Helper",
        "Notion Helper", "Postman", "Insomnia", "Docker Desktop", "OrbStack",
        "Simulator",
    ]

    /// Creative profile: manage the chat/dev noise, never the canvas apps.
    static let creative = [
        "Slack Helper", "Discord Helper", "Microsoft Teams WebView Helper",
    ]

    /// Everyday: media plus chat helpers.
    static let everyday = [
        "Slack Helper", "Discord Helper", "Microsoft Teams WebView Helper",
        "WhatsApp", "Telegram",
    ]

    public static let names = ["developer", "creative", "everyday"]

    static func prefixes(for profile: String) -> [String] {
        switch profile {
        case "developer": return common + developer
        case "creative": return common + creative
        case "everyday": return common + everyday
        default: return common
        }
    }

    /// Match observed process names against a profile's prefixes, dropping
    /// anything protected or that the user demonstrably lives in.
    public static func candidates(profile: String,
                                  observedNames: [String],
                                  policy: Policy,
                                  heavilyUsed: Set<String> = []) -> [String] {
        let prefixList = prefixes(for: profile)
        var out = Set<String>()
        for name in observedNames {
            guard prefixList.contains(where: { name.hasPrefix($0) }),
                  !Validator.isProtected(name: name, policy: policy),
                  !heavilyUsed.contains(name) else { continue }
            out.insert(name)
        }
        return out.sorted()
    }
}
