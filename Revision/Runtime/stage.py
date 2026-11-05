"""Stage the checked-out EML and signed CPython modules into the Xcode-built app."""
import filecmp
import gzip
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

here = Path(__file__).resolve().parent
bundle = Path(os.environ["CODESIGNING_FOLDER_PATH"])
source = Path(os.environ.get("EML_ROOT") or here.parents[2] / "eml").resolve()
python = here / ".cache/Python.xcframework"
simulator = os.environ["PLATFORM_NAME"] == "iphonesimulator"
slice_dir = python / ("ios-arm64_x86_64-simulator" if simulator else "ios-arm64")
architectures = os.environ["ARCHS"].split()
stdlib = "python/lib/python3.13"
signer = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"


def copy(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dst.is_file() or not filecmp.cmp(src, dst, shallow=False):
        shutil.copyfile(src, dst)


def write(dst, data):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dst.is_file() or dst.read_bytes() != data:
        dst.write_bytes(data)


def stage_eml():
    # Mirror just the runtime contract; removing a recipe from EML removes it here on rebuild.
    expected = {}
    for folder, pattern in [("eml", "*.py"), ("schema", "*.json"), ("library", "*.json"),
                            ("exercises", "*.json"), ("examples", "*.json"), ("compat/1.0/library", "*.json")]:
        for path in sorted((source / folder).glob(pattern)):
            expected[path.relative_to(source)] = path
    for name in ["interface.json", "LICENSE", "anatomy/model.json", "anatomy/vertices.bin",
                 "anatomy/indices.bin", "anatomy/ATTRIBUTION.md"]:
        expected[Path(name)] = source / name
    guidance = json.loads((source / "interface.json").read_text()).get("compatibleSetups")
    if guidance:
        relative = Path(guidance)
        if relative.is_absolute() or ".." in relative.parts or relative.suffix != ".json":
            raise SystemExit("error: compatibleSetups must be a relative EML JSON resource")
        expected[relative] = source / relative
    if not all((source / folder).is_dir() for folder in ("eml", "library", "schema", "exercises")):
        raise SystemExit("error: EML_ROOT must point to the exercise-markup-language checkout.")
    out = bundle / "EML"
    for relative, path in expected.items():
        copy(path, out / relative)
    for path in out.rglob("*"):
        if path.is_file() and path.relative_to(out) not in expected:
            path.unlink()


def stage_python():
    # Pure stdlib comes from the same XCFramework as the interpreter. Use a stored ZIP:
    # encodings and zipimport must be available before extension modules can be imported.
    zipped = here / ".cache/python313-b18.zip"
    if not zipped.exists():
        tmp = zipped.with_suffix(f".{os.getpid()}.tmp")
        root = python / "lib/python3.13"
        skip = {"test", "tests", "__pycache__", "idlelib", "tkinter", "ensurepip", "turtledemo"}
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_STORED) as archive:
            for path in root.rglob("*.py"):
                name = path.relative_to(root)
                if not (skip & set(name.parts)):
                    archive.write(path, str(name))
        tmp.replace(zipped)
    copy(zipped, bundle / "python/lib/python313.zip")
    copy(python / "lib/python3.13/LICENSE.txt", bundle / "python/LICENSE.txt")
    arch_stdlibs = [slice_dir / ("lib-" + arch) / "python3.13" for arch in architectures]
    for directory in arch_stdlibs:
        for config in directory.glob("_sysconfigdata*.py"):
            copy(config, bundle / stdlib / config.name)
    packages = bundle / "python/packages"
    for wheel in json.loads((here / "wheels.json").read_text()):
        path = here / ".cache/wheels" / wheel["name"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != wheel["sha256"]:
            raise SystemExit("error: wheel checksum mismatch. Run Revision/Runtime/bootstrap.sh.")
        with zipfile.ZipFile(path) as archive:
            for entry in archive.namelist():
                if not entry.endswith("/") and "tests" not in Path(entry).parts:
                    write(packages / entry, archive.read(entry))
    copy(here / "Support/eml_mobile.py", packages / "eml_mobile.py")
    write(packages / "rpds/__init__.py", b"from .rpds import *\n")
    copy(here / "Vendor/rpds/LICENSE", packages / "rpds/LICENSE")
    copy(here / "Vendor/rpds/THIRD-PARTY.txt", packages / "rpds/THIRD-PARTY.txt")

    # Ship every production extension in CPython's matching SDK slice. Stdlib modules such
    # as dis/importlib load implementation details (_opcode, _typing) conditionally on iOS.
    # Deriving this list from the XCFramework also follows CPython patch releases.
    for path in sorted((arch_stdlibs[0] / "lib-dynload").glob("*.so")):
        name = path.name.split(".")[0]
        if name.startswith(("_test", "xx", "_ctypes_test")):
            continue
        slices = [(directory / "lib-dynload" / path.name).read_bytes() for directory in arch_stdlibs]
        extension(name, Path(stdlib) / "lib-dynload" / path.with_suffix(".fwork").name, joined(slices))
    targets = {"arm64": "aarch64-apple-ios-sim", "x86_64": "x86_64-apple-ios"}
    rust_arches = [targets[a] for a in architectures] if simulator else ["aarch64-apple-ios"]
    rpds = joined([gzip.decompress((here / "Vendor/rpds" / (a + ".gz")).read_bytes()) for a in rust_arches])
    tag = "iphonesimulator" if simulator else "iphoneos"
    extension("rpds.rpds", Path("python/packages/rpds") / f"rpds.cpython-313-{tag}.fwork", rpds)


def joined(slices):
    if len(slices) == 1:
        return slices[0]
    with tempfile.TemporaryDirectory() as tmp:
        inputs = []
        for i, data in enumerate(slices):
            path = Path(tmp) / str(i)
            path.write_bytes(data)
            inputs.append(path)
        output = Path(tmp) / "universal"
        subprocess.run(["/usr/bin/lipo", "-create", *inputs, "-output", output], check=True)
        return output.read_bytes()


def extension(name, marker, data):
    framework = bundle / "Frameworks" / (name + ".framework")
    executable = framework / name
    write(executable, data)
    executable.chmod(0o755)
    info = {
        "CFBundleIdentifier": os.environ["PRODUCT_BUNDLE_IDENTIFIER"] + "." + name.replace("_", "-"),
        "CFBundleExecutable": name, "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundlePackageType": "FMWK", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
        "CFBundleSupportedPlatforms": ["iPhoneSimulator" if simulator else "iPhoneOS"],
        "MinimumOSVersion": os.environ.get("IPHONEOS_DEPLOYMENT_TARGET", "17.0"),
    }
    write(framework / "Info.plist", plistlib.dumps(info))
    write(bundle / marker, (str(executable.relative_to(bundle)) + "\n").encode())
    write(framework / (name + ".origin"), (str(marker) + "\n").encode())
    if os.environ.get("CODE_SIGNING_ALLOWED", "YES") != "NO":
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", signer, "--timestamp=none", str(framework)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


stage_eml()
stage_python()
