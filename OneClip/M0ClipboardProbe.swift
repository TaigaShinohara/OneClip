import AppKit
import Foundation

/// The small boundary used to reproduce pasteboard failures without touching the general pasteboard.
@MainActor
protocol M0ClipboardProbeDestination {
    var changeCount: Int { get }
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int
    func write(_ item: NSPasteboardItem) -> Bool
}

/// An explicit, synchronous write probe. The caller supplies a completed PNG and the destination.
/// This type neither obtains the general pasteboard nor reads or restores pasteboard contents.
@MainActor
enum M0ClipboardProbe {
    enum Code: String {
        case emptyData = "empty_data"
        case itemPreparationFailed = "item_preparation_failed"
        case conflictBeforePrepare = "conflict_before_prepare"
        case conflictAfterPrepare = "conflict_after_prepare"
        case writeRejected = "write_rejected"
        case writeAccepted = "write_accepted"
    }

    struct Outcome: Equatable {
        let code: Code
        let expectedChangeCount: Int
        let observedChangeCount: Int
        let preparedChangeCount: Int?

        var prepared: Bool { preparedChangeCount != nil }

        /// API acceptance is not proof that another app has not subsequently replaced the contents.
        var writeAccepted: Bool { code == .writeAccepted }
    }

    static func writePNG(
        _ data: Data,
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int,
        securityTrace: CaptureSecurityTrace = .disabled,
        traceMode: CaptureSecurityTrace.Mode = .none
    ) -> Outcome {
        writePNG(
            data,
            to: PasteboardDestination(pasteboard: pasteboard),
            expectedChangeCount: expectedChangeCount,
            securityTrace: securityTrace, traceMode: traceMode,
            itemFactory: makePNGItem
        )
    }

    /// The injection point is for deterministic M0 tests. It performs no asynchronous work.
    /// Creating an item and setting its PNG data must finish before the destination is prepared.
    static func writePNG(
        _ data: Data,
        to destination: any M0ClipboardProbeDestination,
        expectedChangeCount: Int,
        securityTrace: CaptureSecurityTrace = .disabled,
        traceMode: CaptureSecurityTrace.Mode = .none,
        itemFactory: @MainActor (Data) -> NSPasteboardItem?
    ) -> Outcome {
        guard !data.isEmpty else {
            return Outcome(
                code: .emptyData,
                expectedChangeCount: expectedChangeCount,
                observedChangeCount: destination.changeCount,
                preparedChangeCount: nil
            )
        }

        guard let item = itemFactory(data) else {
            return Outcome(
                code: .itemPreparationFailed,
                expectedChangeCount: expectedChangeCount,
                observedChangeCount: destination.changeCount,
                preparedChangeCount: nil
            )
        }

        let beforePrepare = destination.changeCount
        guard beforePrepare == expectedChangeCount else {
            return Outcome(
                code: .conflictBeforePrepare,
                expectedChangeCount: expectedChangeCount,
                observedChangeCount: beforePrepare,
                preparedChangeCount: nil
            )
        }

        // This clears the destination. No restoration or further user action is attempted here.
        let preparedCount = destination.prepareForNewContents(with: .currentHostOnly)
        securityTrace.record(.clipboardPrepared, mode: traceMode, phase: .writing)
        let beforeWrite = destination.changeCount
        guard beforeWrite == preparedCount else {
            return Outcome(
                code: .conflictAfterPrepare,
                expectedChangeCount: expectedChangeCount,
                observedChangeCount: beforeWrite,
                preparedChangeCount: preparedCount
            )
        }

        // Keep preparation and writing in one synchronous call. changeCount is a best-effort
        // conflict check, not an atomic compare-and-swap across different applications.
        securityTrace.record(.clipboardWrite, mode: traceMode, phase: .writing)
        let accepted = destination.write(item)
        let observedCount = destination.changeCount
        return Outcome(
            code: accepted ? .writeAccepted : .writeRejected,
            expectedChangeCount: expectedChangeCount,
            observedChangeCount: observedCount,
            preparedChangeCount: preparedCount
        )
    }

    static func makePNGItem(_ data: Data) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else { return nil }
        return item
    }

    private struct PasteboardDestination: M0ClipboardProbeDestination {
        let pasteboard: NSPasteboard

        var changeCount: Int { pasteboard.changeCount }

        func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
            pasteboard.prepareForNewContents(with: options)
        }

        func write(_ item: NSPasteboardItem) -> Bool {
            pasteboard.writeObjects([item])
        }
    }
}
