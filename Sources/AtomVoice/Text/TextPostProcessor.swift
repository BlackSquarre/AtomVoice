import Foundation

// 文本后处理上下文：处理器据此判断是否启用、如何处理
// (Text post-processing context: processors use this to decide if/how to run)
enum TextPunctuationPolicy {
    case modelWithHeuristicFallback
    case heuristic
    case providedByRecognition

    static func forEngine(_ code: String) -> Self {
        switch code {
        case ASREngineRegistry.sherpaCode: return .modelWithHeuristicFallback
        case VolcengineASRSettings.engineCode: return .providedByRecognition
        default: return .heuristic
        }
    }
}

struct TextProcessingContext {
    let engineCode: String
    let language: String
    let isImmediateFinish: Bool
    var autoPunctuationEnabled: Bool = AppSettings.autoPunctuationEnabled
    var punctuationPolicy: TextPunctuationPolicy { .forEngine(engineCode) }
}

// 文本后处理器协议。tryProcess 返回 nil 表示"不适用，交给下一个"，非 nil 表示"由我处理"
// (Text post-processor protocol. tryProcess returns nil for "not applicable, defer to next",
//  non-nil for "handled by me")
protocol TextPostProcessor {
    var id: String { get }
    func tryProcess(_ text: String, context: TextProcessingContext) -> String?
    func processAsync(_ text: String, context: TextProcessingContext, completion: @escaping (String?) -> Void)
}

extension TextPostProcessor {
    func processAsync(_ text: String, context: TextProcessingContext, completion: @escaping (String?) -> Void) {
        completion(tryProcess(text, context: context))
    }
}

// 后处理器注册中心：按顺序遍历处理器，返回第一个非 nil 的结果；全部不适用时返回原文
// (Post-processor registry: iterate in order, return first non-nil; if all skip, return original)
final class TextPostProcessorRegistry {
    private(set) var processors: [TextPostProcessor]

    init(processors: [TextPostProcessor]) {
        self.processors = processors
    }

    func runAsync(_ text: String, context: TextProcessingContext, completion: @escaping (String) -> Void) {
        func next(_ index: Int) {
            guard index < processors.count else { completion(text); return }
            processors[index].processAsync(text, context: context) { result in
                if let result { completion(result) } else { next(index + 1) }
            }
        }
        next(0)
    }

    func run(_ text: String, context: TextProcessingContext) -> String {
        for processor in processors {
            if let processed = processor.tryProcess(text, context: context) {
                return processed
            }
        }
        return text
    }
}

// MARK: - 内置处理器（Built-in processors）

// Sherpa 自带标点模型：仅在 Sherpa 引擎且自动标点开启时尝试；失败时返回 nil 让下游兜底
// (Sherpa's built-in punctuation model: only attempted when engine is Sherpa and auto-punctuation
//  is enabled; returns nil on failure so downstream can take over)
final class SherpaPunctuationProcessor: TextPostProcessor {
    let id = "sherpaPunctuation"

    private let punctuator: (String) -> String?
    private let asyncPunctuator: ((String, @escaping (String?) -> Void) -> Void)?

    init(registry: ASREngineRegistry, asyncPunctuator: ((String, @escaping (String?) -> Void) -> Void)? = nil, punctuator: @escaping (String) -> String?) {
        self.asyncPunctuator = asyncPunctuator
        self.punctuator = punctuator
    }

    func tryProcess(_ text: String, context: TextProcessingContext) -> String? {
        guard context.autoPunctuationEnabled else { return nil }
        guard context.punctuationPolicy == .modelWithHeuristicFallback else { return nil }
        guard Self.supportsLanguage(context.language) else { return nil }
        return punctuator(text)
    }

    func processAsync(_ text: String, context: TextProcessingContext, completion: @escaping (String?) -> Void) {
        guard context.autoPunctuationEnabled, context.punctuationPolicy == .modelWithHeuristicFallback,
              Self.supportsLanguage(context.language) else { completion(nil); return }
        if let asyncPunctuator { asyncPunctuator(text, completion) }
        else { completion(punctuator(text)) }
    }

    private static func supportsLanguage(_ language: String) -> Bool {
        language.hasPrefix("zh") || language.hasPrefix("en")
    }
}

// 启发式标点：豆包服务端已带标点不再处理；Sherpa 在自有处理器失败后兜底；其余引擎默认走这里
// (Heuristic punctuation: skipped for Volcengine since server already adds punctuation;
//  Sherpa falls back to this if its own punctuator failed; other engines use this by default)
final class HeuristicPunctuationProcessor: TextPostProcessor {
    let id = "heuristicPunctuation"

    func tryProcess(_ text: String, context: TextProcessingContext) -> String? {
        guard context.autoPunctuationEnabled else { return nil }
        if context.punctuationPolicy == .providedByRecognition { return nil }
        return PunctuationProcessor.process(text, language: context.language)
    }
}
