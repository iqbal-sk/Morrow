import runpy
import unittest
from pathlib import Path

from metrics import evaluate

RUNNER = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts" / "people-eval.py"))


class ScoreQuery:
    def __matmul__(self, score):
        return score


class ReportTests(unittest.TestCase):
    def test_name_search_uses_test_only_and_unknown_people_are_distractors(self):
        items = [
            {"id": "ref", "person": "A", "known": True, "split": "reference", "path": "ref.jpg"},
            {"id": "unknown", "person": "A", "known": False, "split": "test", "path": "unknown.jpg"},
            {"id": "a1", "person": "A", "known": True, "split": "test", "path": "a1.jpg"},
            {"id": "a2", "person": "A", "known": True, "split": "test", "path": "a2.jpg"},
        ]
        scores = {"ref": 1.0, "unknown": .9, "a1": .8, "a2": .7}
        report = RUNNER["name_search"](items, scores, {"A": ScoreQuery()})[0]
        self.assertEqual(report["relevant_test_images"], 2)
        self.assertFalse(report["top1_correct"])
        self.assertEqual(len(report["top5"]), 3)
        self.assertAlmostEqual(report["average_precision"], (1 / 2 + 2 / 3) / 2)

    def test_report_does_not_claim_threshold_metrics_when_calibration_failed(self):
        items = [
            {"id": "a", "person": "A", "known": True, "split": "test"},
            {"id": "b", "person": "B", "known": False, "split": "test"},
        ]
        result = evaluate(items, set(), lambda a, b: 0)
        report = RUNNER["markdown_report"]({"dataset": "fixture", "end_to_end": {"test": result},
                                            "common_image_count": 0, "gemma_name_search": []})
        self.assertIn("n/a", report)
        self.assertNotIn("None", report)
        self.assertEqual(result["known_processed"], 0)
        self.assertEqual(result["missing_reference_people"], ["A"])


if __name__ == "__main__":
    unittest.main()
