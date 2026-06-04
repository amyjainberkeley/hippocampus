// V2-P5+ Phase-3 NER bake-off — Apple NLTagger(.nameType) A-B baseline.
//
// The mandatory on-device floor: Apple's built-in NaturalLanguage named-
// entity recognizer, which ships in macOS and costs MCI ZERO bundle bytes
// and zero model download. If a converted transformer cannot clearly beat
// this on screen-text F1, the transformer's footprint + bundle are not
// justified and NLTagger is the v1.0 pin.
//
// Reads the bake-off corpus (a JSON list of {id, text, ...}), runs
// NLTagger over each text, maps PersonalName -> person_name /
// OrganizationName -> organization / PlaceName -> location, and writes
// predictions in eval/ner-corpus/tools/score_ner.py's format
// ([{id, entities:[{kind, span_start, span_end}]}]) with **UTF-8 byte**
// offsets — the same offset basis the gold corpus and the neural harness
// use (String.Index ranges are converted to UTF-8 byte counts so a
// multibyte character never shifts a span).
//
// Usage:
//   swift nltagger_baseline.swift <corpus.json>      > preds.json
//   swiftc -O nltagger_baseline.swift -o nltagger && ./nltagger <corpus.json> > preds.json

import Foundation
import NaturalLanguage

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

guard CommandLine.arguments.count >= 2 else {
    die("usage: nltagger_baseline <corpus.json>  (writes predictions JSON to stdout)")
}
let corpusPath = CommandLine.arguments[1]

guard let raw = FileManager.default.contents(atPath: corpusPath) else {
    die("cannot read corpus: \(corpusPath)")
}
guard let records = (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] else {
    die("corpus is not a JSON list of objects: \(corpusPath)")
}

// NLTag -> MCI kind. We only score the three soft/open-vocab kinds the
// neural token-classifier also emits (PER/ORG/LOC); date/time are the
// regex tier's job and out of this bake-off.
func mciKind(_ tag: NLTag) -> String? {
    switch tag {
    case .personalName: return "person_name"
    case .organizationName: return "organization"
    case .placeName: return "location"
    default: return nil
    }
}

// Byte offset of a String.Index in `text`'s UTF-8 encoding.
func utf8Offset(_ text: String, _ idx: String.Index) -> Int {
    return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8) ?? text.utf8.endIndex)
}

let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

var out: [[String: Any]] = []
out.reserveCapacity(records.count)

for rec in records {
    guard let id = rec["id"] as? String, let text = rec["text"] as? String else {
        die("record missing id/text: \(rec)")
    }
    var entities: [[String: Any]] = []
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    let range = text.startIndex..<text.endIndex
    tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
        if let tag = tag, let kind = mciKind(tag) {
            let start = utf8Offset(text, tokenRange.lowerBound)
            let end = utf8Offset(text, tokenRange.upperBound)
            if end > start {
                entities.append(["kind": kind, "span_start": start, "span_end": end])
            }
        }
        return true
    }
    out.append(["id": id, "entities": entities])
}

let outData = try JSONSerialization.data(withJSONObject: out, options: [])
FileHandle.standardOutput.write(outData)
