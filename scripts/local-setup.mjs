#!/usr/bin/env node
/**
 * One command from a fresh clone to a running local LaCrew org:
 *
 *   pnpm local           install, start Anvil, deploy a mock org, print next steps
 *   pnpm local:stop      stop the Anvil this script started
 *
 * Steps (each is skipped when already done, so it is safe to re-run):
 *   1. preflight   Node, pnpm, git, Foundry — a missing tool stops here with
 *                  the exact install command instead of a stack trace later
 *   2. install     `pnpm install`
 *   3. env         seed `.env` from `.env.example` (never overwrites)
 *   4. contracts   `forge install` the Solidity libs into contracts/lib
 *   5. build       protocol packages (the CLI and orchestrator need `dist/`)
 *   6. chain       start Anvil on :8545 in the background (log: .local/anvil.log)
 *   7. deploy      DeployMockOrg via the CLI, which writes the 31337 addresses,
 *                  then rebuild `@lacrew/core` so its `dist/` carries them
 *
 * No step needs a hand-edited file. Zero dependencies: it must run before
 * `pnpm install` has, on the Node that is already on the machine.
 */

import { spawn, spawnSync } from "node:child_process";
import {
  closeSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const stateDir = join(root, ".local");
const pidFile = join(stateDir, "anvil.pid");
const logFile = join(stateDir, "anvil.log");

const RPC = process.env.ANVIL_RPC || "http://127.0.0.1:8545";
const PORT = new URL(RPC).port || "8545";
const MIN_NODE = [22, 12];
const MIN_PNPM_MAJOR = 10;
const TOTAL = 7;

const say = (msg) => console.log(msg);
const step = (n, title) => console.log(`\n[${n}/${TOTAL}] ${title}`);

function fail(title, lines) {
  console.error(`\nerror: ${title}\n`);
  for (const line of lines) console.error(`  ${line}`);
  console.error("\nFix that and re-run `pnpm local` — it picks up where it stopped.");
  process.exit(1);
}

function run(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { cwd: root, encoding: "utf8", ...opts });
}

function has(cmd) {
  return run(cmd, ["--version"]).status === 0;
}

/** Run a visible command; on failure explain which step died and how to retry. */
function must(label, cmd, args, opts = {}) {
  const r = run(cmd, args, { stdio: "inherit", ...opts });
  if (r.status !== 0) {
    fail(`${label} failed (exit ${r.status ?? r.signal}).`, [
      `Command: ${cmd} ${args.join(" ")}${opts.cwd ? `   (in ${opts.cwd})` : ""}`,
      "The output above has the cause.",
    ]);
  }
}

async function rpcUp() {
  try {
    const res = await fetch(RPC, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
      signal: AbortSignal.timeout(1500),
    });
    const body = await res.json();
    return body.result ?? null;
  } catch {
    return null;
  }
}

function stop() {
  if (!existsSync(pidFile)) {
    say("No Anvil started by `pnpm local` is recorded (.local/anvil.pid).");
    return;
  }
  const pid = Number(readFileSync(pidFile, "utf8"));
  try {
    process.kill(pid);
    say(`Stopped Anvil (pid ${pid}).`);
  } catch {
    say(`Anvil (pid ${pid}) was not running.`);
  }
  rmSync(pidFile, { force: true });
}

// ---- 1. preflight ---------------------------------------------------------

function preflight() {
  step(1, "Checking prerequisites");
  const problems = [];

  const [maj, min] = process.versions.node.split(".").map(Number);
  if (maj < MIN_NODE[0] || (maj === MIN_NODE[0] && min < MIN_NODE[1])) {
    problems.push(
      `Node ${process.versions.node} is too old — LaCrew needs Node >= ${MIN_NODE.join(".")}.`,
      "  Install it:  nvm install 22 && nvm use 22   (or https://nodejs.org)",
    );
  }

  const pnpm = run("pnpm", ["--version"]);
  if (pnpm.status !== 0) {
    problems.push(
      "pnpm is not installed.",
      "  Install it:  corepack enable   (ships with Node)   or   npm i -g pnpm",
    );
  } else if (Number(pnpm.stdout.trim().split(".")[0]) < MIN_PNPM_MAJOR) {
    problems.push(
      `pnpm ${pnpm.stdout.trim()} is too old — need pnpm >= ${MIN_PNPM_MAJOR}.`,
      "  Update it:  corepack enable   (this repo pins its pnpm in package.json)   or   npm i -g pnpm",
    );
  }

  if (!has("git"))
    problems.push("git is not installed.  Install it: https://git-scm.com/downloads");

  for (const bin of ["forge", "anvil"]) {
    if (!has(bin)) {
      problems.push(
        `Foundry \`${bin}\` is not on your PATH.`,
        "  Install it:  curl -L https://foundry.paradigm.xyz | bash   then   foundryup",
        "  (then open a new terminal so PATH picks it up)",
      );
      break; // one message covers both
    }
  }

  if (problems.length) fail("prerequisites are missing.", problems);
  say(`  node ${process.versions.node}, pnpm ${pnpm.stdout.trim()}, forge + anvil found.`);
}

