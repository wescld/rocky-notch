import Foundation

/// Parsed AskUserQuestion tool input: the agent pauses and offers the user
/// a set of options. Rocky renders them as tappable rows and answers the
/// permission request directly, so the terminal picker never appears.
public struct AskUserQuestionRequest: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Equatable, Sendable {
        public let text: String
        public let header: String?
        public let multiSelect: Bool
        public let options: [Option]

        public init(text: String, header: String? = nil, multiSelect: Bool = false, options: [Option]) {
            self.text = text
            self.header = header
            self.multiSelect = multiSelect
            self.options = options
        }
    }

    public let questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    /// Nil unless the input carries at least one question with options.
    public static func from(toolName: String, input: JSONValue?) -> AskUserQuestionRequest? {
        guard toolName == "AskUserQuestion",
              case .array(let rawQuestions)? = input?["questions"]
        else { return nil }
        let questions: [Question] = rawQuestions.compactMap { raw in
            guard let text = raw["question"]?.stringValue,
                  case .array(let rawOptions)? = raw["options"]
            else { return nil }
            let options = rawOptions.compactMap { option -> Option? in
                guard let label = option["label"]?.stringValue else { return nil }
                return Option(label: label, description: option["description"]?.stringValue)
            }
            guard !options.isEmpty else { return nil }
            var multiSelect = false
            if case .bool(let flag)? = raw["multiSelect"] { multiSelect = flag }
            return Question(text: text, header: raw["header"]?.stringValue, multiSelect: multiSelect, options: options)
        }
        guard !questions.isEmpty else { return nil }
        return AskUserQuestionRequest(questions: questions)
    }

    /// Builds the `updatedInput` for an allow decision: the original input
    /// plus the collected answers, keyed by question text. Multi-select
    /// answers join the chosen labels with ", ".
    public static func updatedInput(
        original: JSONValue?,
        answers: [String: [String]]
    ) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if case .object(let dict)? = original { object = dict }
        object["answers"] = .object(
            answers.mapValues { .string($0.joined(separator: ", ")) }
        )
        return .object(object)
    }
}
