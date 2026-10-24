# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["numpy==2.2.6", "opencv-python-headless==4.12.0.88"]
# ///
"""Local held-out comparison of SFace, Vision image similarity, and EmbeddingGemma."""

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import statistics
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "evals" / "people"))
from metrics import discover, evaluate

REVISION = "48b10fa505aeb51fbd127fc60a5c660040e823b7"
MODELS = {
    "yunet": ("face_detection_yunet/face_detection_yunet_2023mar.onnx",
              "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4", 232589),
    "sface": ("face_recognition_sface/face_recognition_sface_2021dec.onnx",
              "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79", 38696353),
}


def save(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def timing_stats(samples):
    return {"seconds": samples, "first_seconds": samples[0] if samples else None,
            "median_after_first_seconds": statistics.median(samples[1:]) if len(samples) > 1 else None,
            "total_seconds": sum(samples)}


def model_files(folder):
    folder.mkdir(parents=True, exist_ok=True)
    files = {}
    for name, (relative, digest, size) in MODELS.items():
        target = folder / Path(relative).name
        if not target.exists() or target.stat().st_size != size or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            print(f"Downloading pinned {name} model ({size:,} bytes)...", flush=True)
            url = f"https://media.githubusercontent.com/media/opencv/opencv_zoo/{REVISION}/models/{relative}"
            temporary = target.with_suffix(".partial")
            with urllib.request.urlopen(url, timeout=90) as response, temporary.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            if temporary.stat().st_size != size or hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
                temporary.unlink()
                raise RuntimeError(f"{name}: model checksum mismatch")
            temporary.replace(target)
        files[name] = target
    return files


def vision_helper(cache):
    source = ROOT / "scripts" / "people-eval-vision.swift"
    executable = cache / "people-eval-vision"
    if not executable.exists() or executable.stat().st_mtime < source.stat().st_mtime:
        print("Compiling standalone Vision evaluator...", flush=True)
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(cache / "module-cache"),
                        str(source), "-o", str(executable)], check=True)
    return executable


def vision_run(helper, mode, items, output):
    manifest = output.with_suffix(".input.json")
    save(manifest, items)
    subprocess.run([str(helper), mode, str(manifest), str(output)], check=True)
    return json.loads(output.read_text())


def align_vision(image, anchors):
    import cv2
    import numpy as np
    # Least-squares similarity transform: two eye centres and outer-lip centre.
    target = [(38.2946, 51.6963), (73.5318, 51.5014), (56.1396, 92.2848)]
    rows, values = [], []
    for (x, y), (tx, ty) in zip(anchors, target):
        rows.extend([[x, -y, 1, 0], [y, x, 0, 1]])
        values.extend([tx, ty])
    a, b, tx, ty = np.linalg.lstsq(np.array(rows), np.array(values), rcond=None)[0]
    transform = np.array([[a, -b, tx], [b, a, ty]], dtype=np.float32)
    return cv2.warpAffine(image, transform, (112, 112), flags=cv2.INTER_LINEAR)


def unit(vector):
    import numpy as np
    vector = np.asarray(vector, dtype=np.float32).flatten()
    norm = float(np.linalg.norm(vector))
    if not math.isfinite(norm) or norm <= 0 or not np.isfinite(vector).all():
        raise ValueError("Invalid embedding")
    return vector / norm


