import Testing
@testable import Bighelp

/// A Clarify card has one "own words" field. It used to have one per question,
/// so a single answer had to be typed again for each question before Done.
struct ClarificationAnswersTests {
    private let pick = ClarificationAnswers.Question(choices: ["App Store", "TestFlight"], isMultiSelect: false,
                                                     lockedAnswer: nil, allowsCustomResponse: true)
    private let checkboxes = ClarificationAnswers.Question(choices: ["Ads", "Dinner", "Swag"], isMultiSelect: true,
                                                           lockedAnswer: nil, allowsCustomResponse: true)

    @Test func oneTypedAnswerCoversEveryQuestionWithoutAChoice() {
        #expect(ClarificationAnswers.answers(for: [pick, checkboxes], selections: [:], ownWords: " Ship after review ")
                == ["Ship after review", "Ship after review"])
    }

    @Test func aPickedChoiceKeepsItsQuestionAndTypingCoversTheRest() {
        #expect(ClarificationAnswers.answers(for: [pick, checkboxes], selections: [0: [1]], ownWords: "Only the ads")
                == ["TestFlight", "Only the ads"])
        #expect(ClarificationAnswers.answers(for: [pick, checkboxes], selections: [0: [0], 1: [2, 0]], ownWords: "")
                == ["App Store", #"["Ads","Swag"]"#], "Checkboxes go as a list")
    }

    @Test func doneWaitsUntilEveryQuestionHasAnAnswer() {
        #expect(ClarificationAnswers.answers(for: [pick, checkboxes], selections: [0: [0]], ownWords: "  ") == nil)
        let choicesOnly = ClarificationAnswers.Question(choices: ["Yes", "No"], isMultiSelect: false,
                                                        lockedAnswer: nil, allowsCustomResponse: false)
        #expect(ClarificationAnswers.answers(for: [choicesOnly], selections: [:], ownWords: "Maybe") == nil,
                "Typing can't answer a question that only takes its choices")
    }

    @Test func lockedAnswersStayAsTheyWere() {
        let locked = ClarificationAnswers.Question(choices: [], isMultiSelect: false, lockedAnswer: "Friday",
                                                   allowsCustomResponse: false)
        #expect(ClarificationAnswers.answers(for: [locked, pick], selections: [:], ownWords: "Later")
                == ["Friday", "Later"])
        #expect(ClarificationAnswers.acceptsOwnWords([locked]) == false)
        #expect(ClarificationAnswers.acceptsOwnWords([locked, pick]))
    }

    @Test func onlyASinglePlainQuestionSendsOnTap() {
        #expect(!ClarificationAnswers.needsDone([pick], ownWords: ""))
        #expect(ClarificationAnswers.needsDone([pick], ownWords: "typed"))
        #expect(ClarificationAnswers.needsDone([pick, pick], ownWords: ""))
        #expect(ClarificationAnswers.needsDone([checkboxes], ownWords: ""))
    }
}
