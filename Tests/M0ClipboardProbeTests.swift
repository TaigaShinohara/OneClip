import AppKit
import Darwin
import Foundation

/// Run independently with M0ClipboardProbe.swift; all real writes use a unique named pasteboard.
@main
struct M0ClipboardProbeTests {
    @MainActor
    static func main() {
        let tests: [(String, @MainActor () throws -> Void)] = [
            ("empty_data_preserves_destination", testEmptyData),
            ("item_failure_precedes_prepare", testItemPreparationFailure),
            ("preexisting_conflict_preserves_destination", testConflictBeforePrepare),
            ("post_prepare_conflict_skips_write", testConflictAfterPrepare),
            ("write_rejection_is_not_success", testWriteRejection),
            ("item_is_ready_before_synchronous_write", testWriteOrder),
            ("acceptance_does_not_claim_content_ownership", testRaceDuringWrite),
            ("private_pasteboard_round_trip", testPrivatePasteboardRoundTrip),
            ("private_pasteboard_conflict_preserves_newer_data", testPrivatePasteboardConflict)
        ]

        var failureCount = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS \(name)")
            } catch {
                // Fixed test identifiers only; never print data or arbitrary OS errors.
                print("FAIL \(name)")
                failureCount += 1
            }
        }
        print("M0ClipboardProbeTests: \(tests.count - failureCount)/\(tests.count) passed")
        if failureCount != 0 { exit(EXIT_FAILURE) }
    }

    private enum CheckFailure: Error { case failed }

    private static let fixturePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jY8sAAAAASUVORK5CYII="
    )!
    private static let earlierFixture = Data("OneClip M0 synthetic earlier value".utf8)
    private static let competingFixture = Data("OneClip M0 synthetic competing value".utf8)

    private static func require(_ condition: @autoclosure () -> Bool) throws {
        if !condition() { throw CheckFailure.failed }
    }

    @MainActor
    private static func write(
        _ data: Data = fixturePNG,
        to destination: FakeDestination,
        expected: Int = 7
    ) -> M0ClipboardProbe.Outcome {
        M0ClipboardProbe.writePNG(
            data,
            to: destination,
            expectedChangeCount: expected,
            itemFactory: M0ClipboardProbe.makePNGItem
        )
    }

    @MainActor
    private static func testEmptyData() throws {
        let destination = FakeDestination()
        var itemFactoryCalled = false
        let outcome = M0ClipboardProbe.writePNG(
            Data(),
            to: destination,
            expectedChangeCount: 7,
            itemFactory: { _ in itemFactoryCalled = true; return nil }
        )
        try require(outcome.code == .emptyData)
        try require(!outcome.prepared && !outcome.writeAccepted)
        try require(!itemFactoryCalled)
        try require(destination.prepareCalls == 0 && destination.writeCalls == 0)
        try require(destination.contents == earlierFixture)
    }

    @MainActor
    private static func testItemPreparationFailure() throws {
        let destination = FakeDestination()
        let outcome = M0ClipboardProbe.writePNG(
            fixturePNG,
            to: destination,
            expectedChangeCount: 7,
            itemFactory: { _ in nil }
        )
        try require(outcome.code == .itemPreparationFailed)
        try require(!outcome.prepared && !outcome.writeAccepted)
        try require(destination.prepareCalls == 0 && destination.writeCalls == 0)
        try require(destination.contents == earlierFixture)
    }

    @MainActor
    private static func testConflictBeforePrepare() throws {
        let destination = FakeDestination()
        destination.count = 9
        destination.contents = competingFixture
        let outcome = write(to: destination)
        try require(outcome.code == .conflictBeforePrepare)
        try require(outcome.expectedChangeCount == 7 && outcome.observedChangeCount == 9)
        try require(!outcome.prepared && !outcome.writeAccepted)
        try require(destination.prepareCalls == 0 && destination.writeCalls == 0)
        try require(destination.contents == competingFixture)
    }

    @MainActor
    private static func testConflictAfterPrepare() throws {
        let destination = FakeDestination()
        destination.competeAfterPrepare = true
        let outcome = write(to: destination)
        try require(outcome.code == .conflictAfterPrepare)
        try require(outcome.prepared && !outcome.writeAccepted)
        try require(outcome.preparedChangeCount == 8 && outcome.observedChangeCount == 9)
        try require(destination.prepareCalls == 1 && destination.writeCalls == 0)
        try require(destination.contents == competingFixture)
    }

    @MainActor
    private static func testWriteRejection() throws {
        let destination = FakeDestination()
        destination.acceptWrite = false
        let outcome = write(to: destination)
        try require(outcome.code == .writeRejected)
        try require(outcome.prepared && !outcome.writeAccepted)
        try require(destination.prepareCalls == 1 && destination.writeCalls == 1)
        // Preparation has already cleared the earlier value. There is deliberately no restoration.
        try require(destination.contents == nil)
    }

    @MainActor
    private static func testWriteOrder() throws {
        let destination = FakeDestination()
        let outcome = M0ClipboardProbe.writePNG(
            fixturePNG,
            to: destination,
            expectedChangeCount: 7,
            itemFactory: { data in
                destination.events.append("item")
                return M0ClipboardProbe.makePNGItem(data)
            }
        )
        try require(outcome.code == .writeAccepted && outcome.prepared && outcome.writeAccepted)
        try require(destination.events == ["item", "count", "prepare", "count", "write", "count"])
        try require(destination.preparedOptions == NSPasteboard.ContentsOptions.currentHostOnly)
        try require(destination.contents == fixturePNG)
    }

    @MainActor
    private static func testRaceDuringWrite() throws {
        let destination = FakeDestination()
        destination.competeDuringWrite = true
        let outcome = write(to: destination)
        try require(outcome.code == .writeAccepted)
        try require(outcome.preparedChangeCount == 8 && outcome.observedChangeCount == 9)
        try require(destination.contents == competingFixture)
        // The fixed result reports API acceptance, not what an application will paste later.
        try require(outcome.writeAccepted)
    }

    @MainActor
    private static func testPrivatePasteboardRoundTrip() throws {
        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let outcome = M0ClipboardProbe.writePNG(
            fixturePNG,
            to: pasteboard,
            expectedChangeCount: pasteboard.changeCount
        )
        try require(outcome.code == .writeAccepted && outcome.prepared)
        try require(pasteboard.pasteboardItems?.count == 1)
        try require(pasteboard.data(forType: .png) == fixturePNG)
    }

    @MainActor
    private static func testPrivatePasteboardConflict() throws {
        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let oldCount = pasteboard.changeCount
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let competingItem = NSPasteboardItem()
        try require(competingItem.setData(competingFixture, forType: .png))
        try require(pasteboard.writeObjects([competingItem]))

        let outcome = M0ClipboardProbe.writePNG(fixturePNG, to: pasteboard, expectedChangeCount: oldCount)
        try require(outcome.code == .conflictBeforePrepare && !outcome.prepared)
        try require(pasteboard.data(forType: .png) == competingFixture)
    }

    @MainActor
    private static func makePrivatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("local.OneClip.M0ClipboardProbeTests.\(UUID().uuidString)"))
    }

    @MainActor
    private final class FakeDestination: M0ClipboardProbeDestination {
        var count = 7
        var contents: Data? = M0ClipboardProbeTests.earlierFixture
        var prepareCalls = 0
        var writeCalls = 0
        var preparedOptions: NSPasteboard.ContentsOptions?
        var events: [String] = []
        var acceptWrite = true
        var competeAfterPrepare = false
        var competeDuringWrite = false

        var changeCount: Int {
            events.append("count")
            return count
        }

        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            events.append("prepare")
            prepareCalls += 1
            preparedOptions = options
            count += 1
            contents = nil
            let preparedCount = count
            if competeAfterPrepare {
                count += 1
                contents = M0ClipboardProbeTests.competingFixture
            }
            return preparedCount
        }

        func write(_ item: NSPasteboardItem) -> Bool {
            events.append("write")
            writeCalls += 1
            guard acceptWrite else { return false }
            contents = item.data(forType: .png)
            if competeDuringWrite {
                count += 1
                contents = M0ClipboardProbeTests.competingFixture
            }
            return true
        }
    }
}
