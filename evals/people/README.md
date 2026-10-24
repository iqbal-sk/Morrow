# Local face matching evaluation

This experiment evaluates identity matching for Morrow before treating it as production-ready.

The paths are:

1. YuNet detection, its five-point alignment, and SFace identity embeddings.
2. Apple Vision detection/landmarks, three-point similarity alignment, and the same SFace model.
3. Apple Vision image feature prints of the same aligned crops used by path 1. This is an experimental image-similarity baseline, not a documented Apple identity-recognition API.
4. DigUp's installed EmbeddingGemma 2 worker matching whole-image reference embeddings.
5. The same Gemma worker matching the aligned face crops used by path 1.
6. Gemma matching the Vision-aligned crops used by path 2, with identical detector coverage and references.

A separate Gemma test ranks held-out images using each person's name alone, with the app's exact search prompt. This distinguishes familiar public-figure name retrieval from matching a personally enrolled friend. Only reference photographs, not test photographs, supply the identity vectors in paths 1–6.

Path 2 measures the complete alignment/detection change, not a pure detector-only comparison. Paths 3 and 5 hold the crop constant to compare representations. Detection failures and ambiguous images are reported, and matching is also compared on the images all paths successfully process. Whole-image Gemma can also use clothing/background context, which is part of what this experiment measures.

## Photos

Use a local folder outside Git, such as `~/Desktop/DigUp-Face-Test`:

```text
DigUp-Face-Test/
  known/
    Friend-1/       # rename to the person's name or a consistent pseudonym
    Friend-2/
    Friend-3/
  unknown/
    Person-1/       # people who must not match an enrolled friend
    Person-2/
    Person-3/
```

Put at least eight photos of each enrolled friend in their own folder. Use different occasions, lighting, angles, and glasses where applicable. Avoid repeated edits or burst shots of the same photo. For this first experiment, each photo must contain just the named person; images with several detected faces are excluded rather than guessing which face belongs to the folder's name. Use the separate group evaluation below for multi-face photos.

Put at least four photos of each unknown person in their own folder. Unknown identities are never enrolled. Their photos are divided between calibration and test queries.

The evaluator deterministically splits known photos into two references, two calibration queries, and the remaining test queries. It rejects byte-identical duplicate files and records source hashes; avoid near-duplicate edits/burst shots yourself. It chooses thresholds using calibration queries only. Test images are never used to choose a threshold. A zero observed false-accept rate on this small dataset is not evidence of zero risk; the report includes counts and an uncertainty interval.

## Run

Requires full Xcode and `uv`. Dependencies are isolated from DigUp's embedding worker.

```sh
uv run --python 3.12 scripts/people-eval.py --dataset ~/Desktop/DigUp-Face-Test
```

The evaluator uses the installed `digup worker` helper and Morrow's local model files at `~/Library/Application Support/Morrow/Models`. If needed, supply `--gemma-helper /path/to/Morrow.app/Contents/Helpers/digup`. `--without-gemma` explicitly selects only the CV baselines. The app index is never opened or modified.

All images are orientation-normalized to a maximum of 1,600 pixels before the comparison. Gemma defaults to the app's photo budget of 140 visual tokens; `--gemma-budget 280` permits a second run with more image detail and the same deterministic data split. The app defaults to 280 for screenshots; compare budgets explicitly when evaluating screenshot retrieval.

To check every pipeline with one face photo, without claiming recognition accuracy:

```sh
uv run --python 3.12 scripts/people-eval.py --smoke-image /path/to/portrait.jpg
```

Models are downloaded from one pinned OpenCV Zoo revision and verified against the SHA-256 hashes in that revision's Git LFS pointers. Inference and reports stay on this Mac. No images are sent to the download hosts.

Results, normalized images, crops, models, and the standalone Vision helper go under `.dev/people-eval/`, which is already gitignored. Original photos are read only. Reports contain local photo paths and labels; keep them local.

To run the evaluator's metric/split checks without model downloads:

```sh
python3 -m unittest discover -s evals/people -p 'test_*.py'
```

## What to compare

- Detection coverage and multi-face exclusions.
- Correct top-1 identity on held-out photos.
- Correctly accepted known people, rejected known people, and wrong-identity acceptances.
- Unknown people mistakenly accepted as known.
- The same metrics on the common successful image set.
- Per-image detection and embedding time. Timings include the first inference separately; they are measured on this machine, not a model-card estimate.

SFace weights occupy 38,696,353 bytes; YuNet weights occupy 232,589 bytes. These are weight sizes, not total runtime memory or app-size estimates. The Git LFS hashes and sizes are pinned in the evaluator. OpenCV uses two threads for this baseline.

The first milestone is a working, measured comparison. Selecting a model does not yet implement people search in the app.

## Group photos

After the initial evaluation, place new group photos in folders naming all enrolled people present, for example `groups/iqbal-siri/` or `groups/iqbal-vikas-siri/`. Other, unenrolled people may appear too. Each image must appear once and must not be a byte-identical copy of any earlier reference, calibration, or test image. Avoid near-duplicate shots as well; they are not automatically detected.

Run the Vision + SFace group pass with an existing completed baseline run:

```sh
uv run --python 3.12 scripts/people-eval-groups.py \
  --groups ~/Desktop/DigUp-Face-Test/groups \
  --baseline-run /path/to/earlier-run
```

The pass reuses only the baseline reference vectors and its frozen calibration threshold. All detected faces are independently aligned, embedded, and scored, without using expected folder labels or forcing unique names within an image. It joins expected labels only after predictions are complete. Reference vectors, thresholds, model pins, and the original single-person evaluation are unchanged.

Results go under `.dev/people-eval/group-runs/`. Open `review.html` to see numbered face boxes and predictions, and use `report.json` for scores, photo-level presence metrics, duplicates, and timing. Detection plus alignment, embedding and matching time excludes input normalization, optional quality, crop writes, process overhead, and UI. Confirm the numbered faces and note undetected people before reporting face-level accuracy or false matches on unknown people: matching a folder's expected set cannot reveal swapped identities within a photo.

## Sources

- [SFace and its Apache 2.0 license](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface)
- [YuNet and its MIT license](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet)
- [Apple Vision image feature prints](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest)
- [Apple Vision face landmarks](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)
