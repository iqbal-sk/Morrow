"""Deterministic splits and held-out identity metrics; no model dependencies."""

import hashlib
import math
from pathlib import Path

EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tif", ".tiff", ".bmp", ".avif"}


def discover(root):
    root = Path(root).resolve()
    items = []
    seen_content = {}
    for kind in ("known", "unknown"):
        base = root / kind
        for folder in sorted(base.iterdir() if base.exists() else []):
            if not folder.is_dir():
                continue
            photos = [p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() in EXTENSIONS]
            if not photos:
                continue  # Empty scaffold folders are not identities.
            photos.sort(key=lambda p: hashlib.sha256(str(p.relative_to(root)).encode()).hexdigest())
            minimum = 6 if kind == "known" else 2
            if len(photos) < minimum:
                raise ValueError(f"{folder}: needs at least {minimum} photos; found {len(photos)}")
            for index, photo in enumerate(photos):
                digest = hashlib.sha256()
                with photo.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                fingerprint = digest.hexdigest()
                if fingerprint in seen_content:
                    raise ValueError(f"Duplicate photo files: {seen_content[fingerprint]} and {photo}. Keep only one copy.")
                seen_content[fingerprint] = photo
                split = ("reference" if index < 2 else "calibration" if index < 4 else "test") if kind == "known" else (
                    "calibration" if index < len(photos) // 2 else "test")
                relative = str(photo.relative_to(root))
                items.append({"id": hashlib.sha256(relative.encode()).hexdigest()[:20], "path": str(photo),
                              "sha256": fingerprint, "person": folder.name, "known": kind == "known", "split": split})
    known = {p["person"] for p in items if p["known"]}
    if len(known) < 2 or not any(not p["known"] for p in items):
        raise ValueError("Add at least two people under known/<name>/ and one other person under unknown/<label>/.")
    return items


def wilson(successes, count):
    if not count:
        return None
    z = 1.959963984540054
    p, z2 = successes / count, z * z
    centre = (p + z2 / (2 * count)) / (1 + z2 / count)
    radius = z * math.sqrt(p * (1 - p) / count + z2 / (4 * count * count)) / (1 + z2 / count)
    return [max(0.0, centre - radius), min(1.0, centre + radius)]


def choose_threshold(known, unknown):
    """Highest known correct acceptance subject to zero observed unknown calibration accepts."""
    if not known or not unknown:
        return None
    scores = sorted({p["score"] for p in known + unknown})
    candidates = scores + [math.nextafter(s, math.inf) for s in scores]
    feasible = [t for t in candidates if all(p["score"] < t for p in unknown)]
    return min(feasible, key=lambda t: (-sum(p["correct"] and p["score"] >= t for p in known), t))


def evaluate(items, available, similarity, restrict=None):
    available = set(available)
    selected = [p for p in items if restrict is None or p["id"] in restrict]
    references = {}
    for p in selected:
        if p["split"] == "reference" and p["id"] in available:
            references.setdefault(p["person"], []).append(p["id"])
    predictions = []
    for p in selected:
        if p["split"] == "reference":
            continue
        result = {**p, "processed": False}
        if p["id"] in available and references:
            candidates = [(max(similarity(p["id"], ref) for ref in refs), person)
                          for person, refs in references.items()]
            score, person = sorted(candidates, key=lambda c: (-c[0], c[1]))[0]
            result.update(processed=True, score=float(score), predicted=person,
                          correct=p["known"] and person == p["person"])
        predictions.append(result)
    calibration = [p for p in predictions if p["split"] == "calibration" and p["processed"]]
    threshold = choose_threshold([p for p in calibration if p["known"]],
                                 [p for p in calibration if not p["known"]])
    test = [p for p in predictions if p["split"] == "test"]
    known = [p for p in test if p["known"]]
    unknown = [p for p in test if not p["known"]]
    processed_known = [p for p in known if p["processed"]]
    processed_unknown = [p for p in unknown if p["processed"]]
    for p in predictions:
        p["accepted"] = bool(p["processed"] and threshold is not None and p["score"] >= threshold)
    correct = sum(p["accepted"] and p.get("correct", False) for p in known)
    wrong = sum(p["accepted"] and not p.get("correct", False) for p in known)
    false_accepts = sum(p["accepted"] for p in unknown)
    return {
        "reference_counts": {person: len(refs) for person, refs in references.items()},
        "missing_reference_people": sorted({p["person"] for p in selected if p["known"]} - references.keys()),
        "threshold": threshold, "threshold_policy": "zero observed unknown calibration accepts; maximize correct known accepts",
        "calibration_known_processed": sum(p["known"] for p in calibration),
        "calibration_unknown_processed": sum(not p["known"] for p in calibration),
        "known_test_count": len(known), "known_processed": len(processed_known),
        "top1_correct": sum(p["correct"] for p in processed_known),
        "top1_accuracy": sum(p["correct"] for p in processed_known) / len(processed_known) if processed_known else None,
        "correct_accepts": correct if threshold is not None else None,
        "correct_accept_rate": correct / len(known) if known and threshold is not None else None,
        "wrong_identity_accepts": wrong if threshold is not None else None,
        "known_not_accepted": len(known) - correct - wrong if threshold is not None else None,
        "unknown_test_count": len(unknown), "unknown_processed": len(processed_unknown),
        "unknown_false_accepts": false_accepts if threshold is not None else None,
        "unknown_false_accept_rate": false_accepts / len(processed_unknown) if processed_unknown and threshold is not None else None,
        "unknown_false_accept_95pct_interval": wilson(false_accepts, len(processed_unknown)) if threshold is not None else None,
        "predictions": predictions,
    }
