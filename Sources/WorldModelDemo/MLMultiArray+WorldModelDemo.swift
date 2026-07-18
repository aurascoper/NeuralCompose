import CoreML

/// Small local `[Float]`/`[[Float]]` <-> `MLMultiArray` bridging helpers.
/// No existing shared utility to reuse — `CoreMLIntentClassifier` and
/// `CoreMLSentenceEmbedder` each hand-roll their own inline `MLMultiArray`
/// construction, so this doesn't duplicate anything real; it's kept local
/// to this target rather than promoted to a shared location.
extension Array where Element == Float {
    func toMultiArray(shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        precondition(self.count == shape.reduce(1, *), "flat array count must match product of shape")
        for i in 0..<count {
            pointer[i] = self[i]
        }
        return array
    }
}

extension Array where Element == [Float] {
    /// Flattens a `[N][D]` batch into one `[N, D]` `MLMultiArray` in a
    /// single call — the point of this helper is exactly this: one
    /// batched CoreML call per horizon step, not N separate calls.
    func toBatchedMultiArray() throws -> MLMultiArray {
        guard let first = self.first else {
            return try MLMultiArray(shape: [0], dataType: .float32)
        }
        let n = count
        let d = first.count
        let array = try MLMultiArray(shape: [NSNumber(value: n), NSNumber(value: d)], dataType: .float32)
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for row in 0..<n {
            precondition(self[row].count == d, "all rows must share the same dimension")
            for col in 0..<d {
                pointer[row * d + col] = self[row][col]
            }
        }
        return array
    }
}

extension MLMultiArray {
    /// For a `[1, D]`-shaped output.
    func toFloatArray() -> [Float] {
        let pointer = self.dataPointer.assumingMemoryBound(to: Float.self)
        return (0..<count).map { pointer[$0] }
    }

    /// For a `[N, D]`-shaped output.
    func toBatchedFloatArrays(count rowCount: Int, dim: Int) -> [[Float]] {
        let pointer = self.dataPointer.assumingMemoryBound(to: Float.self)
        return (0..<rowCount).map { row in
            (0..<dim).map { col in pointer[row * dim + col] }
        }
    }
}
