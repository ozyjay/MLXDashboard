import Foundation

public enum ModelMemoryEstimator {
    public static func estimatedResidentMemoryGB(
        modelID: String?,
        runtimeConfiguration: ModelRuntimeConfiguration? = nil
    ) -> Double {
        if let configured = runtimeConfiguration?.estimatedResidentMemoryGB {
            return max(0, configured)
        }
        guard let modelID, !modelID.isEmpty else { return 0.5 }

        let lowercased = modelID.lowercased()
        let parametersBillions = parameterCountBillions(in: lowercased) ?? 8
        let bits = quantizationBits(in: lowercased) ?? 8
        let weightGB = parametersBillions * Double(bits) / 8.0
        let runtimeOverhead = max(2.0, weightGB * 0.25)
        let diffusionOverhead = runtimeConfiguration?.runtime == .textDiffusion
            ? max(1.5, weightGB * 0.08)
            : 0
        return (weightGB + runtimeOverhead + diffusionOverhead).rounded(upToPlaces: 1)
    }

    private static func parameterCountBillions(in value: String) -> Double? {
        let pattern = #"(?:^|[-_])([0-9]+(?:\.[0-9]+)?)b(?:[-_]|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return Double(value[range])
    }

    private static func quantizationBits(in value: String) -> Int? {
        if value.contains("mxfp4") || value.contains("4bit") || value.contains("q4") {
            return 4
        }
        if value.contains("6bit") || value.contains("q6") {
            return 6
        }
        if value.contains("8bit") || value.contains("q8") {
            return 8
        }
        if value.contains("16bit") || value.contains("fp16") || value.contains("bf16") {
            return 16
        }
        return nil
    }
}

private extension Double {
    func rounded(upToPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
