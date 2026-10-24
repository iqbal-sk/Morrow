import tempfile
import unittest
from pathlib import Path

from metrics import choose_threshold, discover, evaluate, wilson


class MetricsTests(unittest.TestCase):
    def test_threshold_rejects_equal_score_unknowns(self):
        threshold = choose_threshold([{"score": .9, "correct": True}, {"score": .5, "correct": True}],
                                     [{"score": .5}])
        self.assertGreater(threshold, .5)
        self.assertLessEqual(threshold, .9)

    def test_no_calibration_means_no_claimed_acceptance_metrics(self):
        self.assertIsNone(choose_threshold([], [{"score": .2}]))

    def test_zero_observed_errors_still_has_uncertainty(self):
        low, high = wilson(0, 10)
        self.assertAlmostEqual(low, 0)
        self.assertGreater(high, .2)

    def test_test_scores_cannot_change_threshold(self):
        items = [
            {"id": "ref", "person": "A", "known": True, "split": "reference"},
            {"id": "cal", "person": "A", "known": True, "split": "calibration"},
            {"id": "neg", "person": "B", "known": False, "split": "calibration"},
            {"id": "test", "person": "B", "known": False, "split": "test"},
            {"id": "missing", "person": "A", "known": True, "split": "test"},
        ]
        values = {"cal": .9, "neg": .3, "test": .2}
        before = evaluate(items, values.keys() | {"ref"}, lambda a, b: values[a])
        values["test"] = .99
        after = evaluate(items, values.keys() | {"ref"}, lambda a, b: values[a])
        self.assertEqual(before["threshold"], after["threshold"])
        self.assertEqual(before["unknown_false_accepts"], 0)
        self.assertEqual(after["unknown_false_accepts"], 1)
        self.assertEqual(after["known_processed"], 0)
        self.assertEqual(after["correct_accept_rate"], 0)

    def test_splits_are_disjoint_stable_and_unknowns_are_never_references(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "known" / "empty-placeholder").mkdir(parents=True)
            for kind, names, count in [("known", ["A", "B"], 8), ("unknown", ["C"], 4)]:
                for name in names:
                    folder = root / kind / name
                    folder.mkdir(parents=True)
                    for i in range(count):
                        (folder / f"{i}.jpg").write_bytes(f"{kind}/{name}/{i}".encode())
            items = discover(root)
            self.assertEqual(items, discover(root))
            self.assertEqual(len({p["id"] for p in items}), len(items))
            self.assertTrue(all(p["known"] for p in items if p["split"] == "reference"))
            self.assertEqual(sum(p["split"] == "test" for p in items), 10)
            (root / "unknown" / "C" / "0.jpg").write_bytes(b"known/A/0")
            with self.assertRaisesRegex(ValueError, "Duplicate photo"):
                discover(root)


if __name__ == "__main__":
    unittest.main()
