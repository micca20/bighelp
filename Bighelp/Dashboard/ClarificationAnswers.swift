import Foundation

/// How a Clarify card's answers come together. A card has one "own words"
/// field, not one per question: a picked choice answers its question, and what
/// you type answers every question you didn't pick a choice for. (With a field
/// per question, one answer had to be typed again for each question.)
enum ClarificationAnswers {
    struct Question: Equatable, Sendable {
        let choices: [String]
        let isMultiSelect: Bool
        let lockedAnswer: String?
        let allowsCustomResponse: Bool
    }

    /// One answer per question, in order, or nil until every question has one.
    static func answers(for questions: [Question], selections: [Int: Set<Int>], ownWords: String) -> [String]? {
        let typed = ownWords.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        for (index, question) in questions.enumerated() {
            if let locked = question.lockedAnswer {
                result.append(locked)
                continue
            }
            let picked = (selections[index] ?? []).sorted().compactMap { choice in
                question.choices.indices.contains(choice) ? question.choices[choice] : nil
            }
            if question.isMultiSelect, !picked.isEmpty {
                guard let data = try? JSONEncoder().encode(picked),
                      let encoded = String(data: data, encoding: .utf8) else { return nil }
                result.append(encoded)
            } else if !question.isMultiSelect, picked.count == 1 {
                result.append(picked[0])
            } else if question.allowsCustomResponse, !typed.isEmpty {
                result.append(typed)
            } else {
                return nil
            }
        }
        return result
    }

    /// The card needs an own-words field when any open question takes typed answers.
    static func acceptsOwnWords(_ questions: [Question]) -> Bool {
        questions.contains { $0.lockedAnswer == nil && $0.allowsCustomResponse }
    }

    /// One tap on a choice sends a single plain question; anything more waits for Done.
    static func needsDone(_ questions: [Question], ownWords: String) -> Bool {
        questions.count > 1
            || questions.contains(where: \.isMultiSelect)
            || questions.contains(where: \.choices.isEmpty)
            || !ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What you've picked and typed in a question pop-up but not sent yet.
struct DirectHermesPromptAnswerDraft: Equatable, Sendable {
    var ownWords: String
    var selections: [Int: Set<Int>]

    var isEmpty: Bool {
        ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selections.values.allSatisfy(\.isEmpty)
    }
}

extension DashboardClarificationQuestion {
    var answerShape: ClarificationAnswers.Question {
        .init(choices: choices, isMultiSelect: isMultiSelect, lockedAnswer: lockedAnswer,
              allowsCustomResponse: allowsCustomResponse)
    }
}

extension DirectHermesPrompt.Question {
    var answerShape: ClarificationAnswers.Question {
        .init(choices: choices, isMultiSelect: isMultiSelect, lockedAnswer: lockedAnswer,
              allowsCustomResponse: lockedAnswer == nil)
    }
}
