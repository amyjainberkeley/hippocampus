import Foundation

/// Caption requests kept small, and answers kept to the moments asked about.
enum CaptionInputs {
    /// At most `moments` moments, each title cut to 200 characters and each
    /// text to `textCharacters`.
    static func bounded(_ input: CaptionInput, textCharacters: Int, moments: Int = 8) -> CaptionInput {
        CaptionInput(moments: input.moments.prefix(moments).map { moment in
            var moment = moment
            moment.app = Prompts.clip(moment.app, 60)
            moment.title = Prompts.clip(moment.title, 200)
            moment.text = Prompts.clip(moment.text, textCharacters)
            return moment
        })
    }

    /// One line for each moment that was asked about (the first the model
    /// gave), cut to its first line; none for a number nobody asked about.
    static func answered(_ lines: [CaptionLine], for input: CaptionInput) -> CaptionOutput {
        let asked = Set(input.moments.map(\.n))
        var seen = Set<Int>()
        return CaptionOutput(captions: lines.compactMap { line in
            guard asked.contains(line.n), seen.insert(line.n).inserted else { return nil }
            let text = line.caption.split(whereSeparator: \.isNewline).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return text.isEmpty ? nil : CaptionLine(n: line.n, caption: text)
        })
    }
}
