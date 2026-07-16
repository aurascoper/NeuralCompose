import Foundation
import os

/// Single shared logger surface so every module logs into the same OSLog
/// subsystem and the user can filter in Console.app on `subsystem:com.neuralcompose`.
public enum BCILog {
    public static let subsystem = "com.neuralcompose"
    public static let eeg        = Logger(subsystem: subsystem, category: "eeg")
    public static let classifier = Logger(subsystem: subsystem, category: "classifier")
    public static let embedding  = Logger(subsystem: subsystem, category: "embedding")
    public static let predictor  = Logger(subsystem: subsystem, category: "predictor")
    public static let pipeline   = Logger(subsystem: subsystem, category: "pipeline")
    public static let ui         = Logger(subsystem: subsystem, category: "ui")
    public static let voice      = Logger(subsystem: subsystem, category: "voice")
    public static let spectral   = Logger(subsystem: subsystem, category: "spectral")
    public static let telemetry  = Logger(subsystem: subsystem, category: "telemetry")
}
