#!/usr/bin/env bash
# Prints the toolchain facts a deployment record must carry so a verifier can rebuild the
# exact bytecode: forge version, solc and optimizer settings, dependency tags, git commit.
# Run from `contracts/` on a clean checkout of the release tag.
set -euo pipefail

forge_version="$(forge --version | head -1)"
tags="$(grep -E '^(FORGE_STD_TAG|OPENZEPPELIN_TAG)=' script/install-libs.sh | tr -d '"' | tr '\n' ' ')"
solc="$(awk -F'"' '/^solc_version/{print $2}' foundry.toml)"
runs="$(awk '/^optimizer_runs/{print $3}' foundry.toml)"
via_ir="$(awk '/^via_ir/{print $3}' foundry.toml)"
evm="$(awk -F'"' '/^evm_version/{print $2}' foundry.toml)"
dirty=false
[ -n "$(git status --porcelain)" ] && dirty=true

printf '{"forge":"%s","solc":"%s","optimizerRuns":%s,"viaIR":%s,"evmVersion":"%s","libs":"%s","commit":"%s","dirty":%s}\n' \
  "$forge_version" "$solc" "$runs" "$via_ir" "$evm" "${tags% }" "$(git rev-parse HEAD)" "$dirty"