// ---- 2-5. deps, env, contracts, build ---------------------------------------

function prepare() {
  step(2, "Installing dependencies");
  must("Installing dependencies", "pnpm", ["install"]);

  step(3, "Seeding .env");
  const template = join(root, ".env.example");
  const env = join(root, ".env");
  if (existsSync(env)) {
    say("  .env already exists — left alone.");
  } else {
    copyFileSync(template, env);
    say(
      "  .env created from .env.example (Anvil demo keys, public — never use on a funded network).",
    );
  }

  step(4, "Installing Solidity libraries");
  const contracts = join(root, "contracts");
  const libs = [
    ["forge-std", "foundry-rs/forge-std", "lib/forge-std/src/Test.sol"],
    [
      "openzeppelin-contracts",
      "OpenZeppelin/openzeppelin-contracts@v5.3.0",
      "lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol",
    ],
  ];
  for (const [name, spec, probe] of libs) {
    if (existsSync(join(contracts, probe))) {
      say(`  ${name} already installed.`);
      continue;
    }
    must(`Installing ${name}`, "forge", ["install", spec, "--no-git"], { cwd: contracts });
  }

  step(5, "Building protocol packages");
  must("Building the packages", "pnpm", [
    "exec",
    "turbo",
    "run",
    "build",
    "--filter=@lacrew/cli...",
    "--filter=@lacrew/orchestrator...",
  ]);
}

// ---- 6-7. chain + deploy ----------------------------------------------------

async function chain() {
  step(6, "Starting a local chain (Anvil)");
  const existing = await rpcUp();
  if (existing) {
    const id = parseInt(existing, 16);
    if (id !== 31337) {
      fail(`${RPC} is not a local Anvil chain (chain id ${id}, expected 31337).`, [
        "Refusing to deploy a demo org there with the public Anvil key.",
        `Stop whatever owns port ${PORT}, or set ANVIL_RPC to another port.`,
      ]);
    }
    say(`  Something already answers on ${RPC} (chain id ${id}) — reusing it.`);
    return;
  }
  mkdirSync(stateDir, { recursive: true });
  const out = openSync(logFile, "a");
  const child = spawn("anvil", ["--port", PORT], {
    cwd: root,
    detached: true,
    stdio: ["ignore", out, out],
  });
  child.unref();
  closeSync(out);
  writeFileSync(pidFile, String(child.pid));
  for (let i = 0; i < 50; i += 1) {
    if (await rpcUp()) {
      say(`  Anvil is up on ${RPC} (pid ${child.pid}, log .local/anvil.log).`);
      return;
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  fail("Anvil did not start.", [
    `See .local/anvil.log. Most often port ${PORT} is taken: \`lsof -i :${PORT}\`.`,
  ]);
}

function deploy() {
  step(7, "Deploying a mock org");
  must("Deploying the mock org", "pnpm", [
    "--filter",
    "@lacrew/cli",
    "exec",
    "tsx",
    "src/index.ts",
    "deploy",
    "--anvil",
  ]);
  // The deploy rewrites core's generated address book; `dist/` is what the
  // orchestrator and CLI import, so it has to be rebuilt to see the new org.
  must("Rebuilding @lacrew/core with the deployed addresses", "pnpm", [
    "--filter",
    "@lacrew/core",
    "build",
  ]);
}

function nextSteps() {
  say(`
------------------------------------------------------------------------
LaCrew is set up locally: Anvil on ${RPC}, a mock org deployed.

Next (the Anvil keys in .env are public test keys — never use them on a
funded network):

  1. Start the orchestrator (:8788) and leave it running:
       pnpm dev

  2. In another terminal, trigger a spend above the worker's cap:
       curl -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:8788/tick
     See it pending (ESCALATE):
       curl http://127.0.0.1:8788/intents

  3. Approve it as the manager (escalation id 1 on a fresh chain):
       pnpm --filter @lacrew/cli exec tsx src/index.ts approve 1 --rpc ${RPC}
     The answer shows "verdict": "ALLOW".

Stop the chain later:  pnpm local:stop
------------------------------------------------------------------------`);
}

if (process.argv.includes("--stop")) {
  stop();
} else {
  preflight();
  prepare();
  await chain();
  deploy();
  nextSteps();
}
