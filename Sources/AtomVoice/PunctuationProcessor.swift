import Foundation

struct PunctuationProcessor {

    /// 对转录文本补全缺失的句末标点
    static func process(_ text: String, language: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let isCJK = language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")

        // 按自然断句拆分：中文按空格/换行，英文按句号等已有标点之后的位置
        let segments = splitIntoSegments(trimmed, isCJK: isCJK)
        let processed = segments.map { addPunctuation($0, isCJK: isCJK, language: language) }

        if isCJK {
            return processed.joined()
        } else {
            return processed.joined(separator: " ")
        }
    }

    // MARK: - 拆分句子

    private static func splitIntoSegments(_ text: String, isCJK: Bool) -> [String] {
        if isCJK {
            // 中日韩：语音识别通常用空格分隔句子
            // 先按已有标点断句，再按空格断句
            var segments: [String] = []
            var current = ""

            for char in text {
                current.append(char)
                if isSentenceEndingPunctuation(char) {
                    segments.append(current)
                    current = ""
                }
            }
            if !current.isEmpty {
                // 没有标点结尾的部分，再按空格拆
                let sub = current.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                segments.append(contentsOf: sub)
            }
            return segments.filter { !$0.isEmpty }
        } else {
            // 英文：按已有句末标点拆，保留标点
            var segments: [String] = []
            var current = ""

            for char in text {
                current.append(char)
                if isSentenceEndingPunctuation(char) {
                    segments.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                segments.append(current.trimmingCharacters(in: .whitespaces))
            }
            return segments.filter { !$0.isEmpty }
        }
    }

    // MARK: - 补标点

    private static func addPunctuation(_ segment: String, isCJK: Bool, language: String) -> String {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return segment }

        // 已有句末标点则不处理
        if let last = trimmed.last, isSentenceEndingPunctuation(last) {
            return trimmed
        }

        if isCJK {
            return trimmed + detectCJKPunctuation(trimmed, language: language)
        } else {
            return trimmed + detectLatinPunctuation(trimmed, language: language)
        }
    }

    // MARK: - 中日韩标点检测

    private static func detectCJKPunctuation(_ text: String, language: String) -> String {
        // 取最后几个字符分析语气
        let suffix = String(text.suffix(6))

        // --- 疑问 ---
        let zhQuestionEndings = ["吗", "呢", "吧", "么", "嘛", "啥", "谁",
                                  "哪", "几", "多少", "什么", "怎么", "怎样",
                                  "为什么", "为啥", "是不是", "对不对",
                                  "好不好", "行不行", "可以吗", "对吗",
                                  "是吗", "真的吗", "有没有", "能不能"]
        let jaQuestionEndings = ["か", "の", "かな", "かい", "だろう", "でしょう", "ですか"]
        let koQuestionEndings = ["까", "니", "나요", "가요", "습니까"]

        let questionPatterns: [String]
        switch language {
        case let l where l.hasPrefix("ja"): questionPatterns = jaQuestionEndings
        case let l where l.hasPrefix("ko"): questionPatterns = koQuestionEndings
        default: questionPatterns = zhQuestionEndings
        }

        for pattern in questionPatterns {
            if suffix.hasSuffix(pattern) {
                return language.hasPrefix("zh") ? "？" : (language.hasPrefix("ja") ? "？" : "?")
            }
        }

        // 检查是否包含疑问代词（即使不在句尾）
        let zhQuestionWords = ["什么", "怎么", "为什么", "哪里", "哪个", "几个", "多少", "谁的", "如何"]
        if language.hasPrefix("zh") {
            for word in zhQuestionWords {
                if text.contains(word) {
                    return "？"
                }
            }
        }

        // --- 感叹 ---
        let zhExclamationEndings = ["啊", "呀", "哇", "哦", "嘞", "喽", "啦",
                                     "太好了", "真棒", "太棒了", "厉害", "不错",
                                     "天哪", "我去", "卧槽", "牛逼", "绝了", "好耶"]
        let jaExclamationEndings = ["よ", "ね", "な", "ぞ", "ぜ", "わ", "さ"]
        let koExclamationEndings = ["요", "다", "네요", "군요"]

        let exclamationPatterns: [String]
        switch language {
        case let l where l.hasPrefix("ja"): exclamationPatterns = jaExclamationEndings
        case let l where l.hasPrefix("ko"): exclamationPatterns = koExclamationEndings
        default: exclamationPatterns = zhExclamationEndings
        }

        for pattern in exclamationPatterns {
            if suffix.hasSuffix(pattern) {
                return language.hasPrefix("zh") ? "！" : (language.hasPrefix("ja") ? "！" : "!")
            }
        }

        // --- 列举/未完 ---
        let continuationEndings = ["等等", "之类的", "什么的", "等"]
        if language.hasPrefix("zh") {
            for pattern in continuationEndings {
                if suffix.hasSuffix(pattern) {
                    return "……"
                }
            }
        }

        // 默认：句号
        if language.hasPrefix("zh") { return "。" }
        if language.hasPrefix("ja") { return "。" }
        if language.hasPrefix("ko") { return "." }
        return "。"
    }

