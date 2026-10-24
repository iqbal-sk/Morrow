"""Group presence metrics, separate from face-level identity ground truth."""

import math


def prediction(scores, threshold):
    if not scores or not math.isfinite(threshold):
        raise ValueError("Finite threshold and enrolled reference scores required")
    if any(not math.isfinite(score) for score in scores.values()):
        raise ValueError("Non-finite identity score")
    ranked = sorted(scores.items(), key=lambda item: (-item[1], item[0]))
    person, score = ranked[0]
    return {"candidate": person, "score": score,
            "accepted": person if score >= threshold else None,
            "margin": score - ranked[1][1] if len(ranked) > 1 else None,
            "scores": dict(ranked)}


def presence(expected, faces):
    expected = set(expected)
    accepted = [face["accepted"] for face in faces if face.get("accepted")]
    predicted = set(accepted)
    return {"expected": sorted(expected), "predicted": sorted(predicted),
            "missing": sorted(expected - predicted), "unexpected": sorted(predicted - expected),
            "exact_presence_match": expected == predicted,
            "duplicate_assignments": sorted({p for p in accepted if accepted.count(p) > 1})}
