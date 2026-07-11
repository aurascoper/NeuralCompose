import Foundation

/// Canonical command vocabulary for NeuralCompose. Every recognizer
/// (stub today, speech/embedding/LLM in future iterations) and the
/// debug palette consume this list. Adding a new command means
/// adding a case to `AppCommand` and an entry here — recognizers
/// and the palette pick it up automatically.
///
/// Aliases are exhaustive of natural variations: short forms
/// (`"reset"`, `"speak"`, `"calibrate"`), long forms
/// (`"open the phase b debug window"`, `"begin sleep protocol"`),
/// and a handful of synonyms (`"clear"` for reset, `"say"` for
/// speak, `"end recording"` for stop recording).
public enum DefaultCommandDescriptors {
    public static let all: [CommandDescriptor] = [
        CommandDescriptor(
            command: .openPhaseBDebug,
            title: "Open Phase B Debug",
            aliases: [
                "open phase b",
                "open the phase b debug window",
                "open phase b debug",
            ]
        ),
        CommandDescriptor(
            command: .startRecording,
            title: "Start Recording",
            aliases: [
                "start recording",
                "begin recording",
            ]
        ),
        CommandDescriptor(
            command: .stopRecording,
            title: "Stop Recording",
            aliases: [
                "stop recording",
                "end recording",
            ]
        ),
        CommandDescriptor(
            command: .beginCalibration,
            title: "Begin Calibration",
            aliases: [
                "begin calibration",
                "start calibration",
                "calibrate",
            ]
        ),
        CommandDescriptor(
            command: .beginSleepProtocol,
            title: "Begin Sleep Protocol",
            aliases: [
                "begin sleep protocol",
                "start sleep protocol",
                "run sleep protocol",
                "begin sleep",
                "start sleep",
            ]
        ),
        CommandDescriptor(
            command: .resetComposition,
            title: "Reset Composition",
            aliases: [
                "reset composition",
                "reset",
                "clear composition",
                "clear",
            ]
        ),
        CommandDescriptor(
            command: .speak,
            title: "Speak",
            aliases: [
                "speak",
                "read it",
                "read aloud",
                "say it",
                "say",
            ]
        ),
        CommandDescriptor(
            command: .refine,
            title: "Refine",
            aliases: [
                "refine",
                "refine it",
                "improve it",
                "improve",
            ]
        ),
        CommandDescriptor(
            command: .startDictation,
            title: "Start Dictation",
            aliases: [
                "start dictation",
                "begin dictation",
            ]
        ),
        CommandDescriptor(
            command: .stopDictation,
            title: "Stop Dictation",
            aliases: [
                "stop dictation",
                "end dictation",
            ]
        ),
    ]
}
