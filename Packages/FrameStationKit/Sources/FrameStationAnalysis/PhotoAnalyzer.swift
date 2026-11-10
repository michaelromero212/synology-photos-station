import Foundation
import Vision

/// Looks at one picture and says what it saw.
///
/// Apple's Vision framework, on this device, and nothing else. This module
/// depends on nothing else in the project, least of all the networking client,
/// so nothing in it can send a photograph anywhere; `AnalysisBoundaryTests`
/// holds it to that. What happens to the answer is the caller's business. For
/// FrameStation that means sending the labels, never the picture, to the
/// family's own NAS.
///
/// No cloud model, ever, and no fallback to one: a picture Vision can't read
/// is reported as having shown nothing.
///
/// One more thing, for the few photos the NAS calls a birthday: the age
/// written in them (`readNumbers`). Whole numbers, never the writing.
@available(iOS 18.0, macOS 15.0, tvOS 18.0, *)
public struct PhotoAnalyzer: Sendable {
    /// Goes up when what this reports changes enough that every photo should
    /// be looked at again. The server asks for photos below it.
    public static let analysisVersion = 1

    /// Vision scores all 1,303 of its labels for every picture, nearly all of
    /// them at close to nothing. Below this they're noise, and no rule on the
    /// server looks lower.
    static let labelFloor: Float = 0.1
    static let maxLabels = 30

    public struct Label: Sendable, Hashable {
        public let id: String
        public let confidence: Float
    }

    public struct Observation: Sendable {
        /// Strongest first.
        public let labels: [Label]
        /// Vision's overall aesthetic score, -1 to 1. Nil where the device
        /// couldn't compute one.
        public let aesthetic: Float?
        /// Vision's own call that this is a screenshot, receipt or document.
        public let isUtility: Bool
        /// A count of people, never who they are.
        public let peopleCount: Int
        public let animalCount: Int

        /// What a picture Vision couldn't read is reported as.
        public static let nothing = Observation(
            labels: [], aesthetic: nil, isUtility: false, peopleCount: 0, animalCount: 0
        )
    }

    public init() {}

    /// Which Vision revisions answer, for the record the server keeps.
    public static var modelVersion: String {
        [
            "classify:\(ClassifyImageRequest().revision)",
            "aesthetics:\(CalculateImageAestheticsScoresRequest().revision)",
            "humans:\(DetectHumanRectanglesRequest().revision)",
            "faces:\(DetectFaceRectanglesRequest().revision)",
            "animals:\(RecognizeAnimalsRequest().revision)",
        ].joined(separator: ",")
    }

    /// Analyzes an encoded image, typically a 512-pixel JPEG thumbnail.
    ///
    /// Classification is the one answer that matters; without it this throws.
    /// The rest are extras, and a device that can't produce one still reports
    /// the labels. Each request runs on its own against the same handler,
    /// which decodes the image once.
    public func analyze(imageData: Data) async throws -> Observation {
        let handler = ImageRequestHandler(imageData)
        let classes = try await handler.perform(ClassifyImageRequest())
        let aesthetics = try? await handler.perform(CalculateImageAestheticsScoresRequest())
        let humans = (try? await handler.perform(DetectHumanRectanglesRequest())) ?? []
        let faces = (try? await handler.perform(DetectFaceRectanglesRequest())) ?? []
        let animals = (try? await handler.perform(RecognizeAnimalsRequest())) ?? []

        let labels = classes
            .filter { $0.confidence >= Self.labelFloor }
            .sorted { $0.confidence > $1.confidence }
            .prefix(Self.maxLabels)
            .map { Label(id: $0.identifier, confidence: $0.confidence) }

        return Observation(
            labels: Array(labels),
            aesthetic: aesthetics?.overallScore,
            isUtility: aesthetics?.isUtility ?? false,
            // Bodies and faces each find people the other misses: a dinner
            // table shows faces with no bodies, a soccer field bodies too small
            // for faces.
            peopleCount: max(humans.count, faces.count),
            animalCount: animals.count
        )
    }
}

// MARK: - The age written in a birthday photo

@available(iOS 18.0, macOS 15.0, tvOS 18.0, *)
extension PhotoAnalyzer {
    /// Goes up when what `readNumbers` reports changes enough that every
    /// birthday photo should be read again. Only those: the server lists the
    /// birthday photos read below it, and nothing else in the library is
    /// looked at again.
    public static let readingVersion = 1

