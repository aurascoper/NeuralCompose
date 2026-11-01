import Foundation
import WorldModelDemo

// Example export entry point for a SwiftPM executable that depends on WorldModelDemo.
// Run from the repository root after adding this file to a small executable target.
let depth = Int(CommandLine.arguments.dropFirst().first ?? "3") ?? 3
let outputPath = CommandLine.arguments.dropFirst(1).first ?? "Artifacts/DoubleTreeHorizonBridge"
let output = URL(fileURLWithPath: outputPath, isDirectory: true)
let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: .pairedHorizonLinks)
try DoubleTreeHorizonBridgeExporter.write(fixture, to: output)
print("Exported depth \(depth): V=\(fixture.finalFrame.nodes.count), E=\(fixture.finalFrame.edges.count), beta0=\(fixture.finalFrame.beta0), beta1=\(fixture.finalFrame.beta1)")
print("Output: \(output.path)")
