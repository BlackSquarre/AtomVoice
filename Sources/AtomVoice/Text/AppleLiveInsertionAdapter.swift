import Foundation

struct AppleLiveSegmentDecision: Equatable {
    let segment: String
    let updatedCommittedText: String
}

final class AppleLiveInsertionAdapter {
    func nextCommitDecision(
        latestPartial: String,
        committedText: String,
        isFinal: Bool
    ) -> AppleLiveSegmentDecision? {
        guard latestPartial.hasPrefix(committedText) else { return nil }
        let uncommittedStart = latestPartial.index(latestPartial.startIndex, offsetBy: committedText.count)
        guard isSafeASCIIBoundary(in: latestPartial, at: uncommittedStart) else { return nil }

        let uncommitted = String(latestPartial.dropFirst(committedText.count))
        guard let endIndex = committableLiveSegmentEnd(in: uncommitted, isFinal: isFinal) else { return nil }

        let segment = String(uncommitted[..<endIndex])
        guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return AppleLiveSegmentDecision(
            segment: segment,
            updatedCommittedText: committedText + segment
        )
    }

    private func committableLiveSegmentEnd(in text: String, isFinal: Bool) -> String.Index? {
        var sentenceEnds: [String.Index] = []
        var index = text.startIndex

        while index < text.endIndex {
            let next = text.index(after: index)
            if PunctuationProcessor.isSentenceEndingPunctuation(text[index]) {
                var end = next
                while end < text.endIndex, text[end].isWhitespace {
                    end = text.index(after: end)
                }
                sentenceEnds.append(end)
            }
            index = next
        }

        for end in sentenceEnds.reversed() {
            let candidate = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            let trailing = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 3, isFinal || trailing.count >= 3 {
                return end
            }
        }

        return nil
    }

    private func isSafeASCIIBoundary(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex, index < text.endIndex else { return true }
        let previous = text[text.index(before: index)]
        let next = text[index]
        guard previous.isASCII,
              next.isASCII,
              (previous.isLetter || previous.isNumber),
              (next.isLetter || next.isNumber) else {
            return true
        }
        return false
    }
}
