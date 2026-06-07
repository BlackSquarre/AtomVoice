#if os(Linux)
import Glibc
#else
import Darwin
#endif
import Foundation

let expectedLocales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"]
let arguments = Set(CommandLine.arguments.dropFirst())
let strictMode = arguments.contains("--strict")

struct DynamicLocCall: Comparable {
    let path: String
    let line: Int
    let snippet: String

    static func < (lhs: DynamicLocCall, rhs: DynamicLocCall) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.line < rhs.line
    }
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

func readText(_ url: URL) throws -> String {
    if let text = try? String(contentsOf: url, encoding: .utf8) {
        return text
    }
    return try String(contentsOf: url)
}

func relativePath(_ url: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    if filePath.hasPrefix(rootPath + "/") {
        return String(filePath.dropFirst(rootPath.count + 1))
    }
    return filePath
}

func files(under directory: String, suffix: String) -> [URL] {
    let start = root.appendingPathComponent(directory, isDirectory: true)
    guard let enumerator = fileManager.enumerator(
        at: start,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var result: [URL] = []
    for case let url as URL in enumerator {
        guard url.path.hasSuffix(suffix) else { continue }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        if values?.isRegularFile == true {
            result.append(url)
        }
    }
    return result.sorted { relativePath($0) < relativePath($1) }
}

func stringsFiles() -> [URL] {
    let searchRoots = ["Resources", "Sources/AtomVoice"]
    return searchRoots
        .flatMap { files(under: $0, suffix: ".lproj/Localizable.strings") }
        .sorted { relativePath($0) < relativePath($1) }
}

// 只移除注释,保留字符串内容,避免把字符串里的 // 或 /* 误判成注释。（Remove only comments while preserving string contents, so // or /* inside strings are not misread as comments.）
func removingComments(from text: String) -> String {
    enum State {
        case normal
        case lineComment
        case blockComment(depth: Int)
        case string
        case multilineString
    }

    var result = ""
    var state = State.normal
    var index = text.startIndex
    var escaped = false

    func next(_ index: String.Index, offset: Int = 1) -> String.Index? {
        text.index(index, offsetBy: offset, limitedBy: text.endIndex)
    }

    func hasPrefix(_ prefix: String, at index: String.Index) -> Bool {
        text[index...].hasPrefix(prefix)
    }

    while index < text.endIndex {
        let char = text[index]

        switch state {
        case .normal:
            if hasPrefix("//", at: index) {
                state = .lineComment
                index = next(index) ?? text.endIndex
            } else if hasPrefix("/*", at: index) {
                state = .blockComment(depth: 1)
                index = next(index) ?? text.endIndex
            } else if hasPrefix("\"\"\"", at: index) {
                result += "\"\"\""
                state = .multilineString
                index = next(index, offset: 3) ?? text.endIndex
                continue
            } else if char == "\"" {
                result.append(char)
                state = .string
                escaped = false
            } else {
                result.append(char)
            }

        case .lineComment:
            if char == "\n" {
                result.append("\n")
                state = .normal
            }

        case .blockComment(let depth):
            if char == "\n" {
                result.append("\n")
            }
            if hasPrefix("/*", at: index) {
                state = .blockComment(depth: depth + 1)
                index = next(index) ?? text.endIndex
            } else if hasPrefix("*/", at: index) {
                if depth == 1 {
                    state = .normal
                } else {
                    state = .blockComment(depth: depth - 1)
                }
                index = next(index) ?? text.endIndex
            }

        case .string:
            result.append(char)
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                state = .normal
            }

        case .multilineString:
            if hasPrefix("\"\"\"", at: index) {
                result += "\"\"\""
                state = .normal
                index = next(index, offset: 3) ?? text.endIndex
                continue
            } else {
                result.append(char)
            }
        }

        index = next(index) ?? text.endIndex
    }

    return result
}

func matches(pattern: String, in text: String) throws -> [NSTextCheckingResult] {
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range)
}

func substring(_ text: String, range: NSRange) -> String {
    guard let swiftRange = Range(range, in: text) else { return "" }
    return String(text[swiftRange])
}

func unescapeKey(_ value: String) -> String {
    var output = ""
    var escaped = false
    for char in value {
        if escaped {
            switch char {
            case "\"": output.append("\"")
            case "\\": output.append("\\")
            default: output.append(char)
            }
            escaped = false
        } else if char == "\\" {
            escaped = true
        } else {
            output.append(char)
        }
    }
    if escaped {
        output.append("\\")
    }
    return output
}

func lineNumber(in text: String, utf16Offset: Int) -> Int {
    var offset = 0
    var line = 1
    for scalar in text.unicodeScalars {
        if offset >= utf16Offset { break }
        offset += scalar.utf16.count
        if scalar == "\n" {
            line += 1
        }
    }
    return line
}

