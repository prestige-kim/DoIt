#!/usr/bin/env python3
"""Build unsigned per-user Windows installers and a local download preview."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile


ARCHITECTURES = {"x64": 0x8664, "arm64": 0xAA64}
SETUP_MACHINE = 0x014C  # NSIS 3.13 launcher is x86; the installed app is native.
MARKER = ".doit-app-payload"


def run(*command, cwd=None):
    subprocess.run(command, cwd=cwd, check=True)


def output(*command, cwd=None):
    return subprocess.check_output(command, cwd=cwd)


def get_source(repo, revision, snapshot):
    commit = output("git", "rev-parse", "--verify", f"{revision}^{{commit}}", cwd=repo).decode().strip()
    archive = output("git", "archive", "--format=zip", commit, "windows/", "site/", "LICENSE", cwd=repo)
    with zipfile.ZipFile(io.BytesIO(archive)) as files:
        files.extractall(snapshot)
    return commit


def inspect_pe(path):
    with path.open("rb") as binary:
        if binary.read(2) != b"MZ":
            raise ValueError(f"Not a Windows executable: {path.name}")
        binary.seek(0x3C)
        pe_offset = struct.unpack("<I", binary.read(4))[0]
        binary.seek(pe_offset)
        if binary.read(4) != b"PE\x00\x00":
            raise ValueError(f"Invalid PE header: {path.name}")
        machine = struct.unpack("<H", binary.read(2))[0]
        binary.seek(pe_offset + 24)
        magic = struct.unpack("<H", binary.read(2))[0]
        if magic not in (0x10B, 0x20B):
            raise ValueError(f"Invalid PE optional header: {path.name}")
        binary.seek(pe_offset + 24 + (96 if magic == 0x10B else 112) + 4 * 8)
        certificate_offset, certificate_size = struct.unpack("<II", binary.read(8))
    return machine, bool(certificate_offset or certificate_size)


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def publish(args, snapshot, arch, publish_dir):
    project = snapshot / "windows/DoIt.Windows/DoIt.Windows.csproj"
    flags = []
    for source in args.nuget_source:
        flags.extend(["--source", str(source)])
    run(
        args.dotnet, "publish", str(project), "--configuration", "Release", "--runtime", f"win-{arch}",
        "--self-contained", "true", "--output", str(publish_dir), "-p:EnableWindowsTargeting=true",
        "-p:PublishSingleFile=false", "-p:UseSharedCompilation=false", "-p:DebugType=None",
        f"-p:Version={args.version}", f"-p:FileVersion={args.version}.{args.build}", *flags,
    )
    app = publish_dir / "DoIt.Windows.exe"
    app_machine, _ = inspect_pe(app)
    if app_machine != ARCHITECTURES[arch]:
        raise ValueError(f"Incorrect app architecture for {arch}: 0x{app_machine:04x}")
    for runtime_file in ("coreclr.dll", "hostfxr.dll", "PresentationFramework.dll"):
        if not (publish_dir / runtime_file).is_file():
            raise ValueError(f"Missing self-contained Windows runtime: {runtime_file}")
    (publish_dir / MARKER).write_text("DoIt.Windows\n", encoding="utf-8")
    copy_notices(snapshot, project, publish_dir)


def copy_notices(snapshot, project, publish_dir):
    target = publish_dir / "Licenses"
    target.mkdir(exist_ok=True)
    shutil.copyfile(snapshot / "LICENSE", target / "DoIt-LICENSE.txt")
    assets = json.loads((project.parent / "obj/project.assets.json").read_text(encoding="utf-8"))
    for library in assets["libraries"].values():
        if library.get("type") != "package":
            continue
        package_path = Path(library["path"])
        for folder in assets["packageFolders"]:
            package = Path(folder) / package_path
            if not package.is_dir():
                continue
            for notice in package.iterdir():
                name = re.sub(r"[^a-z]", "", notice.stem.lower())
                if notice.is_file() and ("license" in name or "notice" in name) and notice.suffix.lower() in {".txt", ".md", ""}:
                    destination = target / (package_path.parent.name + "-" + package_path.name) / notice.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(notice, destination)
            break
    copy_runtime_notices(assets, target)


def copy_runtime_notices(assets, target):
    # Self-contained runtime packs are restored as download dependencies, not as libraries.
    copied = set()
    for framework in assets["project"]["frameworks"].values():
        for dependency in framework.get("downloadDependencies", []):
            name = dependency["name"]
            if not re.fullmatch(r"Microsoft\.(NETCore|WindowsDesktop)\.App\.Runtime\.win-(x64|arm64)", name):
                continue
            version = dependency["version"].strip("[]").split(",")[0].strip()
            for folder in assets["packageFolders"]:
                package = Path(folder) / name.lower() / version
                if not package.is_dir():
                    continue
                for notice in package.iterdir():
                    stem = re.sub(r"[^a-z]", "", notice.stem.lower())
                    if notice.is_file() and ("license" in stem or "notice" in stem):
                        destination = target / f"{name.lower()}-{version}" / notice.name
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(notice, destination)
                        copied.add(name.split(".")[1])
                break
    if copied != {"NETCore", "WindowsDesktop"}:
        raise ValueError("Missing .NET or Windows Desktop runtime license notices for the self-contained app")


def build_license(snapshot, project, destination):
    """Write the installer agreement: Korean notice, DoIt MIT license, then the Windows App SDK terms verbatim."""
    assets = json.loads((project.parent / "obj/project.assets.json").read_text(encoding="utf-8"))
    terms = None
    for library, details in assets["libraries"].items():
        if library.lower().startswith("microsoft.windowsappsdk.foundation/") and details.get("type") == "package":
            for folder in assets["packageFolders"]:
                candidate = Path(folder) / details["path"] / "license.txt"
                if candidate.is_file():
                    terms = candidate.read_text(encoding="utf-8-sig")
                    break
    if not terms or "MICROSOFT SOFTWARE LICENSE TERMS" not in terms.upper():
        raise ValueError("Windows App SDK license terms were not found for the installer agreement")
    intro = (snapshot / "windows/packaging/license-intro-ko.txt").read_text(encoding="utf-8")
    mit = (snapshot / "LICENSE").read_text(encoding="utf-8")
    separator = "\r\n\r\n" + "=" * 60 + "\r\n\r\n"
    text = separator.join(part.strip().replace("\r\n", "\n").replace("\n", "\r\n")
                          for part in (intro, "DoIt\r\n\r\n" + mit, "Windows App SDK\r\n\r\n" + terms))
    # NSIS reads a UTF-8 license file only with a byte order mark.
    destination.write_bytes(b"\xef\xbb\xbf" + (text + "\r\n").encode("utf-8"))
    return destination


def setup(args, snapshot, arch, publish_dir, installer):
    script = snapshot / "windows/packaging/installer.nsi"
    project = snapshot / "windows/DoIt.Windows/DoIt.Windows.csproj"
    license_file = build_license(snapshot, project, snapshot / f"installer-license-{arch}.txt")
    prefix = "/" if os.name == "nt" else "-"
    run(
        args.makensis, f"{prefix}V2", f"{prefix}INPUTCHARSET", "UTF8",
        *([f"{prefix}DWINDOWS_COMPILER"] if os.name == "nt" else []), f"{prefix}DVERSION={args.version}", f"{prefix}DBUILD={args.build}",
        f"{prefix}DARCH={arch}", f"{prefix}DPUBLISH_DIRECTORY={publish_dir}",
        f"{prefix}DLICENSE_FILE={license_file}",
        f"{prefix}DINSTALLER_OUTPUT={installer}", str(script),
    )
    machine, signed = inspect_pe(installer)
    if machine != SETUP_MACHINE or signed:
        raise ValueError("Installer PE does not match the expected unsigned NSIS x86 launcher")
    return {"filename": installer.name, "bytes": installer.stat().st_size, "sha256": digest(installer),
            "appMachine": arch, "setupMachine": "x86", "signed": False}


def enable_preview(preview, version, build, assets):
    config = {
        "version": version, "build": build,
        "assets": {arch: {"url": f"./downloads/{asset['filename']}", "sha256": asset["sha256"]}
                   for arch, asset in assets.items()},
    }
    config_path = preview / "windows-preview.js"
    if config_path.exists():
        raise ValueError("Preview download configuration already exists")
    config_path.write_text(f"globalThis.DOIT_WINDOWS_PREVIEW = {json.dumps(config, indent=2)};\n", encoding="utf-8")
    index_path = preview / "index.html"
    index = index_path.read_text(encoding="utf-8")
    module = re.search(r'<script\s+type="module"', index)
    if not module:
        raise ValueError("Landing module could not be found")
    index = index[:module.start()] + '<script src="./windows-preview.js"></script>\n  ' + index[module.start():]
    index_path.write_text(index, encoding="utf-8")
    (preview / "downloads/SHA256SUMS.txt").write_text(
        "".join(f"{asset['sha256']}  {asset['filename']}\n" for asset in assets.values()), encoding="utf-8")


def build(args):
    if os.name != "nt":
        raise OSError("Run this on Windows. The Windows App SDK requires Windows mt.exe to merge the notification manifest.")
    destination = args.output.resolve()
    if destination.exists():
        raise FileExistsError(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="doit-windows-source-") as snapshot_dir:
        snapshot = Path(snapshot_dir)
        if args.source_zip:
            with zipfile.ZipFile(args.source_zip) as files:
                commit = files.comment.decode("ascii").strip()
                if not re.fullmatch(r"[a-f0-9]{40,64}", commit):
                    raise ValueError("Expected a source ZIP made by git archive")
                for member in files.infolist():
                    path = Path(member.filename)
                    if path.is_absolute() or ".." in path.parts or "\\" in member.filename or ":" in member.filename:
                        raise ValueError("Unsafe path in source ZIP")
                files.extractall(snapshot)
        else:
            commit = get_source(args.repo, args.commit, snapshot)
        stage = Path(tempfile.mkdtemp(prefix=".doit-windows-stage-", dir=destination.parent))
        try:
            preview = stage / "preview"
            shutil.copytree(snapshot / "site", preview)
            downloads = preview / "downloads"
            downloads.mkdir()
            assets = {}
            for arch in ARCHITECTURES:
                publish_dir = snapshot / f"publish-{arch}"
                publish(args, snapshot, arch, publish_dir)
                installer = downloads / f"DoIt-Windows-{args.version}-{args.build}-{arch}-Setup.exe"
                assets[arch] = setup(args, snapshot, arch, publish_dir, installer)
            enable_preview(preview, args.version, args.build, assets)
            nsis_switch = "/VERSION" if os.name == "nt" else "-VERSION"
            manifest = {
                "version": args.version, "build": args.build, "sourceCommit": commit,
                "dotnetSdk": output(args.dotnet, "--version").decode().strip(),
                "nsis": output(args.makensis, nsis_switch).decode().strip(), "assets": assets,
            }
            (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
            stage.rename(destination)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    print(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--commit", default="HEAD")
    parser.add_argument("--source-zip", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--makensis", default="makensis")
    parser.add_argument("--nuget-source", action="append", type=Path, default=[])
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or any(int(part) > 65535 for part in args.version.split(".")):
        parser.error("--version must be numeric major.minor.patch (each at most 65535)")
    if not 1 <= args.build <= 65535:
        parser.error("--build must be between 1 and 65535")
    build(args)


if __name__ == "__main__":
    main()
