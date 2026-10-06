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
