#!/usr/bin/env node
/**
 * Publish step of docs/deployment-plan.md §5: turn the forge broadcast receipts of
 * DeployOrg and DeployProtocol into contracts/deployments/<chainId>.json.
 *
 *   node scripts/write-deployment-record.mjs <chainId> [--build-record <file>]
 *
 * Reads contracts/broadcast/{DeployOrg,DeployProtocol}.s.sol/<chainId>/run-latest.json.
 * The file holds public data only: addresses, tx hashes, block numbers, the git commit
 * and the toolchain record. The keys of `ChainAddresses` (packages/core/src/types.ts)
 * come first so `sync-abis` can read the same file.
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const contracts = join(dirname(fileURLToPath(import.meta.url)), "..", "contracts");

const [chainArg, ...rest] = process.argv.slice(2);
const chainId = Number(chainArg);
if (!Number.isInteger(chainId) || chainId <= 0) {
  console.error("usage: write-deployment-record.mjs <chainId> [--build-record <file>]");
  process.exit(2);
}
const recordFlag = rest.indexOf("--build-record");
const build = recordFlag >= 0 ? JSON.parse(readFileSync(rest[recordFlag + 1], "utf8")) : undefined;

function receipt(script) {
  const file = join(contracts, "broadcast", `${script}.s.sol`, String(chainId), "run-latest.json");
  if (!existsSync(file)) throw new Error(`missing broadcast receipt ${file}`);
  return JSON.parse(readFileSync(file, "utf8"));
}

/** First CREATE per contract name, plus every create tx for the record. */
function creations(run) {
  const byName = {};
  const txs = [];
  const blockOf = new Map(
    (run.receipts ?? []).map((r) => [r.transactionHash, Number(r.blockNumber)]),
  );
  for (const tx of run.transactions) {
    if (tx.transactionType !== "CREATE" || !tx.contractName) continue;
    byName[tx.contractName] ??= tx.contractAddress;
    txs.push({
      contract: tx.contractName,
      address: tx.contractAddress,
      txHash: tx.hash,
      block: blockOf.get(tx.hash),
    });
  }
  return { byName, txs };
}

const org = creations(receipt("DeployOrg"));
const proto = creations(receipt("DeployProtocol"));

const need = (set, name) => {
  if (!set.byName[name]) throw new Error(`broadcast receipt has no ${name} creation`);
  return set.byName[name];
};

const record = {
  chainId,
  orgRegistry: need(org, "OrgRegistry"),
  treasury: need(org, "Treasury"),
  escalationRouter: need(org, "EscalationRouter"),
  governanceModule: need(org, "GovernanceModule"),
  spendCapPolicy: need(org, "SpendCapPolicy"),
  mockUSDC: org.byName.MockUSDC,
  policyStack: need(org, "PolicyStack"),
  whitelistPolicy: need(org, "WhitelistPolicy"),
  timeWindowPolicy: need(org, "TimeWindowPolicy"),
  rateLimitPolicy: need(org, "RateLimitPolicy"),
  epochStreamer: need(org, "EpochStreamer"),
  sessionRegistry: need(org, "SessionRegistry"),
  marketplacePayments: need(proto, "MarketplacePayments"),
  humanRoot: (receipt("DeployOrg").transactions[0].transaction?.from ?? "").toString(),
  deployment: {
    commit: build?.commit,
    toolchain: build,
    transactions: [...org.txs, ...proto.txs],
  },
};
if (!record.mockUSDC) delete record.mockUSDC;
if (!record.humanRoot) delete record.humanRoot;

const dir = join(contracts, "deployments");
mkdirSync(dir, { recursive: true });
const out = join(dir, `${chainId}.json`);
writeFileSync(out, `${JSON.stringify(record, null, 2)}\n`);
console.log(`wrote ${out}`);
