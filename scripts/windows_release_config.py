#!/usr/bin/env python3
"""Fill WINDOWS_RELEASE in site/windows-download.js from a package_windows.py manifest.

Default is a preview: it prints the line that would change and writes nothing.
Pass --write only after the GitHub Release assets were uploaded and re-downloaded.
Standard library only. Exit code 1 on any refusal; the target file is left untouched.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ARCHITECTURES = ("x64", "arm64")
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")
SHA256 = re.compile(r"[0-9a-fA-F]{64}")
OWNER = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?")
REPOSITORY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}")
PLACEHOLDER = re.compile(r"example|placeholder|your-owner|your-repo|demo", re.I)
RELEASE_LINE = re.compile(r"^export const WINDOWS_RELEASE = Object\.freeze\(\{.*\}\);$", re.M)
CONFIG_VALUE = r"^\s*{}:\s*'([^'\n]*)',\s*$"
ROOT = Path(__file__).resolve().parents[1]


class Refused(Exception):
    pass


def asset_file(version, build, arch):
    return f"DoIt-Windows-{version}-{build}-{arch}-Setup.exe"


def release_url(owner, repository, version, build, arch):
    return (f"https://github.com/{owner}/{repository}/releases/download/"
            f"windows-v{version}-{build}/{asset_file(version, build, arch)}")


def read_site(config_path):
    try:
        text = config_path.read_text(encoding="utf-8")
    except OSError:
        raise Refused(f"사이트 설정을 읽을 수 없어요: {config_path.name}")
    values = {}
    for key in ("owner", "repository"):
        found = re.findall(CONFIG_VALUE.format(key), text, re.M)
        if len(found) != 1:
            raise Refused(f"config.js에서 {key} 값을 하나로 찾을 수 없어요")
        values[key] = found[0]
    if (not OWNER.fullmatch(values["owner"]) or not REPOSITORY.fullmatch(values["repository"])
            or PLACEHOLDER.search(f"{values['owner']}/{values['repository']}")):
        raise Refused("config.js의 owner/repository가 공개 주소 형식이 아니에요")
    return values["owner"], values["repository"]


def load_manifest(path, only):
    try:
        manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise Refused("manifest.json을 읽을 수 없거나 JSON이 아니에요")
    if not isinstance(manifest, dict):
        raise Refused("manifest 최상위가 객체가 아니에요")
    version, build, assets = manifest.get("version"), manifest.get("build"), manifest.get("assets")
    if (not isinstance(version, str) or not VERSION.fullmatch(version)
            or any(int(part) > 65535 for part in version.split("."))):
        raise Refused("버전은 x.y.z 숫자 형식이어야 해요 (각 부분 65535 이하)")
    if type(build) is not int or not 1 <= build <= 65535:
        raise Refused("빌드 번호는 1~65535 정수여야 해요")
    if not isinstance(assets, dict) or not assets:
        raise Refused("manifest에 assets가 없어요")
    unknown = sorted(set(assets) - set(ARCHITECTURES))
    if unknown:
        raise Refused(f"알 수 없는 아키텍처: {', '.join(map(str, unknown))}")
    selected = list(only) if only else [arch for arch in ARCHITECTURES if arch in assets]
    if only and len(set(only)) != len(only):
        raise Refused("--only에 같은 아키텍처를 두 번 적었어요")
    if not only and set(selected) != set(ARCHITECTURES):
        raise Refused("manifest에 x64·arm64가 모두 없어요. 하나만 켜려면 --only를 쓰세요")
    checked = {}
    for arch in selected:
        asset = assets.get(arch)
        if not isinstance(asset, dict):
            raise Refused(f"manifest에 {arch} 자산이 없어요")
        expected = asset_file(version, build, arch)
        if asset.get("filename") != expected:
            raise Refused(f"{arch} 파일명이 {expected} 형식과 달라요")
        sha = asset.get("sha256")
        if not isinstance(sha, str) or not SHA256.fullmatch(sha):
            raise Refused(f"{arch} sha256이 64자리 16진수가 아니에요")
        size = asset.get("bytes")
        if type(size) is not int or size <= 0:
            raise Refused(f"{arch} 파일 크기(bytes)가 올바르지 않아요")
        if "appMachine" in asset and asset["appMachine"] != arch:
            raise Refused(f"{arch} 자산의 appMachine 값이 아키텍처와 달라요")
        if not isinstance(asset.get("signed", False), bool):
            raise Refused(f"{arch} signed 값은 true/false여야 해요")
        checked[arch] = {"filename": expected, "sha256": sha.lower(), "bytes": size}
    return version, build, checked


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def verify_files(paths, assets):
    by_name = {asset["filename"]: arch for arch, asset in assets.items()}
    seen = set()
    for raw in paths:
        path = Path(raw)
        arch = by_name.get(path.name)
        if arch is None:
            raise Refused(f"켜려는 자산 이름이 아니에요: {path.name}")
        if arch in seen:
            raise Refused(f"{arch} 파일을 두 번 지정했어요")
        if not path.is_file():
            raise Refused(f"파일이 없어요: {path.name}")
        if path.stat().st_size != assets[arch]["bytes"]:
            raise Refused(f"{path.name} 크기가 manifest와 달라요")
        if digest(path) != assets[arch]["sha256"]:
            raise Refused(f"{path.name} SHA-256이 manifest와 달라요")
        seen.add(arch)
    missing = [arch for arch in assets if arch not in seen]
    if missing:
        raise Refused(f"--verify-file에 {', '.join(missing)} 파일이 빠졌어요")


def release_line(owner, repository, version, build, assets):
    parts = []
    for arch in ARCHITECTURES:
        if arch in assets:
            url = release_url(owner, repository, version, build, arch)
            parts.append(f"{arch}: {{ url: '{url}', sha256: '{assets[arch]['sha256']}' }}")
    return ("export const WINDOWS_RELEASE = Object.freeze({ releasePublished: true, "
            f"version: '{version}', build: {build}, assets: {{ {', '.join(parts)} }} }});")


def find_node(option):
    if option:
        return option if Path(option).is_file() else None
    return shutil.which("node")


def check_with_node(node, script_text, config_path, expected):
    """Run the real verifiedWindowsDownload on a temporary copy and compare the result."""
    with tempfile.TemporaryDirectory(prefix="doit-windows-release-") as tmp:
        folder = Path(tmp)
        shutil.copyfile(config_path, folder / "config.js")
        (folder / "windows-download.js").write_text(script_text, encoding="utf-8")
        module = (folder / "windows-download.js").as_uri()
        code = (f"const m = await import({json.dumps(module)});"
                "console.log(JSON.stringify(m.verifiedWindowsDownload()));")
        try:
            result = subprocess.run([node, "--input-type=module", "-e", code], capture_output=True,
                                    text=True, timeout=60, cwd=tmp)
        except (OSError, subprocess.TimeoutExpired):
            raise Refused("node 실행에 실패했어요")
    if result.returncode != 0:
        raise Refused("node에서 windows-download.js를 불러오지 못했어요")
    try:
        actual = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise Refused("node 검사 결과를 읽을 수 없어요")
    if actual != expected:
        raise Refused("verifiedWindowsDownload 결과가 기대와 달라요 (null이거나 값 불일치)")


def run(args):
    target = Path(args.target)
    config_path = target.with_name("config.js")
    owner, repository = read_site(config_path)
    version, build, assets = load_manifest(args.manifest, args.only)
    if args.verify_file:
        verify_files(args.verify_file, assets)
    try:
        text = target.read_text(encoding="utf-8")
    except OSError:
        raise Refused(f"대상 파일을 읽을 수 없어요: {target.name}")
    matches = list(RELEASE_LINE.finditer(text))
    if len(matches) != 1:
        raise Refused("WINDOWS_RELEASE 한 줄 형식을 찾을 수 없어요. 파일 형식이 바뀌었는지 확인하세요")
    old = matches[0].group()
    new = release_line(owner, repository, version, build, assets)
    updated = text[:matches[0].start()] + new + text[matches[0].end():]

    expected = {"version": version, "build": build, "assets": [
        {"architecture": arch, "file": assets[arch]["filename"],
         "url": release_url(owner, repository, version, build, arch), "sha256": assets[arch]["sha256"]}
        for arch in ARCHITECTURES if arch in assets]}
    node = find_node(args.node)
    if node:
        check_with_node(node, updated, config_path, expected)
        node_note = "node 검사: verifiedWindowsDownload 결과 일치"
    elif args.node:
        raise Refused("--node로 지정한 실행 파일이 없어요")
    else:
        node_note = "node 없음: JS 실행 검사는 건너뜀"

    print(f"- {old}")
    print(f"+ {new}")
    print(f"켜는 아키텍처: {', '.join(expected_arch['architecture'] for expected_arch in expected['assets'])}")
    print(node_note)
    if old == new:
        print("이미 같은 값이에요. 바꿀 것이 없어요.")
        return
    if not args.write:
        print("미리보기만 했어요. 파일에 쓰려면 --write를 붙이세요.")
        return
    mode = target.stat().st_mode & 0o777
    fd, temp_name = tempfile.mkstemp(prefix=".windows-download-", dir=target.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(updated)
        os.chmod(temp_name, mode)
        os.replace(temp_name, target)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    print(f"{target.name}에 썼어요.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("manifest", help="package_windows.py가 만든 manifest.json")
    parser.add_argument("--target", default=str(ROOT / "site/windows-download.js"),
                        help="바꿀 windows-download.js (기본: site/windows-download.js)")
    parser.add_argument("--only", nargs="+", choices=ARCHITECTURES,
                        help="실기기 검증을 마친 아키텍처만 켭니다 (예: --only x64)")
    parser.add_argument("--verify-file", nargs="+", metavar="EXE",
                        help="다시 내려받은 설치 파일의 크기·SHA-256을 manifest와 대조합니다")
    parser.add_argument("--node", help="JS 검사에 쓸 node 경로 (기본: PATH에서 찾음, 없으면 건너뜀)")
    parser.add_argument("--write", action="store_true", help="검증이 모두 통과하면 파일에 씁니다")
    args = parser.parse_args(argv)
    try:
        run(args)
    except Refused as error:
        print(f"거부: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
