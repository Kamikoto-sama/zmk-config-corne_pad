#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ZMK_IMAGE="${ZMK_IMAGE:-zmkfirmware/zmk-build-arm:stable}"
readonly ZMK_WORKSPACE_VOLUME="${ZMK_WORKSPACE_VOLUME:-cornepad-zmk-workspace}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

run_in_container() {
    command -v west >/dev/null 2>&1 || die "west is not available in the container"

    cd /workspaces

    local initialized=0
    if [[ ! -d .west ]]; then
        echo "==> Initializing the West workspace"
        west init -l --mf config/west.yml config
        initialized=1
    fi

    if [[ "$initialized" == 1 || "${ZMK_UPDATE:-0}" == 1 ]]; then
        echo "==> Updating ZMK and its modules"
        west update
    else
        echo "==> Reusing the existing West workspace"
    fi

    west zephyr-export

    echo "==> Building the build.yaml matrix"
    python3 - /workspaces/config <<'PY'
from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

import yaml


repo = Path(sys.argv[1])
matrix_path = repo / "build.yaml"
matrix = yaml.safe_load(matrix_path.read_text()) or {}
entries = matrix.get("include")

if not isinstance(entries, list) or not entries:
    raise SystemExit(f"No include entries found in {matrix_path}")

requested_targets = {
    target for target in os.environ.get("ZMK_TARGETS", "").split(",") if target
}
if requested_targets:
    available_targets = {
        str(entry.get("shield")) for entry in entries if isinstance(entry, dict)
    }
    missing_targets = requested_targets - available_targets
    if missing_targets:
        missing = ", ".join(sorted(missing_targets))
        raise SystemExit(f"Targets are missing from {matrix_path}: {missing}")
    entries = [entry for entry in entries if str(entry.get("shield")) in requested_targets]

firmware_dir = repo / "firmware"
firmware_dir.mkdir(exist_ok=True)
clean_build = os.environ.get("ZMK_CLEAN") == "1"
updated_workspace = os.environ.get("ZMK_UPDATE") == "1"

built_artifacts: list[Path] = []

for index, entry in enumerate(entries, start=1):
    if not isinstance(entry, dict):
        raise SystemExit(f"Invalid build.yaml entry #{index}: expected a mapping")

    board = entry.get("board")
    shield = entry.get("shield")
    if not board or not shield:
        raise SystemExit(f"Invalid build.yaml entry #{index}: board and shield are required")

    artifact_name = entry.get("artifact-name") or f"{board}-{shield}"
    safe_name = re.sub(r"[^A-Za-z0-9._-]+", "-", str(artifact_name)).strip("-.")
    if not safe_name:
        raise SystemExit(f"Invalid artifact name in build.yaml entry #{index}")

    build_dir = repo / "build" / safe_name
    signature_path = build_dir / ".zmk-build-signature"
    signature = json.dumps(entry, sort_keys=True, separators=(",", ":"))
    reuse_configuration = (
        not clean_build
        and not updated_workspace
        and (build_dir / "CMakeCache.txt").is_file()
        and signature_path.is_file()
        and signature_path.read_text() == signature
    )

    if reuse_configuration:
        command = ["west", "build", "-d", str(build_dir)]
    else:
        command = ["west", "build"]

        if clean_build:
            command.append("--pristine=always")

        command.extend(
            [
                "-s",
                "zmk/app",
                "-d",
                str(build_dir),
                "-b",
                str(board),
            ]
        )

        snippet = entry.get("snippet")
        if snippet:
            command.extend(["-S", str(snippet)])

        command.extend(
            [
                "--",
                f"-DSHIELD={shield}",
                f"-DZMK_CONFIG={repo / 'config'}",
                f"-DZMK_EXTRA_MODULES={repo}",
            ]
        )

        cmake_args = entry.get("cmake-args")
        if cmake_args:
            command.extend(shlex.split(str(cmake_args)))

    print(f"\n==> [{index}/{len(entries)}] {artifact_name}", flush=True)
    print("+ " + shlex.join(command), flush=True)
    subprocess.run(command, cwd="/workspaces", check=True)
    signature_path.write_text(signature)

    zephyr_dir = build_dir / "zephyr"
    candidates = [zephyr_dir / "zmk.uf2", zephyr_dir / "zmk.bin"]
    source = next((path for path in candidates if path.is_file()), None)
    if source is None:
        expected = " or ".join(str(path) for path in candidates)
        raise SystemExit(f"Build succeeded but no firmware was found at {expected}")

    destination = firmware_dir / f"{safe_name}{source.suffix}"
    shutil.copy2(source, destination)
    built_artifacts.append(destination)

print("\n==> Firmware is ready:")
for artifact in built_artifacts:
    print(artifact)
PY
}

if [[ "${1:-}" == "--inside-container" ]]; then
    run_in_container
    exit 0
fi

update=0
clean=0
targets=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)
            update=1
            ;;
        --clean)
            clean=1
            ;;
        --left)
            targets+=(cornepad_left)
            ;;
        --right)
            targets+=(cornepad_right)
            ;;
        --dongle)
            targets+=(cornepad_dongle)
            ;;
        --reset)
            targets+=(settings_reset)
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./build-local.sh [--left] [--right] [--dongle] [--reset]
                        [--update] [--clean]

By default, reuse downloaded dependencies and build all targets incrementally.
Target flags can be combined to build any subset.

  --left    Build the left half.
  --right   Build the right half.
  --dongle  Build the dongle.
  --reset   Build the settings-reset firmware.
  --update  Update ZMK and all West modules before building.
  --clean   Discard cached build output and rebuild every target from scratch.
EOF
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

targets_csv=""
if [[ ${#targets[@]} -gt 0 ]]; then
    targets_csv="$(IFS=,; echo "${targets[*]}")"
fi

command -v docker >/dev/null 2>&1 || die "Docker is not installed"
docker info >/dev/null 2>&1 || die "Docker is not running or is not accessible"

docker volume create "$ZMK_WORKSPACE_VOLUME" >/dev/null

docker_args=(
    run
    --rm
    -v "$ZMK_WORKSPACE_VOLUME:/workspaces"
    -v "$REPO_ROOT:/workspaces/config"
    -w /workspaces
    -e "ZMK_UPDATE=$update"
    -e "ZMK_CLEAN=$clean"
    -e "ZMK_TARGETS=$targets_csv"
)

if [[ -t 0 && -t 1 ]]; then
    docker_args+=(-it)
fi

docker_args+=(
    "$ZMK_IMAGE"
    bash /workspaces/config/build-local.sh --inside-container
)

echo "==> Starting $ZMK_IMAGE"
docker "${docker_args[@]}"