func snippet(afterLocCallIn text: String, match: NSTextCheckingResult) -> String {
    guard let end = Range(match.range, in: text)?.upperBound else { return "loc(...)" }
    let remainder = text[end...].prefix { char in
        char != "\n" && char != ")"
    }
    let trimmed = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    return "loc(\(trimmed.prefix(80)))"
}

func isFunctionDeclaration(in text: String, match: NSTextCheckingResult) -> Bool {
    guard let lowerBound = Range(match.range, in: text)?.lowerBound else { return false }
    let prefix = String(text[..<lowerBound].suffix(16))
    return prefix.range(of: #"\bfunc\s*$"#, options: .regularExpression) != nil
}

func collectSourceKeys() throws -> (keys: Set<String>, dynamicCalls: [DynamicLocCall]) {
    let swiftFiles = files(under: "Sources/AtomVoice", suffix: ".swift")
    var keys = Set<String>()
    var dynamicCalls: [DynamicLocCall] = []

    for file in swiftFiles {
        let rawText = try readText(file)
        let text = removingComments(from: rawText)

        for match in try matches(pattern: #"\bloc\s*\(\s*"((?:\\.|[^"\\])*)""#, in: text) {
            let key = unescapeKey(substring(text, range: match.range(at: 1)))
            keys.insert(key)
        }

        for match in try matches(pattern: #"\bloc\s*\("#, in: text) {
            if isFunctionDeclaration(in: text, match: match) { continue }
            guard let end = Range(match.range, in: text)?.upperBound else { continue }
            let remainder = text[end...]
            guard let first = remainder.first(where: { !$0.isWhitespace }) else { continue }
            if first == "\"" { continue }

            dynamicCalls.append(
                DynamicLocCall(
                    path: relativePath(file),
                    line: lineNumber(in: text, utf16Offset: match.range.location),
                    snippet: snippet(afterLocCallIn: text, match: match)
                )
            )
        }
    }

    return (keys, dynamicCalls.sorted())
}

func collectLocalizedKeys() throws -> [String: Set<String>] {
    let files = stringsFiles()
    var keysByLocale: [String: Set<String>] = [:]

    for locale in expectedLocales {
        keysByLocale[locale] = []
    }

    for file in files {
        let lprojName = file.deletingLastPathComponent().lastPathComponent
        let locale = String(lprojName.dropLast(".lproj".count))
        guard expectedLocales.contains(locale) else { continue }

        let text = removingComments(from: try readText(file))
        var keys = keysByLocale[locale] ?? []
        for match in try matches(pattern: #""((?:\\.|[^"\\])*)"\s*="#, in: text) {
            let key = unescapeKey(substring(text, range: match.range(at: 1)))
            keys.insert(key)
        }
        keysByLocale[locale] = keys
    }

    return keysByLocale
}

do {
    let source = try collectSourceKeys()
    let localizedKeys = try collectLocalizedKeys()
    let localizedUnion = localizedKeys.values.reduce(into: Set<String>()) { partial, keys in
        partial.formUnion(keys)
    }

    print("Localization key lint")
    print("Mode: \(strictMode ? "strict" : "report-only")")
    print("Literal loc() keys in source: \(source.keys.count)")
    print("Dynamic loc() calls skipped: \(source.dynamicCalls.count)")

    if !source.dynamicCalls.isEmpty {
        print("")
        print("Dynamic loc() calls:")
        for call in source.dynamicCalls {
            print("- \(call.path):\(call.line) \(call.snippet)")
        }
    }

    var missingByLocale: [String: [String]] = [:]
    for locale in expectedLocales {
        let keys = localizedKeys[locale] ?? []
        let missing = source.keys.subtracting(keys).sorted()
        if !missing.isEmpty {
            missingByLocale[locale] = missing
        }
    }

    print("")
    if missingByLocale.isEmpty {
        print("Missing localized keys: none")
    } else {
        let missingCount = missingByLocale.values.reduce(0) { $0 + $1.count }
        print("Missing localized keys: \(missingCount) \(strictMode ? "errors" : "warnings")")
        for locale in expectedLocales {
            guard let missing = missingByLocale[locale] else { continue }
            print("- \(locale): \(missing.count)")
            for key in missing {
                print("  - \(key)")
            }
        }
    }

    let unusedKeys = localizedUnion.subtracting(source.keys).sorted()
    print("")
    print("Localized keys not referenced by literal loc() calls: \(unusedKeys.count) warnings")
    for key in unusedKeys {
        print("- \(key)")
    }

    if strictMode && !missingByLocale.isEmpty {
        exit(1)
    }
    exit(0)
} catch {
    fputs("Localization lint failed: \(error)\n", stderr)
    exit(2)
}
