# DigUp People

Personal macOS fork on `codex/people-integration`. Build with `bash build.sh`, then open `build.noindex/DigUp People.app`. The native helper bundles SFace and ONNX Runtime; Python is only used by the separate developer evaluations and model-fetch script.

## Use

1. Choose searchable folders in Settings → Folders.
2. Open Settings → People and add a name and optional comma-separated aliases.
3. Add several varied reference photos. For group references, select the intended face explicitly.
4. Enable People search. Faces in indexed photos/screenshots are processed in background batches. Pause/resume is available in People settings.
5. Review uncertain faces, confirm a suggested name, choose a different person, or mark a face as not someone enrolled.
6. Search names in the existing search panel/window: `Alex`, `Alex and Sam`, or `Alex at the beach`. Control–Shift–Space opens the panel. Ambiguous names require a full name or unique alias.

The initial local setup enrolls the three people from the user's existing reference set, with two references each, and selects the existing face-test folder. That setup data lives outside Git; personal photographs and evaluation outputs are not bundled or committed.

## Isolation

- Bundle ID: `local.iqbal.DigUpPeople`.
- Index: `~/Library/Application Support/DigUp People/index.noindex/index.sqlite`.
- Gemma models: `~/Library/Application Support/DigUp People/Models`.
- User defaults: the new bundle domain. Development launches can override all locations and use a separate defaults suite.
- Upstream Sparkle feed is removed from this personal build to prevent an upstream release replacing it.
- Existing DigUp's database, models, preferences and app are left in place. This build uses schema 6; do not point it at the installed application's schema-5 index.

## Storage and execution

Schema 6 adds `people`, `person_references`, `face_files`, `faces`, and `face_matches` to the existing SQLite index. References contain a confirmed name association, a retained aligned thumbnail, and a model-versioned 128-D float32 embedding. Detected faces store normalized boxes, thumbnails, vectors and file links. `face_files` records the source size/mtime stamp and processing version, including images with zero detected faces and read errors.

Curated people, references, and corrections survive `IndexStore.resetAll()`. Source-file changes invalidate search eligibility until faces are recomputed. Deleting a file cascades to derived faces; enrolled references remain independent of original-file deletion. Confirmed and rejected face decisions are protected from automatic rematching, including overlapping workers. Unrecognized vectors are retained so enrollment can rematch them without decoding the library again.

The short-lived native helper uses Vision revision-3 landmarks, three-point alignment, RGB 112×112 input and the pinned SFace ONNX model. Model/preprocessing versions are kept separate from Gemma's 768-D semantic space. Background work is bounded to 40 photos per batch, two inference threads, and selected-folder/exclusion rules. It waits under Low Power Mode, serious thermal pressure, and the existing indexing schedule/power constraints. Canceling enrollment/background work affects only its owned process.

Automatic matches require cosine similarity at least 0.50 and a lead of at least 0.08 over the next enrolled identity. Candidates scoring at least 0.35 can be suggested for review. These conservative initial defaults are not probabilities or a universal reliability guarantee. They deliberately differ from the frozen small-dataset evaluation threshold. Confirmations are authoritative.

Names/aliases resolve on word boundaries. Multi-person queries intersect eligible file sets. Person filtering occurs before the final result limit, including the SQL full-text candidate limit. Name-only lookup skips query embedding. Compound queries embed the remaining topic. Extracted text mentions in documents/PDFs/audio are also candidates; photo folder names do not count as face evidence.

## Validation and present limits

- Native ONNX embeddings on 34 identical aligned crops: minimum cosine against OpenCV greater than 0.9999997.
- Complete native enrollment/detection/alignment replay: same photo-level predictions as the prototype on all 17 group images, with the frozen evaluation threshold.
- Store/search tests cover preservation through reset, corrections/rejections, stale jobs, overlapping writes, aliases/ambiguity, unknown handling, text mentions and filtering before top-K.
- Existing core regression run passed 121 tests across 16 suites; native alignment has its own test.
- The actual empty People screen was rendered and inspected. Interactive enrollment/review should also be exercised by the user on their own data.

Face indexing currently covers photos and screenshots. It is a separate pass, so shared image decoding with Gemma remains a performance improvement to make later. Face tracking in videos and generated answers about people are not implemented. Unknown-person false-match reliability still needs more diverse labeled evaluation. Photo-level agreement alone cannot verify individual face assignments or reveal swapped names.
