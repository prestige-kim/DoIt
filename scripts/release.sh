#!/bin/sh
# 로컬 후보만 준비한다. 커밋·설치·업로드·site 변경 없음.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
exec /usr/bin/python3 -B "$root/scripts/lib/release_tool.py" "$@"
