import Foundation

// A GitHub comment body flattened to the one plain line a mention row shows,
// and the test for whether a body really @-mentions the user.
//
// The excerpt drops what isn't the commenter's own prose (PR-template HTML
// comments, fenced code, quoted replies, images), keeps link text, renders
// inline markdown to plain text and turns :shortcodes: into emoji.
enum CommentExcerpt {
    static let maxLength = 140

    static func make(_ body: String) -> String {
        var text = Rewrite.apply(leading, to: unixNewlines(body))
        text = withoutQuotedReplies(text)
        text = Rewrite.apply(markup, to: text)
        text = plainInline(text)
        text = Emoji.expand(text)
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength - 1)) + "…"
    }

    /// True when `body` mentions `@login` (case-insensitive, whole handle)
    /// outside quoted replies and code — where GitHub doesn't notify.
    static func mentions(_ body: String, login: String) -> Bool {
        guard !login.isEmpty else { return false }
        let prose = withoutQuotedReplies(Rewrite.apply(code, to: unixNewlines(body)))
        let handle = NSRegularExpression.escapedPattern(for: login)
        guard let pattern = try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9_-])@\(handle)(?![A-Za-z0-9-])", options: [.caseInsensitive]
        ) else { return prose.localizedCaseInsensitiveContains("@\(login)") }
        return pattern.firstMatch(in: prose, range: NSRange(prose.startIndex..., in: prose)) != nil
    }

    // MARK: Steps

    /// Run before quoted replies go, so a `>` inside code or a template
    /// comment can't eat a line of prose.
    private static let leading = [
        Rewrite(#"(?s)<!--.*?-->"#, ""),
        Rewrite(#"(?s)```.*?(?:```|$)"#, "\n[code]\n"),       // an unclosed fence runs to the end
    ]

    /// Images go; other tags go but keep their text; links keep their text.
    private static let markup = [
        Rewrite(#"!\[[^\]]*\]\([^)]*\)"#, ""),
        Rewrite(#"(?i)<img\b[^>]*>"#, ""),
        Rewrite(#"(?i)<br\s*/?>"#, " "),
        Rewrite(#"</?[a-zA-Z][^>]*>"#, ""),
        Rewrite(#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
    ]

    /// Fenced and inline code, removed outright (a handle there isn't a mention).
    private static let code = [
        Rewrite(#"(?s)```.*?(?:```|$)"#, ""),
        Rewrite(#"`[^`\n]*`"#, ""),
    ]

    private static func unixNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// "> earlier comment" lines are someone else's words.
    private static func withoutQuotedReplies(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in line.first(where: { !$0.isWhitespace }) != ">" }
            .joined(separator: "\n")
    }

    /// **bold**, `code`, _em_ … → their text, via Foundation's markdown parser.
    private static func plainInline(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return text }
        return String(parsed.characters)
    }
}

/// One regex substitution, compiled once.
private struct Rewrite {
    let regex: NSRegularExpression?
    let template: String

    init(_ pattern: String, _ template: String) {
        regex = try? NSRegularExpression(pattern: pattern)
        self.template = template
    }

    static func apply(_ rewrites: [Rewrite], to text: String) -> String {
        rewrites.reduce(text) { text, rewrite in
            guard let regex = rewrite.regex else { return text }
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rewrite.template
            )
        }
    }
}

// MARK: - :shortcode: → emoji

/// The shortcodes people actually type in review threads, by GitHub's
/// (gemoji) names. Unknown codes are left as typed.
private enum Emoji {
    static let byName: [String: String] = [
        "+1": "👍", "-1": "👎", "100": "💯",
        "arrow_right": "➡️", "art": "🎨",
        "bell": "🔔", "books": "📚", "boom": "💥", "bug": "🐛", "bulb": "💡",
        "checkered_flag": "🏁", "clap": "👏", "coffee": "☕", "confused": "😕",
        "construction": "🚧", "crossed_fingers": "🤞", "cry": "😢",
        "exclamation": "❗", "eyes": "👀",
        "facepalm": "🤦", "fire": "🔥",
        "gear": "⚙️", "grimacing": "😬", "grin": "😁", "grinning": "😀",
        "hammer": "🔨", "hammer_and_wrench": "🛠️", "heart": "❤️", "heart_eyes": "😍",
        "heavy_check_mark": "✔️", "heavy_minus_sign": "➖", "heavy_plus_sign": "➕",
        "hourglass": "⌛", "hourglass_flowing_sand": "⏳", "hugs": "🤗",
        "joy": "😂",
        "key": "🔑",
        "laughing": "😆", "link": "🔗", "lipstick": "💄", "lock": "🔒",
        "mag": "🔍", "memo": "📝", "muscle": "💪",
        "nerd_face": "🤓", "no_entry": "⛔", "no_entry_sign": "🚫",
        "ok_hand": "👌",
        "package": "📦", "partying_face": "🥳", "pencil": "📝", "pencil2": "✏️",
        "point_down": "👇", "point_right": "👉", "point_up": "☝️", "pray": "🙏", "pushpin": "📌",
        "question": "❓",
        "raised_hands": "🙌", "recycle": "♻️", "robot": "🤖", "rocket": "🚀",
        "rofl": "🤣", "rotating_light": "🚨",
        "see_no_evil": "🙈", "ship": "🚢", "shrug": "🤷", "skull": "💀",
        "slightly_smiling_face": "🙂", "smile": "😄", "smiley": "😃", "sob": "😭",
        "sparkles": "✨", "speech_balloon": "💬", "star": "⭐", "sunglasses": "😎",
        "sweat_smile": "😅",
        "tada": "🎉", "test_tube": "🧪", "thinking": "🤔", "thumbsdown": "👎",
        "thumbsup": "👍", "trophy": "🏆", "truck": "🚚",
        "unlock": "🔓", "upside_down_face": "🙃",
        "v": "✌️",
        "warning": "⚠️", "wave": "👋", "white_check_mark": "✅", "wink": "😉", "wrench": "🔧",
        "x": "❌",
        "zap": "⚡",
    ]

    private static let shortcode = try? NSRegularExpression(pattern: #":([A-Za-z0-9_+-]+):"#)

    /// Replaces matches back to front, so earlier ranges stay valid.
    static func expand(_ text: String) -> String {
        guard let shortcode else { return text }
        let result = NSMutableString(string: text)
        let matches = shortcode.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let name = result.substring(with: match.range(at: 1)).lowercased()
            if let emoji = byName[name] { result.replaceCharacters(in: match.range, with: emoji) }
        }
        return result as String
    }
}