class GemmaWorker:
    def __init__(self, executable, models, folder, budget):
        self.budget = budget
        self.log = (folder / "gemma-worker.log").open("w")
        env = {**os.environ, "DIGUP_MODELS": str(models)}
        self.process = subprocess.Popen(["/usr/bin/time", "-l", str(executable), "worker"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                        text=True, bufsize=1, env=env)
        self.counter = 0
        try:
            ready = self.read()
            if not ready.get("ready"):
                raise RuntimeError(str(ready))
            self.info = ready["info"]
        except BaseException:
            self.close()
            raise

    def read(self):
        if not select.select([self.process.stdout], [], [], 300)[0]:
            raise TimeoutError("Gemma worker timed out; see gemma-worker.log")
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("Gemma worker exited; see gemma-worker.log")
        return json.loads(line)

    def embed(self, op, inputs):
        import numpy as np
        self.counter += 1
        request = {"id": self.counter, "op": op, "inputs": inputs, "budget": self.budget}
        started = time.perf_counter()
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        result = self.read()
        if result.get("id") != self.counter or not result.get("ok"):
            raise RuntimeError(str(result))
        if result["count"] != len(inputs):
            raise RuntimeError("Worker returned an unexpected embedding count")
        array = np.frombuffer(base64.b64decode(result["vectors"]), dtype="<f4").reshape(len(inputs), result["dim"])
        return [None if error else unit(row) for row, error in zip(array, result["errors"])], time.perf_counter() - started

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write(json.dumps({"id": -1, "op": "quit"}) + "\n")
                self.process.stdin.flush()
                self.process.wait(timeout=10)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


def collect(items, run, models, helper, smoke=False):
    import cv2
    cv2.setNumThreads(2)
    load_started = time.perf_counter()
    detector = cv2.FaceDetectorYN.create(str(models["yunet"]), "", (320, 320), .8, .3, 5000)
    recognizer = cv2.FaceRecognizerSF.create(str(models["sface"]), "")
    load_seconds = time.perf_counter() - load_started
    print("Running Vision detection and image normalization...", flush=True)
    vision = vision_run(helper, "detect", items, run / "vision-detections.json")
    vectors = {"YuNet + SFace": {}, "Vision + SFace": {}}
    crops, vision_crops, full, observations, timings = {}, {}, {}, [], {}
    (run / "crops").mkdir()
    for record in vision["images"]:
        identifier = record["id"]
        observation = {"id": identifier, "vision_faces": len(record.get("faces", [])),
                       "vision_detection_seconds": record.get("detection_seconds"),
                       "vision_quality_seconds": record.get("quality_seconds")}
        if record.get("error"):
            observation["error"] = record["error"]
            observations.append(observation)
            continue
        image = cv2.imread(record["normalized"])
        if image is None:
            observation["error"] = "OpenCV could not read normalized image"
            observations.append(observation)
            continue
        full[identifier] = record["normalized"]
        detector.setInputSize((image.shape[1], image.shape[0]))
        started = time.perf_counter()
        faces = detector.detect(image)[1]
        faces = [] if faces is None else list(faces)
        observation["yunet_detection_seconds"] = time.perf_counter() - started
        observation["yunet_faces"] = len(faces)
        if len(faces) == 1 or (smoke and faces):
            face = max(faces, key=lambda f: f[2] * f[3])
            started = time.perf_counter()
            aligned = recognizer.alignCrop(image, face)
            vectors["YuNet + SFace"][identifier] = unit(recognizer.feature(aligned))
            observation["yunet_sface_align_embed_seconds"] = time.perf_counter() - started
            crop = run / "crops" / f"{identifier}-yunet.png"
            if not cv2.imwrite(str(crop), aligned):
                raise RuntimeError(f"Cannot save crop: {crop}")
            crops[identifier] = str(crop)
        vision_faces = record.get("faces", [])
        if len(vision_faces) == 1 or (smoke and vision_faces):
            face = max(vision_faces, key=lambda f: f["box"][2] * f["box"][3])
            if "anchors" in face:
                started = time.perf_counter()
                aligned = align_vision(image, face["anchors"])
                vectors["Vision + SFace"][identifier] = unit(recognizer.feature(aligned))
                observation["vision_sface_align_embed_seconds"] = time.perf_counter() - started
                crop = run / "crops" / f"{identifier}-vision.png"
                if not cv2.imwrite(str(crop), aligned):
                    raise RuntimeError(f"Cannot save crop: {crop}")
                vision_crops[identifier] = str(crop)
        observations.append(observation)
    save(run / "detections.json", observations)
    print("Running Vision image feature prints on the same YuNet-aligned crops...", flush=True)
    prints = vision_run(helper, "prints", [{"id": key, "path": path} for key, path in crops.items()], run / "vision-prints.json")
    for name, values in vectors.items():
        prefix = "yunet" if name == "YuNet + SFace" else "vision"
        samples = [r[f"{prefix}_detection_seconds"] + r[f"{prefix}_sface_align_embed_seconds"]
                   for r in observations if f"{prefix}_sface_align_embed_seconds" in r]
        timings[name] = {"successful_images": len(values), **timing_stats(samples)}
    timings["OpenCV model loading"] = {"seconds": load_seconds}
    timings["Vision image prints"] = {"successful_images": sum("error" not in p for p in prints["items"]),
                                       **timing_stats([p["seconds"] for p in prints["items"]]),
                                       "peak_process_rss_bytes": prints["peak_process_rss_bytes"]}
    return vectors, crops, vision_crops, full, prints, observations, timings


def gemma_collect(executable, models, run, full, crops, vision_crops, items, budget):
    vectors = {"Gemma full-image references": {}, "Gemma face-crop references": {},
               "Gemma Vision-crop references": {}}
    timings, names = {}, {}
    worker = GemmaWorker(executable, models, run, budget)
    try:
        for label, paths in [("Gemma full-image references", full), ("Gemma face-crop references", crops),
                             ("Gemma Vision-crop references", vision_crops)]:
            times = []
            for identifier, path in paths.items():
                print(f"{label}: {len(times) + 1}/{len(paths)}", flush=True)
                result, seconds = worker.embed("image", [path])
                times.append(seconds)
                if result[0] is not None:
                    vectors[label][identifier] = result[0]
            timings[label] = {**timing_stats(times), "successful_images": len(vectors[label])}
        labels = sorted({p["person"] for p in items if p.get("known")})
        if labels:
            values, seconds = worker.embed("text", [f"task: search result | query: {name.replace('_', ' ').replace('-', ' ')}" for name in labels])
            names = {name: value for name, value in zip(labels, values) if value is not None}
            timings["Gemma name queries"] = {"total_seconds": seconds}
    finally:
        worker.close()
    memory = re.search(r"(\d+)\s+maximum resident set size", (run / "gemma-worker.log").read_text())
    timings["Gemma worker"] = {"load_seconds": worker.info.get("load_seconds"),
                               "peak_process_rss_bytes": int(memory[1]) if memory else None}
    return vectors, names, timings, worker.info


def name_search(items, full_vectors, names):
    queries = []
    tests = [p for p in items if p.get("split") == "test" and p["id"] in full_vectors]
    for name, query in names.items():
        ranked = sorted(tests, key=lambda p: -float(query @ full_vectors[p["id"]]))
        relevant = sum(p["known"] and p["person"] == name for p in ranked)
        found, precision_sum = 0, 0.0
        for rank, p in enumerate(ranked, 1):
            if p["known"] and p["person"] == name:
                found += 1
                precision_sum += found / rank
        queries.append({"name": name, "relevant_test_images": relevant,
                        "average_precision": precision_sum / relevant if relevant else None,
                        "top1_correct": bool(ranked and ranked[0]["known"] and ranked[0]["person"] == name),
                        "top5": [{"path": p["path"], "person": p["person"], "known": p["known"],
                                  "score": float(query @ full_vectors[p["id"]])} for p in ranked[:5]]})
    return queries


def markdown_report(report):
    lines = ["# Local face matching comparison", "", f"Dataset: `{report['dataset']}`", "",
             "Thresholds use calibration images only. Higher similarity means a closer match within each method; raw scores across methods are not comparable.", "",
             "| Method | Known processed/test | Top-1 | Correct accepted/test | Wrong identity accepts | Unknown false accepts/processed |",
             "|---|---:|---:|---:|---:|---:|"]
    for name, result in report["end_to_end"].items():
        top = f"{result['top1_accuracy']:.1%}" if result["top1_accuracy"] is not None else "n/a"
        accepted = f"{result['correct_accepts']}/{result['known_test_count']}" if result["threshold"] is not None else "n/a"
        wrong = result["wrong_identity_accepts"] if result["threshold"] is not None else "n/a"
        unknown = f"{result['unknown_false_accepts']}/{result['unknown_processed']}" if result["threshold"] is not None else "n/a"
        lines.append(f"| {name} | {result['known_processed']}/{result['known_test_count']} | {top} | {accepted} | {wrong} | {unknown} |")
    lines.extend(["", f"Common successfully processed images across all methods: {report['common_image_count']}. Full common-set metrics, calibration counts, uncertainty intervals, and individual errors are in `report.json`.", "",
                  "## Gemma name-only retrieval", "", "These queries use names alone, with no reference photos. This is a different test from matching a friend's reference photos.", ""])
    for query in report["gemma_name_search"]:
        ap = f"{query['average_precision']:.1%}" if query["average_precision"] is not None else "n/a"
        lines.append(f"- {query['name']}: average precision {ap}; first result correct: {query['top1_correct']}.")
    lines.extend(["", "## Timing and limitations", "", "`timings` and `detections.json` preserve per-image timings. First inference is separate from later inference; this is a sequential experiment, not an app indexing-throughput benchmark. Peak memory is recorded for the standalone Vision processes; Gemma's `/usr/bin/time -l` output is in `gemma-worker.log`.", "",
                  "A zero observed error rate in a small personal dataset does not establish reliability. Review the individual mismatches and crops. Group photos and face-level detection recall require a separately annotated evaluation. Vision image feature prints are an experimental identity baseline, not a documented face-recognition API.", ""])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=Path.home() / "Desktop/DigUp-Face-Test")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--smoke-image", type=Path, help="Check the pipelines on one image, without reporting identity accuracy")
    parser.add_argument("--gemma-helper", type=Path)
    parser.add_argument("--gemma-budget", type=int, choices=[70, 140, 280, 560, 1120], default=140)
    parser.add_argument("--models", type=Path, default=Path.home() / "Library/Application Support/DigUp/Models")
    parser.add_argument("--without-gemma", action="store_true", help="Explicitly run only the CV baselines")
    args = parser.parse_args()
    if args.smoke_image:
        items = [{"id": "smoke", "path": str(args.smoke_image.resolve()), "known": False}]
    else:
        items = discover(args.dataset)
    import cv2
    import numpy as np
    cache = ROOT / ".dev/people-eval"
    cache.mkdir(parents=True, exist_ok=True)
    run = args.output or cache / "runs" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    run = run.resolve()
    run.mkdir(parents=True, exist_ok=False)
    save(run / "manifest.json", items)
    model_paths = model_files(cache / "models")
    helper = vision_helper(cache)
    vectors, crops, vision_crops, full, prints, detections, timings = collect(items, run, model_paths, helper, bool(args.smoke_image))
    names, gemma_info = {}, None
    if not args.without_gemma:
        candidates = [args.gemma_helper] if args.gemma_helper else [ROOT / ".build/release/digup", Path("/Applications/DigUp.app/Contents/Helpers/digup"), Path("/Volumes/DigUp/DigUp.app/Contents/Helpers/digup")]
        executable = next((p for p in candidates if p and p.is_file()), None)
        if executable is None:
            raise ValueError("Gemma helper not found; supply --gemma-helper /path/to/digup or explicitly use --without-gemma")
        extra, names, times, gemma_info = gemma_collect(executable, args.models, run, full, crops, vision_crops, items, args.gemma_budget)
        vectors.update(extra)
        timings.update(times)
    for name, values in vectors.items():
        np.savez_compressed(run / (name.replace(" ", "-") + ".npz"), **values)
    if args.smoke_image:
        if not crops or any(not values for values in vectors.values()) or not prints["items"] or "error" in prints["items"][0]:
            raise RuntimeError(f"Smoke image did not exercise every pipeline; inspect {run}")
        sanity = {name: {"dimension": len(next(iter(values.values()))),
                         "self_similarity": float(next(iter(values.values())) @ next(iter(values.values())))} for name, values in vectors.items()}
        for name, value in sanity.items():
            if value["dimension"] != (768 if name.startswith("Gemma") else 128) or abs(value["self_similarity"] - 1) > 1e-4:
                raise RuntimeError(f"Invalid {name} smoke embedding: {value}")
        if abs(prints["distances"][0][0]) > 1e-6:
            raise RuntimeError("Vision self-distance is not zero")
        save(run / "smoke.json", {"vectors": sanity, "vision_self_distance": prints["distances"][0][0],
                                   "gemma_info": gemma_info, "timings": timings})
        print(f"Smoke checks passed. No identity accuracy measured. Results: {run}")
        return
    methods = {name: (set(values), lambda a, b, v=values: float(v[a] @ v[b])) for name, values in vectors.items()}
    indices = {p["id"]: i for i, p in enumerate(prints["items"]) if "error" not in p}
    methods["Vision image prints"] = (set(indices), lambda a, b: -float(prints["distances"][indices[a]][indices[b]]))
    common = set.intersection(*(available for available, _ in methods.values()))
    report = {"dataset": str(args.dataset.resolve()), "opencv_version": cv2.__version__, "model_revision": REVISION,
              "gemma_image_budget": args.gemma_budget, "normalization_max_pixels": 1600,
              "models": MODELS, "gemma_info": gemma_info, "timings": timings, "detections": detections,
              "common_image_count": len(common),
              "end_to_end": {name: evaluate(items, available, score) for name, (available, score) in methods.items()},
              "common_set": {name: evaluate(items, available, score, common) for name, (available, score) in methods.items()},
              "gemma_name_search": name_search(items, vectors.get("Gemma full-image references", {}), names)}
    save(run / "report.json", report)
    (run / "report.md").write_text(markdown_report(report))
    print(f"Comparison complete: {run / 'report.md'}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
