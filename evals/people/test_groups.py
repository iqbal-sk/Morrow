import unittest

from group_metrics import prediction, presence


class GroupTests(unittest.TestCase):
    def test_prediction_uses_only_scores_and_frozen_threshold(self):
        self.assertIsNone(prediction({"A": .44, "B": .3}, .45)["accepted"])
        self.assertEqual(prediction({"A": .45, "B": .3}, .45)["accepted"], "A")
        with self.assertRaises(ValueError):
            prediction({"A": float("nan")}, .45)

    def test_missing_and_extra_people_are_separate(self):
        result = presence(["A", "B"], [{"accepted": "A"}, {"accepted": "C"}, {"accepted": None}])
        self.assertEqual(result["missing"], ["B"])
        self.assertEqual(result["unexpected"], ["C"])
        self.assertFalse(result["exact_presence_match"])

    def test_presence_agreement_does_not_claim_face_identity_accuracy(self):
        result = presence(["A", "B"], [{"accepted": "B"}, {"accepted": "A"}, {"accepted": "A"}])
        self.assertTrue(result["exact_presence_match"])
        self.assertEqual(result["duplicate_assignments"], ["A"])
        self.assertNotIn("face_accuracy", result)
