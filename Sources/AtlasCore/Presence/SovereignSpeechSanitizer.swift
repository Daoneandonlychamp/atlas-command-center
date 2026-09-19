import Foundation

public struct SovereignSpeechSanitizer {
    public init() {}

    /// Sanitizes raw Markdown and technical response text for natural speech synthesis.
    public static func sanitize(_ text: String) -> String {
        var result = text

        // 1. Remove fenced code blocks (```...```)
        let codeBlockRegex = try? NSRegularExpression(pattern: "```[\\s\\S]*?```", options: [])
        result = codeBlockRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "") ?? result

        // 2. Remove inline code (`...`)
        let inlineCodeRegex = try? NSRegularExpression(pattern: "`([^`]+)`", options: [])
        result = inlineCodeRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1") ?? result

        // 3. Replace Markdown links [text](url) with just text
        let mdLinkRegex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^\\)]+\\)", options: [])
        result = mdLinkRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1") ?? result

        // 4. Remove bare HTTP/HTTPS URLs
        let urlRegex = try? NSRegularExpression(pattern: "https?://\\S+", options: [])
        result = urlRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "") ?? result

        // 5. Remove bold/italic markdown formatting (*, **, _, __, ~~)
        let fmtRegex = try? NSRegularExpression(pattern: "(\\*\\*|\\*|__|~{2})", options: [])
        result = fmtRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "") ?? result

        // 6. Remove Markdown header prefixes (# , ## , etc.)
        let headerRegex = try? NSRegularExpression(pattern: "(?m)^#{1,6}\\s+", options: [])
        result = headerRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "") ?? result

        // 7. Replace bullet points (* , - , • ) with clean spacing
        let bulletRegex = try? NSRegularExpression(pattern: "(?m)^[\\*\\-\\•]\\s+", options: [])
        result = bulletRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "") ?? result

        // 8. Normalize spoken abbreviations and acronyms
        result = result.replacingOccurrences(of: "ATLAS", with: "Atlas")
        result = result.replacingOccurrences(of: "e.g.", with: "for example")
        result = result.replacingOccurrences(of: "i.e.", with: "that is")
        result = result.replacingOccurrences(of: "vs.", with: "versus")
        result = result.replacingOccurrences(of: "v0.", with: "version zero point ")

        // 9. Collapse multiple spaces and newlines
        let spaceRegex = try? NSRegularExpression(pattern: "\\s+", options: [])
        result = spaceRegex?.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: " ") ?? result

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into bounded sentence-level chunks without cutting words in half.
    ///
    /// Chunk size sets how long you wait before hearing anything, because playback
    /// starts the moment chunk 0 lands and the rest synthesizes underneath it.
    /// Measured on the morning brief, same text, three runs each:
    ///
    ///     30 words -> 7.9s / 14.4s / 26.0s to first audio
    ///     12 words -> ~2.1s, and tightly clustered
    ///
    /// Long chunks are slower *and* far less predictable — they give the sampler
    /// room to ramble toward the token cap. Below ~8 words the per-request
    /// overhead pushes synthesis past real time and playback starts gapping
    /// between chunks, so 12 is the floor with margin.
    public static func chunk(_ text: String, maxWordsPerChunk: Int = 12) -> [String] {
        let sanitized = sanitize(text)
        guard !sanitized.isEmpty else { return [] }

        // Split into sentences using natural sentence boundaries
        var sentences: [String] = []
        var currentSentence = ""

        for char in sanitized {
            currentSentence.append(char)
            if char == "." || char == "!" || char == "?" || char == "\n" {
                let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                currentSentence = ""
            }
        }
        let remaining = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        if sentences.isEmpty {
            return [sanitized]
        }

        // Group sentences into bounded chunks up to maxWordsPerChunk
        var chunks: [String] = []
        var currentChunkSentences: [String] = []
        var currentChunkWordCount = 0

        for sentence in sentences {
            let wordsInSentence = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

            if currentChunkWordCount + wordsInSentence > maxWordsPerChunk && !currentChunkSentences.isEmpty {
                chunks.append(currentChunkSentences.joined(separator: " "))
                currentChunkSentences = [sentence]
                currentChunkWordCount = wordsInSentence
            } else {
                currentChunkSentences.append(sentence)
                currentChunkWordCount += wordsInSentence
            }
        }

        if !currentChunkSentences.isEmpty {
            chunks.append(currentChunkSentences.joined(separator: " "))
        }

        return chunks.isEmpty ? [sanitized] : chunks
    }
}