    // MARK: - 拉丁语系标点检测

    private static func detectLatinPunctuation(_ text: String, language: String) -> String {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let words = lower.components(separatedBy: .whitespaces)
        let firstWord = words.first ?? ""

        // 疑问句特征词
        let questionStarters: [String]
        let tagQuestions: [String]
        let exclamationStarters: [String]
        let exclamationEnders: [String]

        switch language {
        case let l where l.hasPrefix("es"):
            // 西班牙语
            questionStarters = ["qué", "dónde", "cómo", "cuándo", "por", "quién",
                                "cuál", "cuánto", "cuánta", "cuántos", "cuántas",
                                "verdad", "no", "es", "son", "está", "están",
                                "puede", "pueden", "debe", "deben", "hay",
                                "tiene", "tienen", "será", "serán"]
            tagQuestions = ["verdad", "no", "correcto", "ok"]
            exclamationStarters = ["ay", "ojalá", "bravo", "magnífico", "increíble",
                                   "genial", "fantástico", "vaya", "dios", "caramba"]
            exclamationEnders = ["increíble", "fantástico", "magnífico", "genial",
                                 "maravilloso", "excelente", "perfecto", "por fin"]
        case let l where l.hasPrefix("fr"):
            // 法语
            questionStarters = ["où", "quand", "comment", "pourquoi", "qui", "quel",
                                "quelle", "quels", "quelles", "combien", "est-ce",
                                "est", "sont", "peut", "peuvent", "doit", "doivent",
                                "y", "a", "sera", "seront"]
            tagQuestions = ["n'est-ce pas", "non", "d'accord", "ok"]
            exclamationStarters = ["oh", "bravo", "formidable", "magnifique", "incroyable",
                                   "génial", "fantastique", "mince", "diable", "zut"]
            exclamationEnders = ["incroyable", "fantastique", "magnifique", "génial",
                                 "merveilleux", "excellent", "parfait", "enfin"]
        case let l where l.hasPrefix("de"):
            // 德语
            questionStarters = ["wo", "wie", "warum", "wann", "wer", "welcher",
                                "welche", "welches", "was", "kann", "kannst", "können",
                                "ist", "sind", "war", "wird", "werden", "hat", "haben",
                                "soll", "sollen", "möchtest", "möchten", "darf", "dürfen"]
            tagQuestions = ["nicht wahr", "richtig", "ok", "gell"]
            exclamationStarters = ["ach", "wow", "toll", "fantastisch", "unglaublich",
                                   "super", "großartig", "herrlich", "donnerwetter", "oha"]
            exclamationEnders = ["unglaublich", "fantastisch", "großartig", "wunderbar",
                                 "ausgezeichnet", "perfekt", "endlich", "super"]
        default:
            // 英语（默认）
            questionStarters = ["what", "where", "when", "who", "whom", "whose",
                                "which", "why", "how", "is", "are", "was", "were",
                                "do", "does", "did", "can", "could", "will", "would",
                                "shall", "should", "may", "might", "have", "has", "had",
                                "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't",
                                "didn't", "can't", "couldn't", "won't", "wouldn't"]
            tagQuestions = ["right", "huh", "yeah", "no", "correct", "ok", "isn't it"]
            exclamationStarters = ["wow", "oh", "amazing", "great", "awesome",
                                   "incredible", "fantastic", "holy", "damn",
                                   "god", "omg", "no way", "unbelievable"]
            exclamationEnders = ["amazing", "awesome", "great", "incredible",
                                 "fantastic", "wonderful", "excellent", "perfect",
                                 "finally", "at last"]
        }

        // 疑问句检测
        if questionStarters.contains(firstWord) {
            return "?"
        }
        for tag in tagQuestions {
            if lower.hasSuffix(tag) { return "?" }
        }

        // 感叹句检测
        for starter in exclamationStarters {
            if lower.hasPrefix(starter) { return "!" }
        }
        for ender in exclamationEnders {
            if lower.hasSuffix(ender) { return "!" }
        }

        return "."
    }

    // MARK: - 辅助

    /// 检查文本末尾是否有句末标点
    static func hasTrailingPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return isSentenceEndingPunctuation(last)
    }

    static func isSentenceEndingPunctuation(_ char: Character) -> Bool {
        let endings: Set<Character> = [
            ".", "!", "?",          // 英文
            "。", "！", "？",       // 中文全角
            "…", "⋯",              // 省略号
            "~", "～",              // 波浪号
        ]
        return endings.contains(char)
    }
}
