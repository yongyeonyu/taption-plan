import CoreML
import Foundation
import TaptionWatchSync

/// Optional Create ML/Core ML bridge. The app works without a bundled model;
/// when `WatchActivityClassifier.mlmodelc` is present, its prediction wins
/// over the conservative rule fallback for the same sensor window.
@MainActor
public final class WatchBehaviorModel {
    private let model: MLModel
    public let modelVersion: String

    private init(model: MLModel, modelVersion: String) {
        self.model = model
        self.modelVersion = modelVersion
    }

    public static func load(
        bundle: Bundle = .main,
        resource: String = "WatchActivityClassifier"
    ) -> WatchBehaviorModel? {
        guard let url = bundle.url(
            forResource: resource,
            withExtension: "mlmodelc"
        ), let model = try? MLModel(contentsOf: url) else {
            return nil
        }
        return WatchBehaviorModel(
            model: model,
            modelVersion: "core-ml-\(resource)"
        )
    }

    public func predict(
        features: WatchBehaviorWindowFeatures
    ) -> WatchBehaviorInference? {
        guard let input = model.modelDescription.inputDescriptionsByName
            .first(where: { $0.value.type == .multiArray }),
            let array = try? MLMultiArray(
                shape: [NSNumber(value: features.featureVector.count)],
                dataType: .double
            ) else {
            return nil
        }
        for (index, value) in features.featureVector.enumerated() {
            array[index] = NSNumber(value: value)
        }
        guard let provider = try? MLDictionaryFeatureProvider(
            dictionary: [
                input.key: MLFeatureValue(multiArray: array),
            ]
        ), let output = try? model.prediction(from: provider) else {
            return nil
        }

        let label = output.featureValue(for: "classLabel")?.stringValue
            ?? output.featureValue(for: "label")?.stringValue
        let probabilities = output.featureValue(
            for: "classLabelProbs"
        )?.dictionaryValue.reduce(into: [String: Double]()) { result, item in
            result[String(describing: item.key)] = item.value.doubleValue
        }
        let best = probabilities?.max { $0.value < $1.value }
        let rawLabel = label ?? best?.key
        guard let rawLabel,
              let kind = WatchBehaviorKind.fromModelLabel(rawLabel) else {
            return nil
        }
        return WatchBehaviorInference(
            kind: kind,
            confidenceScore: min(0.99, max(0, best?.value ?? 0.7)),
            evidence: [
                "Core ML 활동 모델",
                "IMU 창 \(WatchBehaviorWindowFeatures.featureSchemaVersion)",
            ],
            modelVersion: modelVersion
        )
    }
}
