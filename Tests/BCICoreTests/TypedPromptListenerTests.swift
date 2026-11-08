import XCTest
@testable import BCICore

/// `TypedPromptListener` is the keyboard-fed `HypnagogicListening` seam: the
/// loop pulls prompts from it exactly as it pulls transcripts from the mic.
/// These tests pin the queue semantics the app and the scripted harness rely
/// on: FIFO delivery, suspension until a submit, blank-line dropping, and a
/// `cancel()` that releases every waiter with silence.
final class TypedPromptListenerTests: XCTestCase {

    func testQueuedPromptsAreDeliveredFirstInFirstOut() async throws {
        let listener = TypedPromptListener()
        await listener.submit("first")
        await listener.submit("second")
        await listener.submit("third")
        let a = try await listener.listen(timeout: 1)
        let b = try await listener.listen(timeout: 1)
        let c = try await listener.listen(timeout: 1)
        XCTAssertEqual([a, b, c], ["first", "second", "third"])
        let remaining = await listener.pendingCount()
        XCTAssertEqual(remaining, 0)
    }

    func testListenSuspendsUntilSubmit() async throws {
        let listener = TypedPromptListener()
        let waiting = Task { try await listener.listen(timeout: 1) }
        // Give the listen call a moment to register as a waiter, then feed it.
        try await Task.sleep(nanoseconds: 20_000_000)
        await listener.submit("late prompt")
        let heard = try await waiting.value
        XCTAssertEqual(heard, "late prompt")
    }

    func testSubmittedPromptGoesStraightToTheWaiterNotTheQueue() async throws {
        let listener = TypedPromptListener()
        let waiting = Task { try await listener.listen(timeout: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await listener.submit("direct")
        _ = try await waiting.value
        let remaining = await listener.pendingCount()
        XCTAssertEqual(remaining, 0, "a prompt handed to a waiter must not also be queued")
    }

    func testWhitespaceOnlySubmissionsAreDroppedAndOthersTrimmed() async throws {
        let listener = TypedPromptListener()
        await listener.submit("   ")
        await listener.submit("\n\t")
        await listener.submit("  keep me  \n")
        let remaining = await listener.pendingCount()
        XCTAssertEqual(remaining, 1)
        let heard = try await listener.listen(timeout: 1)
        XCTAssertEqual(heard, "keep me")
    }

    func testSeedLinesAreQueuedInOrder() async throws {
        let listener = TypedPromptListener(seed: ["one", "", "two"])
        let remaining = await listener.pendingCount()
        XCTAssertEqual(remaining, 2)
        let a = try await listener.listen(timeout: 1)
        let b = try await listener.listen(timeout: 1)
        XCTAssertEqual([a, b], ["one", "two"])
    }

    func testSubmitAllPreservesOrder() async throws {
        let listener = TypedPromptListener()
        await listener.submitAll(["a", "b"])
        let a = try await listener.listen(timeout: 1)
        let b = try await listener.listen(timeout: 1)
        XCTAssertEqual([a, b], ["a", "b"])
    }

    func testCancelResumesSuspendedListenWithNil() async throws {
        let listener = TypedPromptListener()
        let waiting = Task { try await listener.listen(timeout: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        await listener.cancel()
        let heard = try await waiting.value
        XCTAssertNil(heard, "cancel() reads as silence to the loop")
    }

    func testCancelKeepsQueuedLinesForTheNextListen() async throws {
        let listener = TypedPromptListener()
        await listener.submit("survivor")
        await listener.cancel()
        let heard = try await listener.listen(timeout: 1)
        XCTAssertEqual(heard, "survivor")
    }

    func testCancellingTheAwaitingTaskReleasesTheWaiter() async throws {
        let listener = TypedPromptListener()
        let waiting = Task { try await listener.listen(timeout: 1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiting.cancel()
        let heard = try await waiting.value
        XCTAssertNil(heard)
        // A later submit must queue normally rather than resume a stale waiter.
        await listener.submit("after cancel")
        let remaining = await listener.pendingCount()
        XCTAssertEqual(remaining, 1)
    }

    func testAuthorizationIsAlwaysGrantedAndNotLive() async {
        let listener = TypedPromptListener()
        let granted = await listener.requestAuthorization()
        XCTAssertTrue(granted)
        XCTAssertFalse(listener.isLive)
    }

    // MARK: - Seed file parsing (shared with dialectic-session --seed-file)

    func testParseSeedLinesTrimsSkipsBlanksAndComments() {
        let contents = """
        # a comment line
          What is the window?

        \t# indented comment
        Say that again\t
        """
        XCTAssertEqual(
            TypedPromptListener.parseSeedLines(contents),
            ["What is the window?", "Say that again"]
        )
    }

    func testParseSeedLinesHandlesCRLFAndEmptyFile() {
        XCTAssertEqual(TypedPromptListener.parseSeedLines("one\r\ntwo\r\n"), ["one", "two"])
        XCTAssertEqual(TypedPromptListener.parseSeedLines(""), [])
        XCTAssertEqual(TypedPromptListener.parseSeedLines("\n\n#only comments\n"), [])
    }
}
