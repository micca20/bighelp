import Foundation

/// The Hermes voice settings a team call honors, read from the members' own
/// `config.yaml` (`voice.*`, `tts.streaming.min_len`). Hosts differ, so every
/// value is optional on the wire and falls back to Hermes' own default.
struct TeamCallVoiceSettings: Equatable, Sendable {
    /// `voice.barge_in`: talking over a reply stops it.
    var bargeIn = true
    /// `voice.barge_in_grace_seconds`: right after a reply starts, its own
    /// sound can't count as you talking.
    var bargeInGrace: Duration = .milliseconds(500)
    /// `voice.barge_in_threshold_multiplier`: how much louder than the quiet
    /// room you have to be to cut in.
    var bargeInThresholdMultiplier: Double = 3
    /// `voice.silence_duration`: the longest pause that still waits for more.
    var silenceLimit: Duration = .seconds(3)
    /// `voice.stop_phrases`: saying exactly one of these ends the call.
    var stopPhrases: [String] = ["stop"]
    /// `tts.streaming.min_len` per profile: the shortest first sentence spoken
    /// on its own while the rest is made.
    var firstSentenceMinimum: [String: Int] = [:]

    static let defaultFirstSentenceMinimum = 20

    func firstSentenceMinimum(for profileID: String) -> Int {
        firstSentenceMinimum[profileID] ?? Self.defaultFirstSentenceMinimum
    }

    /// Call-wide `voice.*` comes from the first member whose config could be
    /// read (Hermes uses the active profile's the same way); each member keeps
    /// its own `tts.streaming.min_len`.
    static func resolve(configs: [(profileID: String, config: [String: BighelpJSONValue])]) -> Self {
        var settings = Self()
        if let voice = configs.lazy.compactMap({ $0.config["voice"]?.object }).first {
            settings.apply(voice: voice)
        }
        for (profileID, config) in configs {
            if let minimum = Self.integer(config["tts"]?.object?["streaming"]?.object?["min_len"]) {
                settings.firstSentenceMinimum[profileID] = min(max(minimum, 1), 400)
            }
        }
        return settings
    }

    private mutating func apply(voice: [String: BighelpJSONValue]) {
        if let value = voice["barge_in"]?.boolean { bargeIn = value }
        if let seconds = Self.number(voice["barge_in_grace_seconds"]) {
            bargeInGrace = .milliseconds(Int(min(max(seconds, 0), 5) * 1_000))
        }
        if let multiplier = Self.number(voice["barge_in_threshold_multiplier"]), multiplier > 0 {
            bargeInThresholdMultiplier = min(multiplier, 20)
        }
        if let seconds = Self.number(voice["silence_duration"]), seconds > 0 {
            silenceLimit = .milliseconds(Int(min(max(seconds, 0.5), 10) * 1_000))
        }
        // Hermes: a bare string is one phrase, [] turns the feature off, and a
        // malformed value keeps the default.
        switch voice["stop_phrases"] {
        case .string(let phrase):
            stopPhrases = TeamCallStopPhrase.normalizedList([phrase])
        case .array(let values):
            stopPhrases = TeamCallStopPhrase.normalizedList(values.compactMap { value in
                switch value {
                case .string(let text): text
                case .integer(let number): String(number)
                default: nil
                }
            })
        default:
            break
        }
    }

    private static func number(_ value: BighelpJSONValue?) -> Double? {
        switch value {
        case .integer(let number): Double(number)
        case .number(let number): number.isFinite ? number : nil
        default: nil
        }
    }

    private static func integer(_ value: BighelpJSONValue?) -> Int? {
        number(value).map { Int($0) }
    }
}

/// Hermes' `is_voice_stop_phrase`: the whole utterance, lowercased with its
/// surrounding punctuation stripped, must equal a phrase, so "stop doing that
/// and try again" still reaches the agents.
enum TeamCallStopPhrase {
    private static let edges = CharacterSet(charactersIn: ".,!?;: \t\n\"'")

    static func matches(_ transcript: String, phrases: [String]) -> Bool {
        let cleaned = cleaned(transcript)
        return !cleaned.isEmpty && phrases.contains(cleaned)
    }

    static func normalizedList(_ phrases: [String]) -> [String] {
        phrases.map(cleaned).filter { !$0.isEmpty }
    }

    private static func cleaned(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: edges)
    }
}

/// Cuts a finished reply so its first sentence can be spoken while the rest is
/// still being made, the way Hermes' streaming TTS does (`SentenceChunker`):
/// a sentence ends at `.`, `!` or `?` and a space, or a blank line, and an
/// opener shorter than the minimum rides with the next sentence. After the
/// first, sentences are grouped so a long reply isn't dozens of requests.
enum TeamCallSpeechSplitter {
    static let laterChunkLength = 320

    static func chunks(_ text: String, firstSentenceMinimum: Int) -> [String] {
        let sentences = self.sentences(in: text)
        guard !sentences.isEmpty else { return [] }
        let minimum = max(firstSentenceMinimum, 1)
        var result: [String] = []
        var current = ""
        for sentence in sentences {
            let joined = current.isEmpty ? sentence : current + " " + sentence
            if result.isEmpty {
                // The opener: just long enough to stand on its own.
                current = joined
                if current.count >= minimum {
                    result.append(current)
                    current = ""
                }
            } else if current.isEmpty || joined.count <= laterChunkLength {
                current = joined
            } else {
                result.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let endsSentence = "!?.".contains(character) && (next.map { $0.isWhitespace } ?? true)
            let blankLine = character == "\n" && next == "\n"
            if endsSentence || blankLine {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current = ""
            }
            index += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}