    /// The age written in a picture: a number candle, "Happy 2nd Birthday" on
    /// the cake, a "TWO" banner or shirt. For the photos the NAS calls a
    /// birthday, read from the full-screen copy: at 512 pixels a lone "2"
    /// candle isn't read at all.
    ///
    /// Vision reads the writing here, and the writing goes no further than
    /// this function. What comes back is one whole number from 1 to 18 or
    /// none (`numbers(in:)`); the server decides whose age it is, if anyone's.
    public func readNumbers(imageData: Data) async throws -> [Int] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        let lines = try await ImageRequestHandler(imageData).perform(request)
        return Self.numbers(in: lines.compactMap { $0.topCandidates(1).first?.string })
    }

    /// The age a picture's writing says, from 1 to 18: digits ("2"),
    /// ordinals ("2nd", "second") or words ("TWO"). One number at most, and
    /// often none.
    ///
    /// A picture whose writing might not be about an age says nothing at
    /// all:
    /// - another number ("40", "0", "2026", "3:45", "$5", "#7", "twenty"), so
    ///   two candles read apart as "4" and "0" are never a 4;
    /// - two different ages, which is two candles read apart ("2" "5") or
    ///   two children's cakes;
    /// - a date ("May 12", "4th of July");
    /// - months, weeks or days ("6 months"), or a half birthday;
    /// - an anniversary.
    ///
    /// A bare "1" or "11" in digits says nothing on its own. To a text reader
    /// a plain candle looks like a 1, and two of them like 11; "1st", "ONE"
    /// and "eleven" still count. Beside another number it may be the first
    /// half of a teenager's two candles, "1" "2", so then the picture says
    /// nothing. "One" counts too, except in "no one" and "one and only".
    public static func numbers(in lines: [String]) -> [Int] {
        var found = Set<Int>()
        var bare = Set<Int>()
        for line in lines {
            let words = line.lowercased()
                .split(whereSeparator: { $0.isWhitespace || "-–—".contains($0) })
                .map { $0.trimmingCharacters(in: edges) }
                .filter { !$0.isEmpty }
            for (index, word) in words.enumerated() {
                if word.hasPrefix("anniv") || word == "half" { return [] }
                let number: Int
                switch reading(word) {
                case .nothing: continue
                case .bare(let ones):
                    bare.insert(ones)
                    continue
                case .notAnAge: return []
                case .age(let age): number = age
                }
                let before = index > 0 ? words[index - 1] : ""
                let after = index + 1 < words.count ? words[index + 1] : ""
                let twoOn = index + 2 < words.count ? words[index + 2] : ""
                // "May 12", "12 May", "July 4th", "4th of July".
                if months.contains(before) || months.contains(after)
                    || (after == "of" && months.contains(twoOn)) {
                    return []
                }
                // "6 months", "3 weeks".
                if spans.contains(after) { return [] }
                if word == "one", before == "no" || (after == "and" && twoOn == "only") { continue }
                found.insert(number)
            }
        }
        guard found.count == 1, bare.isSubset(of: found) else { return [] }
        return Array(found)
    }

    private enum Reading {
        /// Not a number: a word, or punctuation.
        case nothing
        /// A number that says nothing on its own: a bare "1" or "11".
        case bare(Int)
        /// A number that can't be an age, or might be part of a bigger one.
        case notAnAge
        case age(Int)
    }

    private static func reading(_ word: String) -> Reading {
        if word.allSatisfy(\.isLetter) {
            guard let number = numberWords[word] else { return .nothing }
            return (1...18).contains(number) ? .age(number) : .notAnAge
        }
        // Any numeral at all, "½" and "²" included, is a number of some kind.
        guard word.contains(where: \.isNumber) else { return .nothing }
        let digits = word.prefix(while: { $0.isASCII && $0.isNumber })
        let suffix = word.dropFirst(digits.count)
        guard !digits.isEmpty, digits.first != "0",
              suffix.isEmpty || ["st", "nd", "rd", "th"].contains(String(suffix)),
              let number = Int(digits), (1...18).contains(number)
        else { return .notAnAge }
        if suffix.isEmpty, digits.allSatisfy({ $0 == "1" }) { return .bare(number) }
        return .age(number)
    }

    /// Trimmed from either end of a word. Not "$", "#", "%", "+" or "/": a
    /// number wearing one of those isn't an age.
    private static let edges = CharacterSet(charactersIn: "!?.,;:'\"“”‘’()[]{}*~_…")

    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    private static let spans: Set<String> = [
        "month", "months", "mo", "mos", "week", "weeks", "wk", "wks", "day", "days",
    ]

    /// Number words, the ones that can't be an age among them, which make a
    /// picture say nothing.
    private static let numberWords: [String: Int] = [
        "zero": 0,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
        "hundredth": 100, "thousandth": 1000,
    ]
}
