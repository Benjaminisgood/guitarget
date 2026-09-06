#!/bin/sh
set -eu

convertor_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$convertor_dir/.." && pwd)
build_dir="$convertor_dir/.build"
output="$build_dir/validate"
temporary="$output.tmp.$$"

mkdir -p "$build_dir"
trap 'rm -f "$temporary"' 0 1 2 15
xcrun swiftc -O -module-name GuitargetValidator \
    -module-cache-path "$build_dir/ModuleCache" \
    "$project_dir/Sources/GuitarCore/ScoreTypes.swift" \
    "$project_dir/Sources/GuitarCore/ScoreEngine.swift" \
    "$convertor_dir/validate.swift" \
    -o "$temporary"
mv -f "$temporary" "$output"
trap - 0 1 2 15
printf '%s\n' "$output"
