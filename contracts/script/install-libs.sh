#!/usr/bin/env bash
# Installs the pinned contract dependencies. CI and release builds both run this, so the
# tags live in exactly one place. Run from `contracts/`.
set -euo pipefail

FORGE_STD_TAG="v1.16.2"
OPENZEPPELIN_TAG="v5.3.0"

forge install "foundry-rs/forge-std@${FORGE_STD_TAG}" --no-git
forge install "OpenZeppelin/openzeppelin-contracts@${OPENZEPPELIN_TAG}" --no-git
