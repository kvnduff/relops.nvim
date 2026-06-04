#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
nvim --headless -u NONE -i NONE -n -l tests/relops_spec.lua
