# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy==2.2.6", "opencv-python-headless==4.12.0.88"]
# ///
"""Frozen-reference Vision + SFace evaluation of every face in group photos."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import html
import importlib.util
import json
from pathlib import Path
import statistics
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "evals/people"))
from metrics import EXTENSIONS
from group_metrics import prediction, presence

spec = importlib.util.spec_from_file_location("people_eval", ROOT / "scripts/people-eval.py")
pipeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pipeline)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--groups", type=Path, required=True)
    parser.add_argument("--baseline-run", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    import cv2
    import numpy as np
    cv2.setNumThreads(2)
    baseline = args.baseline_run.resolve()
    previous = json.loads((baseline / "report.json").read_text())
    if previous["model_revision"] != pipeline.REVISION or previous["normalization_max_pixels"] != 1600:
        raise ValueError("Baseline model/preprocessing version differs")
    threshold = previous["end_to_end"]["Vision + SFace"]["threshold"]
    if threshold is None:
        raise ValueError("Baseline has no calibrated threshold")
    manifest = json.loads((baseline / "manifest.json").read_text())
    with np.load(baseline / "Vision-+-SFace.npz", allow_pickle=False) as stored:
        references = {}
        for item in manifest:
            if item["split"] == "reference" and item["id"] in stored:
                vector = pipeline.unit(stored[item["id"]])
                if len(vector) != 128:
                    raise ValueError("Expected SFace 128-D references")
                references.setdefault(item["person"], []).append(vector)
    known = {name.casefold(): name for name in references}
    groups = args.groups.resolve()
    items, labels, seen = [], {}, {}
    old_hashes = {p["sha256"]: p for p in manifest}
    for photo in sorted(groups.rglob("*")):
        if not photo.is_file() or photo.suffix.lower() not in EXTENSIONS:
            continue
        relative = photo.relative_to(groups)
        if len(relative.parts) < 2:
            raise ValueError(f"Put {photo.name} in a folder naming the people present")
        tokens = relative.parts[0].casefold().split("-")
        if any(token not in known for token in tokens) or len(tokens) != len(set(tokens)):
            raise ValueError(f"Unknown/duplicate person in folder {relative.parts[0]}")
        digest = hashlib.sha256(photo.read_bytes()).hexdigest()
        if digest in seen:
            raise ValueError(f"Duplicate group images: {relative} and {seen[digest]}")
        if digest in old_hashes:
            raise ValueError(f"Group image overlaps earlier evaluation: {relative}")
        seen[digest] = str(relative)
        identifier = hashlib.sha256(str(relative).encode()).hexdigest()[:20]
        # These items alone go to the detector: expected labels never enter inference.
        items.append({"id": identifier, "path": str(photo)})
        labels[identifier] = {"relative": str(relative), "sha256": digest,
                              "expected": sorted(known[t] for t in tokens)}
    if not items:
        raise ValueError("No group photos found")
    cache = ROOT / ".dev/people-eval"
    run = (args.output or cache / "group-runs" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")).resolve()
    run.mkdir(parents=True, exist_ok=False)
    (run / "annotated").mkdir()
    (run / "crops").mkdir()
    models = pipeline.model_files(cache / "models")
    recognizer = cv2.FaceRecognizerSF.create(str(models["sface"]), "")
    vision = pipeline.vision_run(pipeline.vision_helper(cache), "detect", items, run / "vision-detections.json")
    records, vectors = [], {}
    for image in vision["images"]:
        identifier = image["id"]
        record = {"id": identifier, "path": image["path"], "detected_faces": len(image.get("faces", [])), "faces": []}
        if image.get("error"):
            record["error"] = image["error"]
        else:
            decoded = cv2.imread(image["normalized"])
            if decoded is None:
                record["error"] = "Cannot read normalized image"
            else:
                canvas = decoded.copy()
                embedding_seconds = 0.0
                # Stable image-local numbering: face centre from left to right.
                detected = sorted(image.get("faces", []), key=lambda f: (f["box"][0] + f["box"][2] / 2, f["box"][1]))
                for index, face in enumerate(detected, 1):
                    result = {"number": index, "box": face["box"], "quality": face.get("quality"), "accepted": None}
                    if "anchors" not in face:
                        result["error"] = "Landmarks unavailable"
                    else:
                        started = time.perf_counter()
                        aligned = pipeline.align_vision(decoded, face["anchors"])
                        vector = pipeline.unit(recognizer.feature(aligned))
                        scores = {name: float(max(vector @ ref for ref in refs)) for name, refs in references.items()}
                        result.update(prediction(scores, threshold))
                        result["align_embed_match_seconds"] = time.perf_counter() - started
                        embedding_seconds += result["align_embed_match_seconds"]
                        key = f"{identifier}-face-{index}"
                        vectors[key] = vector
                        result["crop"] = f"crops/{key}.png"
                        if not cv2.imwrite(str(run / result["crop"]), aligned):
                            raise RuntimeError("Could not save aligned face crop")
                    x, y, w, h = [round(value) for value in face["box"]]
                    cv2.rectangle(canvas, (x, y), (x + w, y + h), (0, 220, 255), 2)
                    cv2.putText(canvas, str(index), (max(0, x), max(20, y - 5)), cv2.FONT_HERSHEY_SIMPLEX, .8, (0, 220, 255), 2)
                    record["faces"].append(result)
                record["annotated"] = f"annotated/{identifier}.jpg"
                if not cv2.imwrite(str(run / record["annotated"]), canvas):
                    raise RuntimeError("Could not save numbered image")
                record["face_pipeline_seconds"] = image["detection_seconds"] + embedding_seconds
                record["normalization_seconds"] = image["normalization_seconds"]
                record["quality_seconds"] = image.get("quality_seconds")
        # Join expected labels only after every face has been independently predicted.
        record.update(labels[identifier])
        record.update(presence(record["expected"], record["faces"]))
        if record.get("error"):
            record["exact_presence_match"] = False
        records.append(record)
        print(f"{record['relative']}: {record['detected_faces']} faces; predicted {record['predicted']}; missing {record['missing']}; unexpected {record['unexpected']}", flush=True)
    counts = Counter(record["relative"].split("/")[0] for record in records)
    summary = {"photos": len(records), "detected_faces": sum(r["detected_faces"] for r in records),
               "embedded_faces": len(vectors), "exact_presence_matches": sum(r["exact_presence_match"] for r in records),
               "missing_person_photo_pairs": sum(len(r["missing"]) for r in records),
               "unexpected_person_photo_pairs": sum(len(r["unexpected"]) for r in records),
               "photos_with_duplicate_assignments": sum(bool(r["duplicate_assignments"]) for r in records),
               "photos_with_errors": sum("error" in r for r in records), "folders": dict(counts),
               "face_pipeline_median_seconds": statistics.median(r["face_pipeline_seconds"] for r in records if "face_pipeline_seconds" in r) if any("face_pipeline_seconds" in r for r in records) else None}
    report = {"method": "Vision + SFace", "baseline": str(baseline), "threshold": threshold,
              "reference_counts": {p: len(refs) for p, refs in references.items()}, "model_revision": pipeline.REVISION,
              "reference_vectors_sha256": hashlib.sha256((baseline / "Vision-+-SFace.npz").read_bytes()).hexdigest(),
              "summary": summary, "photos": records,
              "limitations": ["Folder labels measure photo-level presence only; they cannot detect swapped face identities.",
                              "Unknown-person face counts and false matches need manual face-level labels.",
                              "No thresholds or reference vectors were changed using group photos.",
                              "Timings exclude crop/report writes, process overhead and UI. Input normalization and optional quality are separate."]}
    pipeline.save(run / "report.json", report)
    np.savez_compressed(run / "face-vectors.npz", **vectors)
    esc = lambda value: html.escape(str(value), quote=True)
    sections = []
    for record in records:
        rows = "".join(f"<tr><td>{f['number']}</td><td>{esc(f.get('accepted') or 'Unknown / rejected')}</td><td>{esc(f.get('candidate', '—'))}</td><td>{f.get('score', 0):.3f}</td><td>{esc(f.get('error', ''))}</td></tr>" for f in record["faces"])
        picture = f"<a href='{esc(record['annotated'])}'><img src='{esc(record['annotated'])}' alt='Numbered detected faces'></a>" if "annotated" in record else ""
        sections.append(f"<section><h2>{esc(record['relative'])}</h2><p>Expected: {esc(', '.join(record['expected']))}. Predicted: {esc(', '.join(record['predicted']) or 'None')}.</p><p>Missing: {esc(', '.join(record['missing']) or 'None')}. Unexpected: {esc(', '.join(record['unexpected']) or 'None')}. Duplicate assignments: {esc(', '.join(record['duplicate_assignments']) or 'None')}.</p>{picture}<table><tr><th>Face #</th><th>Accepted prediction</th><th>Best candidate</th><th>Score</th><th>Error</th></tr>{rows}</table><p>{esc(record.get('error', 'Please confirm each face number/name and note any undetected faces.'))}</p></section>")
    document = "<!doctype html><meta charset='utf-8'><title>Morrow group-photo review</title><style>body{font:16px system-ui;max-width:1100px;margin:32px auto;padding:0 20px;background:#171717;color:#eee}section{border-top:1px solid #555;margin-top:32px;padding-top:16px}img{max-width:100%;max-height:720px}table{border-collapse:collapse;margin-top:16px}td,th{padding:8px 16px;border:1px solid #555;text-align:left}a{color:#9cf}</style><h1>Group-photo recognition review</h1>"
    document += f"<p>{summary['exact_presence_matches']}/{summary['photos']} photos have the expected set of names. This is photo-level agreement, not verified face accuracy. Threshold {threshold:.6f}, frozen from the earlier calibration.</p>" + "".join(sections)
    (run / "review.html").write_text(document)
    print(json.dumps(summary, indent=2))
    print(f"Review: {run / 'review.html'}")


if __name__ == "__main__":
    main()
