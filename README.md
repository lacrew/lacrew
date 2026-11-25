# LaCrew

**Protocol spec:** [SPEC.md](./SPEC.md) (v0.1 draft) — the normative interface surface, invariants, and conformance rules.

**Payroll, budgets, and approvals for AI agent teams.**

> Your agents. Their budgets. Your keys.

LaCrew is an open source protocol and platform for organizing AI agents the way you organize a company. Every agent is a node in an onchain org chart with its own smart account, a streaming allowance, and a policy that defines what it can do on its own.

## What's in this repo

| Path                    | Purpose                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------ |
| `contracts/`            | Solidity contracts (Foundry): OrgRegistry, Treasury, EscalationRouter, GovernanceModule, PolicyModules |
| `packages/core`         | Shared TypeScript types, ABIs, constants                                                               |
| `packages/sdk`          | Typed client for org state, intents, escalations, sessions                                             |
| `packages/db`           | Drizzle + Postgres (Neon or Docker)                                                                    |
| `packages/orchestrator` | Agent runtime: pg-boss queue, session keys, intent proposal                                            |
| `packages/adapters/*`   | Wallet and agent-framework adapters                                                                    |
| `apps/cli`              | Scaffold an org, run a crew locally, self-host                                                         |
| `apps/docs`             | Protocol docs — Fumadocs, published at [lacrew.github.io/lacrew](https://lacrew.github.io/lacrew/)     |
| `examples/`             | Starter crew templates                                                                                 |

The hosted cloud (`lacrew.xyz`) is a separate private repo. It depends on these packages; it does not fork them.

## Status

Phase 0 — scaffolding and spec. Contracts and packages contain mock / stub implementations marked clearly. Do not use with real funds.

## Prerequisites

| Tool    | Version                                 | Check             |
| ------- | --------------------------------------- | ----------------- |
| Node.js | 22 or newer (CI runs 26)                | `node -v`         |
| pnpm    | 12.23.0, as pinned in `package.json`    | `pnpm -v`         |
| Foundry | any recent release; the Anvil loop only | `anvil --version` |

Run `corepack enable` once so `pnpm` resolves to the pinned version. Another
pnpm will reinstall `node_modules` and rewrite `pnpm-lock.yaml` on the next run.
Install Foundry with [foundryup](https://book.getfoundry.sh/getting-started/installation).
Docker is not needed for this quickstart; only `pnpm db:up` (a local Postgres) uses it.

## Quickstart

### One command

Needs Node >= 22.12, pnpm, git and [Foundry](https://book.getfoundry.sh/getting-started/installation); it checks them first and prints the exact install command for any that is missing.

```bash
pnpm local
```

`pnpm local` installs dependencies, seeds `.env` from `.env.example` (never overwriting), installs the Solidity libraries, builds, starts Anvil in the background (pid and log under the git-ignored `.local/`), and deploys the mock org. It is safe to re-run. When it finishes it prints the next steps: start the orchestrator with `pnpm dev`, then

```bash
curl -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:8788/tick   # → "verdict": "ESCALATE"
pnpm --filter @lacrew/cli exec tsx src/index.ts approve 1 --rpc http://127.0.0.1:8545   # → "verdict": "ALLOW"
```

If a command fails, the CLI ends with a `Stuck? Tell us` link that opens a prefilled issue (secrets and RPC URL paths are redacted); set `LACREW_NO_STUCK_LINK=1` to hide it.

Stop the chain with `pnpm local:stop`. The Anvil keys in `.env` are public test keys: never use them on a funded network.

### By hand

```bash
pnpm install
pnpm build

# Sandbox orchestrator (simulated, no chain required) — http://127.0.0.1:8788
pnpm dev:sandbox
```

`pnpm dev` alone starts the orchestrator in chain mode: without `ANVIL_RPC` +
`PRIVATE_KEY` it answers `mode: "unavailable"` on `/health` and 503 on every
data route. Use `pnpm dev:sandbox` to try it without a chain, or the Anvil
loop below for onchain enforcement.

### Optional Anvil loop (indexer / onchain SDK)

`pnpm dev` does **not** start a blockchain. For onchain escalate → approve (USDC spend):

> **Stop any earlier `pnpm dev` / `pnpm dev:sandbox` first.** Only one orchestrator can
> hold `:8788`; a leftover one keeps answering while the new one fails with `EADDRINUSE`.
> Check with `lsof -i :8788`, and confirm `curl http://127.0.0.1:8788/health` reports
> `"mode":"onchain"` once Terminal C is up.

```bash
# Terminal A — local chain
anvil

# Terminal B — deploy reference org (manager = Anvil account #1) + sync addresses
pnpm --filter @lacrew/cli exec tsx src/index.ts deploy --anvil

# Terminal C — orchestrator in onchain mode
# PRIVATE_KEY = Anvil #0 (deployer / propose)
# MANAGER_PRIVATE_KEY = Anvil #1 (resolve) — see .env.example
export ANVIL_RPC=http://127.0.0.1:8545 CHAIN_ID=31337
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export MANAGER_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
pnpm --filter @lacrew/orchestrator dev
curl -X POST -H 'content-type: application/json' -d '{}' http://127.0.0.1:8788/tick
# (the content-type header is required: without it /tick answers 415 content_type_must_be_json)
# → {"intentId":"1","verdict":"ESCALATE", ...}

# Terminal D — approve it as the manager (signs EscalationRouter.resolve)
export MANAGER_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
pnpm --filter @lacrew/cli exec tsx src/index.ts approve 1 --rpc http://127.0.0.1:8545
# → "resolved": true, "approved": true, "verdict": "ALLOW", plus a txHash;
#   75 USDC (75000000) lands on x402Target. Replace `1` with the intentId from /tick.
# Optional hosted UI: Approvals at lacrew.xyz does the same thing.

# Terminal D (again) — a spend within the cap: propose 30 USDC from the CLI.
# <worker> and <x402Target> are in apps/cli/.lacrew/deployments-31337.json (written by deploy).
pnpm --filter @lacrew/cli exec tsx src/index.ts propose <worker> <x402Target> 30000000 --rpc http://127.0.0.1:8545
# → {"sessionId":"2", "keyAddress":"0x…", "maxValue":"200000000", "allowedTarget":"0x…",
#    "intentId":"0", "verdict":"ALLOW", "txHash":"0x…"}
#   ALLOW: it paid out at once, no approval step.
#   Units: USDC has 6 decimals, so 30000000 = 30 USDC (and /tick's 75000000 = 75 USDC).
#   The cap is 50 USDC here: read it at GET /org (the worker's "allowance.cap": "50000000").
#   List intents and their ids: curl http://127.0.0.1:8788/intents
#   (it lists intents still waiting on a human, e.g. the one /tick escalates; settled ones are not shown).

# Terminal E — event indexer (optional)
pnpm dev:indexer
```

Without `ANVIL_RPC` + `PRIVATE_KEY` (and without `LACREW_MODE=sandbox`), the orchestrator reports `mode: "unavailable"` and answers 503.

See [apps/docs/content/self-host.md](./apps/docs/content/self-host.md) for the full loop.

## License

Apache-2.0 — see [LICENSE](./LICENSE).
