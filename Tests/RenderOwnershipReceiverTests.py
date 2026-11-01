"""TEMP pure receiver regressions. No Swift, children, image, or resource trial."""

import copy
import errno
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("render_receipt_receiver", Path(__file__).resolve().parents[1] / "scripts" / "render_ownership_receiver.py")
receiver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receiver)

SCOPE = "OC_RENDER_LIFETIME_SCOPE schema=1 classification=temporary_default_render_object_pilot maximumProcesses=1 maximumArms=4 sourceCount=2 sourceWidth=64 sourceHeight=64 expectedWidth=96 expectedHeight=224 operationDeadlineNanoseconds=2000000000 workerReturnEvidence=original_wrapper_awaited sourcePayload=fictional board=not_exercised capture=0 gui=0 backingRelease=not_observed resourceAcceptance=0"


def arm(ordinal):
    row = dict(schema=1, arm=ordinal, generation=ordinal,
               mode=("positive_control", "success", "cancel_before", "cancel_after")[ordinal - 1],
               state="ESTABLISHED", reason="none", hookCalls=1, imageObserved=1, providerObserved=1,
               hookImageAlive=1, hookProviderAlive=1, providerGetterStable=1,
               heldImageAlive=-1, heldProviderAlive=-1, heldImageIdentity=-1, heldProviderIdentity=-1,
               providerOnlyImageAlive=-1, providerOnlyProviderAlive=-1, finalImageAlive=0, finalProviderAlive=0,
               wrapperStarted=1, valueAwaited=1, wrapperReturned=1, resultReturned=1, pngBytes=1000,
               compositionEntered=1, compositionFinished=1, traceDropped=0,
               gateReached=0, gateImageAlive=-1, gateProviderAlive=-1,
               cancellationRequested=0, cancellationOutcome="not_requested", elapsedNanoseconds=5000000)
    if ordinal == 1:
        row.update(heldImageAlive=1, heldProviderAlive=1, heldImageIdentity=1, heldProviderIdentity=1,
                   providerOnlyImageAlive=0, providerOnlyProviderAlive=1)
    if ordinal > 2:
        row.update(resultReturned=0, pngBytes=0, gateReached=1, gateImageAlive=1, gateProviderAlive=1,
                   cancellationRequested=1, cancellationOutcome="cancelled")
    return row


def packet(arms=None, *, state="ESTABLISHED", reason="none", completed=4):
    arms = [arm(i) for i in range(1, 5)] if arms is None else arms
    lines = [SCOPE] + ["OC_RENDER_LIFETIME_ARM " + " ".join(f"{k}={v}" for k, v in row.items()) for row in arms]
    lines.append(f"OC_RENDER_LIFETIME_RESULT schema=1 state={state} reason={reason} completedArms={completed} maximumArms=4 backingRelease=not_observed resourceAcceptance=0")
    return ("\n".join(lines) + "\n").encode("ascii")


def metadata(data, *, exit_code=0):
    return dict(stdoutBytes=len(data), stderrBytesDiscarded=0, cleanupConfirmed=True, exit=exit_code,
                elapsedSeconds=0.3, elapsedWallSeconds=0.3, reason=None)


class EvidenceError(ValueError):
    pass


