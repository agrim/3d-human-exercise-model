# Codex Cloud setup

Select both `agrim/3d-human-exercise-model` and `agrim/exercise-markup-language` when creating the environment. This wrapper embeds EML from a separate source checkout; it is not a package-manager dependency or a submodule. Use compatible revisions: the current wrapper expects EML 1.1 (`v1.1.0` is the documented baseline). Keep the source checkouts separate.

## Installation

Use Python 3.11+ and Git. Allow package-manager downloads. Native mesh fixture work also requires Git LFS and GitHub/LFS network access. Set the saved environment variable `EML_ROOT` to the EML checkout directory. The script also recognizes sibling checkouts named `eml` or `exercise-markup-language`, but that detection does not persist a variable into later tasks.

Run this from this repository as the environment's **Install script**:

```sh
bash .codex/cloud/setup.sh
```

It creates/reuses EML's ignored `.venv` and installs its existing dependency constraints. It leaves Git LFS assets untouched for source-only work. It does not install Apple runtimes, start a login service or publish anything. Dependencies follow EML's current `requirements.txt`; this is not an exact dependency lock.

## Task startup and checks

No service is required for source work. For the environment's **Start skill**, identify the two checkout paths, use EML's `.venv/bin/python` explicitly, and run the checks appropriate to the task. Shell exports made by the install script are not a substitute for the saved `EML_ROOT` environment setting.

Run these in the EML checkout for compiler, registry or exercise changes:

```sh
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python -m eml catalog --samples 17 -o out/catalog-report.json
```

For wrapper-authored recipes, use the same interpreter from the wrapper root:

```sh
PYTHONPATH="$EML_ROOT" "$EML_ROOT/.venv/bin/python" -m eml validate Revision/Review/AnatomyViewer/standing-curl-and-return.json
```

An optional browser review uses `.venv/bin/python -m viewer` in EML, then checks `http://127.0.0.1:8765/api/catalog` and opens the forwarded viewer in the cloud workspace. Stop any existing instance before starting another. Do not install the macOS login service in Cloud.

## Optional Blender authoring

Use **Blender 5.2.1 LTS** as the authoring environment baseline, matching the local installation checked with `--version` and a headless Python startup on macOS. Full anatomy rebuilds and Linux execution remain separate validation steps. A default operating-system `blender` package may install another release, so select the explicit version and check it before asset work.

Blender is optional for this wrapper's source edits, EML conformance checks and playback of committed buffers. The editable anatomy master and its rebuild pipeline belong to the EML checkout. Follow [EML's anatomy rebuild guide](https://github.com/agrim/exercise-markup-language/blob/v1.1.0/anatomy/rebuild/README.md), together with that checkout's current Cloud guidance. Configure `BLENDER` as the absolute executable path when Blender is outside `PATH`; the macOS app executable is `/Applications/Blender.app/Contents/MacOS/Blender`, while Cloud needs the matching Linux build.

Keep Blender installation and atlas rebuilding out of the default source-only setup. Before changing the Blender version, verify headless startup, load the master with embedded scripts disabled, run the affected rebuild/audit workflow, and review geometry and animation results. Record the exact version used; do not treat a version-string check as a completed rebuild. The historical actions in the master are not the source of the EML recipes played by the wrapper.

## Native validation boundary

When native work needs the retained mesh fixtures, install Git LFS and hydrate only their paths from the wrapper root:

```sh
git lfs install --local
git lfs pull --include="Revision/Sources/ExerciseDummy/Resources/indices.bin,Revision/Sources/ExerciseDummy/Resources/vertices.bin" --exclude=""
```

Do not fetch the historical asset archives as an environment default.

This repository uses Metal, Apple `simd`, iOS frameworks and an embedded Apple Python runtime. Linux cannot establish a successful Swift/Metal build, native UI behavior, model framing or physical-device performance. For those tasks follow [the build instructions](../../README.md) on macOS with Xcode, including `Revision/Runtime/bootstrap.sh`, and run the applicable package, iOS integration and UI tests there. Keep anatomy authoring and shared EML language changes in the EML repository.

The files here are explicit setup entry points, not an automatically loaded Cloud manifest. Commit and push reviewed changes before creating an environment from GitHub; review, test and publish the environment in the Cloud setup UI. See [the official Cloud environment guide](https://learn.chatgpt.com/docs/environments/cloud-environments).
