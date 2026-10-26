#if DEBUG
import AppKit
import Darwin
import Foundation

/// Explicit integration-test entry point. No permission request or general pasteboard access.
@MainActor
enum M0RuntimeChecks {
    static func run() async {
        var checks: [String: Bool] = [:]
        var facts: [String: String] = [:]
        var incomplete: [String] = []
        let lab = M0LabController.shared
        do {
            let frame = CGRect(x: -1800, y: 100, width: 640, height: 360)
            let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
            let region = CGRect(x: 10, y: 20, width: 100, height: 80)
            checks["geometry_negative_origin"] = try M0RegionGeometry.sourceRect(
                fixture: frame, screen: screen, region: region
            ) == CGRect(x: 130, y: 640, width: 100, height: 80)
            do {
                _ = try M0RegionGeometry.sourceRect(fixture: frame, screen: screen,
                                                  region: CGRect(x: 630, y: 0, width: 20, height: 20))
                checks["geometry_rejects_boundary_crossing"] = false
            } catch { checks["geometry_rejects_boundary_crossing"] = true }
            var latest: M0CompositionResult?
            for count in [1, 2, 4] {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try await Task.detached {
                    try M0ImageComposer.compose(assets: M0ImageFixture.makeSamples(count: count))
                }.value
                checks["compose_\(count)"] = !result.pngData.isEmpty && result.plan.placements.count == count
                let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                facts["compose_\(count)"] = "\(result.plan.width)x\(result.plan.height),png=\(result.pngData.count),estimated_peak=\(result.plan.estimatedPeakBytes),ms=\(elapsed)"
                latest = result
            }
            if let latest {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                let accepted = M0ClipboardProbe.writePNG(latest.pngData, to: board, expectedChangeCount: board.changeCount)
                checks["private_pasteboard_write"] = accepted.writeAccepted
                // Only our named board and synthetic bytes are read.
                checks["private_pasteboard_png_roundtrip"] = board.data(forType: .png) == latest.pngData
                let count = board.changeCount
                let conflict = M0ClipboardProbe.writePNG(latest.pngData, to: board, expectedChangeCount: count - 1)
                checks["private_pasteboard_conflict_no_clear"] = !conflict.prepared && board.changeCount == count
            }
            lab.makeSyntheticComposition()
            let startedCount = lab.startedOperationCount
            lab.invalidate(hide: false)
            lab.makeSyntheticComposition()
            checks["invalidated_worker_blocks_reentry"] = lab.busy && lab.startedOperationCount == startedCount
            await lab.waitForWorkToFinish()
            checks["late_composition_invalidated"] = lab.preview == nil && !lab.busy && lab.status == "INVALIDATED"
            facts["screen_permission"] = CGPreflightScreenCaptureAccess() ? "GRANTED" : "NOT_AUTHORIZED"
            facts["protected_data"] = NSApp.isProtectedDataAvailable ? "AVAILABLE" : "UNAVAILABLE"
            if CommandLine.arguments.contains("--m0-test-hotkey") {
                let registered = lab.hotKey.register()
                checks["hotkey_registered"] = registered.code == .registered
                facts["hotkey_register"] = registered.code.rawValue
                facts["hotkey_register_status"] = registered.osStatus.map(String.init) ?? "none"
                if registered.code == .registered {
                    let duplicate = lab.hotKey.testDuplicateRegistration()
                    checks["hotkey_duplicate_rejected"] = duplicate.code == .duplicateRejected
                    facts["hotkey_duplicate_status"] = duplicate.osStatus.map(String.init) ?? "none"
                }
                let removed = lab.hotKey.unregister()
                checks["hotkey_released"] = !lab.hotKey.isRegistered && removed.code == .unregistered
            }
            if CommandLine.arguments.contains("--m0-test-capture") {
                facts["capture_assertions"] = "fixture_dimensions_markers_region_offset_update_lab_exclusion"
                if CGPreflightScreenCaptureAccess() {
                    do {
                        let window = try await lab.captureFixtureForCheck(region: nil)
                        facts["fixture_window_capture"] = "\(window.image.width)x\(window.image.height),scale=\(window.scale)"
                        checks["fixture_window_dimensions"] = window.image.width == Int(640 * window.scale) && window.image.height == Int(360 * window.scale)
                        let expected = try M0ImageFixture.make(index: 1, width: 640, height: 360)
                        checks["fixture_top_left_marker"] = try matches(window, at: CGPoint(x: 10, y: 4), expected: expected, at: CGPoint(x: 10, y: 4))
                        checks["fixture_bottom_right_marker"] = try matches(window, at: CGPoint(x: 632, y: 352), expected: expected, at: CGPoint(x: 632, y: 352))
                        let region = try await lab.captureFixtureForCheck(region: CGRect(x: 300, y: 160, width: 320, height: 180), coveredByLab: true)
                        facts["fixture_display_region_capture"] = "\(region.image.width)x\(region.image.height),scale=\(region.scale)"
                        checks["fixture_display_region_dimensions"] = region.image.width == Int(320 * region.scale) && region.image.height == Int(180 * region.scale)
                        checks["fixture_display_region_offset"] = try matches(region, at: CGPoint(x: 10, y: 10), expected: expected, at: CGPoint(x: 310, y: 170))
                            && matches(region, at: CGPoint(x: 30, y: 10), expected: expected, at: CGPoint(x: 330, y: 170))
                            && !matches(region, at: CGPoint(x: 10, y: 10), expected: expected, at: CGPoint(x: 10, y: 10))
                        checks["fixture_region_excludes_covering_lab_sample"] = try matches(region, at: CGPoint(x: 270, y: 150), expected: expected, at: CGPoint(x: 570, y: 310))
                        lab.updateFixture()
                        let updated = try await lab.captureFixtureForCheck(region: nil)
                        let expectedUpdate = try M0ImageFixture.make(index: 2, width: 640, height: 360)
                        checks["fixture_updated_content"] = try matches(updated, at: CGPoint(x: 500, y: 200), expected: expectedUpdate, at: CGPoint(x: 500, y: 200))
                            && !matches(updated, at: CGPoint(x: 500, y: 200), expected: expected, at: CGPoint(x: 500, y: 200))
                    } catch {
                        checks["fixture_capture_completed"] = false
                        facts["fixture_capture"] = M0LabController.code(error)
                    }
                } else {
                    facts["fixture_capture"] = "NOT_RUN_PERMISSION_REQUIRED"
                    incomplete.append("CAPTURE_PERMISSION_REQUIRED")
                }
            }
        } catch {
            checks["runtime_checks_completed"] = false
            facts["failure"] = M0LabController.code(error)
        }
        lab.stop()
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { facts["process_high_water_bytes"] = String(usage.ru_maxrss) }
        let failed = checks.values.contains(false)
        let passed = !failed && incomplete.isEmpty
        let output: [String: Any] = ["kind": "OneClip_M0", "passed": passed,
                                     "status": failed ? "FAILED" : (incomplete.isEmpty ? "PASSED" : "INCOMPLETE"),
                                     "incomplete": incomplete, "checks": checks, "facts": facts]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        exit(failed ? 1 : (incomplete.isEmpty ? 0 : 2))
    }

    /// Compare only fabricated fixture pixels in memory; never emit image bytes or sampled colors.
    private static func matches(_ captured: M0ImageAsset, at point: CGPoint,
                                expected: M0ImageAsset, at expectedPoint: CGPoint) throws -> Bool {
        let lhs = try pixel(captured.image, x: Int(point.x * captured.scale), y: Int(point.y * captured.scale))
        let rhs = try pixel(expected.image, x: Int(expectedPoint.x), y: Int(expectedPoint.y))
        return zip(lhs, rhs).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 12 }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw M0ProbeError.captureFailed }
        var bytes: [UInt8] = [0, 0, 0, 0]
        try bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw M0ProbeError.captureFailed
            }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
#endif