class ReceiverTests(unittest.TestCase):
    def check_unknown(self, data, **kwargs):
        result = receiver.build_report(data, metadata(data), **kwargs)
        self.assertEqual(result["objectObservation"], "NOT_ESTABLISHED")
        self.assertFalse(result["resourceAcceptance"])
        return result

    def test_four_real_proof_shapes_are_object_only(self):
        data = packet(); result = receiver.build_report(data, metadata(data))
        self.assertEqual(result["protocolStatus"], "VALID_FIXED_PROTOCOL")
        self.assertEqual(result["objectObservation"], "ESTABLISHED_OBJECT_LIFETIME_ONLY")
        self.assertEqual(len(result["rows"]["arms"]), 4)
        self.assertFalse(result["resourceAcceptance"])
        self.assertEqual(result["backingRelease"], "not_observed")
        self.assertEqual(result["resourceSummary"]["status"], "NOT_EXERCISED")

    def test_provider_only_hold_does_not_require_image_to_die(self):
        rows = [arm(i) for i in range(1, 5)]; rows[0]["providerOnlyImageAlive"] = 1
        data = packet(rows)
        self.assertEqual(receiver.build_report(data, metadata(data))["objectObservation"], "ESTABLISHED_OBJECT_LIFETIME_ONLY")

    def test_each_observer_worker_and_trace_proof_is_required(self):
        for key, value in (("hookCalls", 0), ("imageObserved", 0), ("providerObserved", 0),
                           ("hookImageAlive", -1), ("hookProviderAlive", 0), ("providerGetterStable", 0),
                           ("finalImageAlive", 1), ("finalProviderAlive", -1), ("wrapperReturned", 0),
                           ("valueAwaited", 0), ("compositionEntered", 0), ("compositionFinished", 0),
                           ("traceDropped", 1), ("elapsedNanoseconds", 2000000001)):
            with self.subTest(key=key):
                rows = [arm(i) for i in range(1, 5)]; rows[1][key] = value
                self.check_unknown(packet(rows))

    def test_cancel_cannot_adopt_png_or_skip_actual_cancel_and_gate(self):
        for key, value in (("resultReturned", 1), ("pngBytes", 1), ("cancellationRequested", 0),
                           ("cancellationOutcome", "not_requested"), ("gateReached", 0),
                           ("gateImageAlive", -1), ("gateProviderAlive", 0)):
            with self.subTest(key=key):
                rows = [arm(i) for i in range(1, 5)]; rows[2][key] = value
                self.check_unknown(packet(rows))

    def test_success_requires_real_result_and_nonzero_bounded_png(self):
        for key, value in (("resultReturned", -1), ("resultReturned", 0), ("pngBytes", -1),
                           ("pngBytes", 0), ("pngBytes", receiver.IMAGE_BUDGET + 1)):
            with self.subTest(key=key, value=value):
                rows = [arm(i) for i in range(1, 5)]; rows[1][key] = value
                self.check_unknown(packet(rows))

    def test_positive_identity_and_explicit_hold_proofs_are_required(self):
        for key in ("heldImageAlive", "heldProviderAlive", "heldImageIdentity", "heldProviderIdentity", "providerOnlyProviderAlive"):
            rows = [arm(i) for i in range(1, 5)]; rows[0][key] = 0
            self.check_unknown(packet(rows))
        rows = [arm(i) for i in range(1, 5)]; rows[1]["heldProviderAlive"] = 1
        self.check_unknown(packet(rows))

    def test_unknown_keys_enums_kinds_and_payload_do_not_escape(self):
        secret = "synthetic-unapproved-text"
        for data in (packet().replace(b"schema=1 classification=", b"unexpected=" + secret.encode() + b" schema=1 classification=", 1),
                     packet().replace(b"mode=success", b"mode=" + secret.encode()),
                     packet().replace(b"OC_RENDER_LIFETIME_ARM", b"UNAPPROVED_KIND", 1),
                     packet().replace(b"reason=none", b"reason=" + secret.encode(), 1),
                     packet() + secret.encode() + b"\n"):
            result = self.check_unknown(data)
            self.assertNotIn(secret, json.dumps(result))

    def test_duplicate_stale_order_and_noncanonical_fields_are_refused(self):
        for data in (packet().replace(b"generation=2", b"generation=1"),
                     packet().replace(b"arm=2 generation=2", b"arm=2 arm=2 generation=2"),
                     packet().replace(b"pngBytes=1000", b"pngBytes=01", 1),
                     packet().replace(b"pngBytes=1000", b"pngBytes=18446744073709551616", 1),
                     packet([arm(2), arm(1), arm(3), arm(4)])):
            self.check_unknown(data)

    def test_truncation_counts_and_fake_terminal_are_refused(self):
        for data in (packet()[:-1], packet(completed=3), packet([arm(1)], completed=1),
                     packet(state="NOT_ESTABLISHED", reason="none"), b"\n", b"x" * 65537, b"\xff\n"):
            self.check_unknown(data)

    def test_known_ne_prefix_preserves_minus_one_without_release(self):
        rows = [arm(1), arm(2)]
        rows[1].update(state="NOT_ESTABLISHED", reason="missing_hook", hookCalls=0, imageObserved=0,
                       providerObserved=0, finalImageAlive=-1, finalProviderAlive=-1, resultReturned=-1, pngBytes=-1)
        data = packet(rows, state="NOT_ESTABLISHED", reason="missing_hook", completed=1)
        result = receiver.build_report(data, metadata(data, exit_code=2))
        self.assertEqual(result["protocolStatus"], "VALID_FIXED_PROTOCOL")
        self.assertEqual(result["objectReason"], "missing_hook")
        self.assertEqual(result["rows"]["arms"][-1]["finalImageAlive"], -1)
        self.assertEqual(result["objectObservation"], "NOT_ESTABLISHED")
        self.check_unknown(packet(rows + [arm(3)], state="NOT_ESTABLISHED", reason="missing_hook", completed=1))

    def test_invalid_arguments_terminal_has_zero_arms(self):
        data = packet([], state="NOT_ESTABLISHED", reason="invalid_arguments", completed=0)
        result = receiver.build_report(data, metadata(data, exit_code=2))
        self.assertEqual(result["protocolStatus"], "VALID_FIXED_PROTOCOL")
        self.assertEqual(result["objectReason"], "invalid_arguments")

    def test_capture_qualification_is_independent_and_unknown_text_dropped(self):
        data = packet()
        for key, value in (("exit", 2), ("cleanupConfirmed", False), ("stderrBytesDiscarded", 1),
                           ("elapsedSeconds", 15.01), ("elapsedWallSeconds", 15.01),
                           ("reason", "synthetic-private-error"), ("stdoutBytes", len(data) - 1),
                           ("cleanupConfirmed", 1)):
            with self.subTest(key=key):
                meta = metadata(data); meta[key] = value
                result = receiver.build_report(data, meta)
                self.assertEqual(result["objectObservation"], "NOT_ESTABLISHED")
                self.assertNotIn("synthetic-private-error", json.dumps(result))

    def test_full_summary_failure_keeps_prior_saved_object_receipt_and_fixed_code(self):
        data = packet()
        with tempfile.TemporaryDirectory(prefix="render-receiver-") as directory:
            target = Path(directory) / "receipt.json"
            def summarize(_):
                self.assertEqual(json.loads(target.read_text())["objectObservation"], "ESTABLISHED_OBJECT_LIFETIME_ONLY")
                raise EvidenceError("heartbeat_unobserved")
            result = receiver.receive_to_file(data, metadata(data), target, summarize=summarize, evidence_error_type=EvidenceError)
            sidecar = json.loads(target.with_name("receipt.json.summary.json").read_text())
            self.assertEqual(sidecar["resourceSummary"]["reason"], "heartbeat_unobserved")
            self.assertTrue(sidecar["resourceSummary"]["recognizedEvidenceError"])
            self.assertEqual(result["objectObservation"], "ESTABLISHED_OBJECT_LIFETIME_ONLY")
            self.assertFalse(sidecar["resourceAcceptance"])

    def test_fixed_runner_failure_codes_are_preserved_exactly_without_qualification(self):
        data = packet()
        for reason in ("parent_interrupted", "clock_invalid", "launch_failed", "capture_failed", "input_changed"):
            with self.subTest(reason=reason):
                meta = metadata(data); meta["reason"] = reason
                result = receiver.build_report(data, meta)
                self.assertEqual(result["capture"]["reason"], reason)
                self.assertEqual(result["objectObservation"], "NOT_ESTABLISHED")

    def test_missing_clocks_stay_null_and_invalid_types_never_become_zero(self):
        data = packet()
        for key in ("elapsedSeconds", "elapsedWallSeconds"):
            for reason in (None, "clock_invalid"):
                meta = metadata(data); meta.update({key: None, "reason": reason})
                result = receiver.build_report(data, meta)
                self.assertIsNone(result["capture"][key])
                self.assertEqual(result["objectReason"], "capture_not_established")
                self.assertEqual(result["objectObservation"], "NOT_ESTABLISHED")
            for invalid in ("0.0", True, float("nan"), float("inf"), -1.0):
                meta = metadata(data); meta[key] = invalid
                result = receiver.build_report(data, meta)
                self.assertEqual(result["protocolReason"], "capture_metadata_invalid")
                self.assertEqual(result["objectObservation"], "NOT_ESTABLISHED")

    def test_unknown_summary_reason_text_and_returned_data_never_saved(self):
        data = packet(); private = "synthetic-private-summary-detail"
        def unknown(_):
            raise EvidenceError(private)
        result = receiver.build_report(data, metadata(data), summarize=unknown, evidence_error_type=EvidenceError)
        self.assertEqual(result["resourceSummary"]["reason"], "unrecognized_evidence_error")
        self.assertNotIn(private, json.dumps(result))
        result = receiver.build_report(data, metadata(data), summarize=lambda _: {private: private})
        self.assertEqual(result["resourceSummary"]["status"], "SCALAR_PARSE_ONLY")
        self.assertNotIn(private, json.dumps(result))

    def test_memory_missing_reason_stays_ne_without_zero_or_object_loss(self):
        data = packet()
        def missing(_):
            raise EvidenceError("unavailable_or_invalid_rss")
        result = receiver.build_report(data, metadata(data), summarize=missing, evidence_error_type=EvidenceError)
        self.assertEqual(result["resourceSummary"]["reason"], "unavailable_or_invalid_rss")
        self.assertEqual(result["objectObservation"], "ESTABLISHED_OBJECT_LIFETIME_ONLY")
        self.assertNotIn("rss", result["resourceSummary"])

    def test_new_receipt_is_private_and_existing_receipt_not_overwritten(self):
        data = packet()
        with tempfile.TemporaryDirectory(prefix="render-receiver-") as directory:
            path = Path(directory) / "receipt.json"
            receiver.receive_to_file(data, metadata(data), path)
            original = path.read_bytes()
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                receiver.receive_to_file(data, metadata(data), path)
            self.assertEqual(path.read_bytes(), original)

    def test_output_symlinks_and_escape_are_refused_without_touching_target(self):
        data = packet()
        with tempfile.TemporaryDirectory(prefix="render-receiver-") as directory:
            root = Path(directory).resolve(); target = root / "target"; target.write_bytes(b"synthetic-marker")
            link = root / "link"; link.symlink_to(target)
            with self.assertRaises(OSError):
                receiver.receive_to_file(data, metadata(data), link)
            real = root / "real"; real.mkdir(mode=0o700)
            alias = root / "alias"; alias.symlink_to(real, target_is_directory=True)
            with self.assertRaises(OSError):
                receiver.receive_to_file(data, metadata(data), alias / "receipt.json")
            with self.assertRaises(receiver.ReceiverError):
                receiver.receive_to_file(data, metadata(data), root / "unused" / ".." / "receipt.json")
            with self.assertRaises(receiver.ReceiverError):
                receiver.receive_to_file(data, metadata(data), root.parent.parent / "outside-render-receipt.json")
            self.assertEqual(target.read_bytes(), b"synthetic-marker")
            self.assertEqual(list(real.iterdir()), [])

    def test_short_write_and_eintr_finish_the_same_receipt(self):
        data = packet(); live_write = os.write; calls = []
        def fragmented(descriptor, value):
            calls.append(len(value))
            if len(calls) == 1:
                raise InterruptedError(errno.EINTR, "synthetic-interruption")
            return live_write(descriptor, value[:7])
        with tempfile.TemporaryDirectory(prefix="render-receiver-") as directory:
            path = Path(directory) / "receipt.json"
            with mock.patch.object(receiver.os, "write", side_effect=fragmented):
                receiver.receive_to_file(data, metadata(data), path)
            self.assertGreater(len(calls), 2)
            self.assertEqual(json.loads(path.read_text())["objectObservation"], "ESTABLISHED_OBJECT_LIFETIME_ONLY")


if __name__ == "__main__":
    unittest.main()
