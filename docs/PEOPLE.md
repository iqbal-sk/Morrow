# People search in Morrow

Morrow lets you find chosen files by the people in their photos. Processing stays on the Mac. You add a name and reference photos, choose the face in each photo, then search for that person alongside ordinary text and visual descriptions.

## Build

Run `bash build.sh`, then open `build.noindex/Morrow.app`. The app bundles the pinned SFace model and ONNX Runtime. Python is used only by developer evaluation scripts and the model-fetch script.

## Data locations

- Search and people index: `~/Library/Application Support/Morrow/index.noindex`.
- Settings: the `com.iqbal.morrow` defaults domain.
- Gemma models: `~/Library/Application Support/Morrow/Models`. Morrow downloads and stores its own model files.
- Search and people index: `~/Library/Application Support/Morrow/index.noindex`. Morrow starts fresh and never imports a DigUp index.

The people database lives inside the selected index directory. Resetting one folder or the complete file index keeps names, aliases, reference photos, and confirmed identities. Removing a person explicitly removes that person's references and identity labels, never the original files.

## Matching and review

Vision detects faces and landmarks. SFace produces the face descriptor after alignment. Face descriptors are versioned separately from Gemma's 768-dimensional semantic vectors. Face inference is serialized across reference selection and background indexing; batches are capped at 40 photos and ONNX uses two inference threads. Small faces can be excluded before matching, and a policy change rechecks the selected folders.

Automatic matches remain visible as automatic matches. Uncertain faces stay out of person search until confirmed. Each review item shows its face crop and a clickable route to the original file. In group photos, reference enrollment asks you to select which face belongs to the person.

Background face work follows selected-folder and exclusion rules, waits for the file index pass, Low Power Mode, serious thermal pressure, and configured schedule or power constraints. People settings explains why scanning is waiting. Canceling enrollment or background work stops only that operation.

## Manual checks

1. Add several varied references for one person, including a group photo where you choose the correct face.
2. Search by the person's full name and alias; confirm matching images and text mentions appear together.
3. Review uncertain faces, confirm a match, correct one to another person, and mark one as unknown.
4. Reset one indexed folder, then reset all indexes. Confirm original files and people references remain.
