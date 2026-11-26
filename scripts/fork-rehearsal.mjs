#!/usr/bin/env node
/**
 * Stage 0 of docs/deployment-plan.md: rehearse the release deploy against local
 * Anvil forks of the public testnets, then prove the post-deploy state.
 *
 *   pnpm rehearse:fork                   Ethereum Sepolia and Base Sepolia
 *   pnpm rehearse:fork -- sepolia        one chain (sepolia | base-sepolia)
 *
 * Per chain it forks the testnet into a throwaway Anvil, funds a freshly
 * generated key on the fork (no real key, nothing is broadcast to the public
 * chain), runs the real DeployOrg and DeployProtocol scripts with --broadcast,
 * and then re-reads the chain with `cast` independently of the script's own
 * post-conditions: owners and governor on every contract, the wiring between
 * Treasury / EscalationRouter / registries / policies, and that the bootstrap
 * deployer can no longer call any bootstrap setter.
 *
 * Env: SEPOLIA_FORK_URL, BASE_SEPOLIA_FORK_URL (public RPCs by default),
 *      REHEARSAL_PORT (first Anvil port, default 8645).
 * Needs Foundry (forge, cast, anvil) and `contracts/lib` (script/install-libs.sh).
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const contracts = join(dirname(fileURLToPath(import.meta.url)), "..", "contracts");

const CHAINS = {
  sepolia: {
    name: "Ethereum Sepolia",
    id: 11155111,
    url: process.env.SEPOLIA_FORK_URL || "https://ethereum-sepolia-rpc.publicnode.com",
  },
  "base-sepolia": {
    name: "Base Sepolia",
    id: 84532,
    url: process.env.BASE_SEPOLIA_FORK_URL || "https://sepolia.base.org",
  },
};

const ZERO = "0x0000000000000000000000000000000000000000";
const SPEND_CAP = "50000000";
const sh = (cmd, args, opts = {}) =>
  spawnSync(cmd, args, { cwd: contracts, encoding: "utf8", ...opts });

function cast(args, from) {
  const r = sh("cast", from ? [...args, "--from", from] : args);
  if (r.status !== 0) throw new Error(`cast ${args.join(" ")}: ${(r.stderr || "").trim()}`);
  return r.stdout.trim();
}
const lc = (s) => String(s).toLowerCase();
const addr = (a, sig) => lc(cast(["call", a, sig, "--rpc-url", rpc]));
let rpc = "";

async function waitForRpc(url) {
  for (let i = 0; i < 120; i++) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}',
      });
      if (res.ok) return;
    } catch {
      /* not up yet */
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`anvil did not come up at ${url} (is the fork RPC reachable?)`);
}

function deploy(script, env, key) {
  const r = sh(
    "forge",
    [
      "script",
      `script/${script}.s.sol:${script}`,
      "--rpc-url",
      rpc,
      "--private-key",
      key,
      "--broadcast",
      "--slow",
    ],
    { env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] },
  );
  if (r.status !== 0) throw new Error(`${script} failed:\n${r.stdout}\n${r.stderr}`);
  const run = JSON.parse(
    readFileSync(
      join(contracts, "broadcast", `${script}.s.sol`, String(env.CHAIN), "run-latest.json"),
      "utf8",
    ),
  );
  const out = {};
  for (const tx of run.transactions) {
    if (tx.transactionType === "CREATE" && tx.contractName)
      out[tx.contractName] ??= tx.contractAddress;
  }
  return out;
}

async function rehearse(chain) {
  const port = Number(process.env.REHEARSAL_PORT || 8645) + (chain.id === 84532 ? 1 : 0);
  rpc = `http://127.0.0.1:${port}`;
  const anvil = spawn("anvil", ["--fork-url", chain.url, "--port", String(port), "--silent"], {
    stdio: "ignore",
  });
  const failures = [];
  const check = (ok, what) => {
    console.log(`  ${ok ? "ok  " : "FAIL"} ${what}`);
    if (!ok) failures.push(`${chain.name}: ${what}`);
  };
  try {
    await waitForRpc(rpc);
    check(
      Number(cast(["chain-id", "--rpc-url", rpc])) === chain.id,
      `fork reports chain id ${chain.id}`,
    );

    const wallet = () => JSON.parse(cast(["wallet", "new", "--json"])).data[0];
    const deployer = wallet();
    const governor = wallet();
    const feeRecipient = wallet();
    for (const w of [deployer, governor, feeRecipient]) {
      cast(["rpc", "anvil_setBalance", w.address, "0x56BC75E2D63100000", "--rpc-url", rpc]);
    }

    console.log(`\n${chain.name} fork: DeployOrg`);
    const org = deploy(
      "DeployOrg",
      {
        CHAIN: String(chain.id),
        HUMAN_ROOT: deployer.address,
        DEPLOY_MOCK_ASSET: "true",
        DEFAULT_SPEND_CAP: SPEND_CAP,
      },
      deployer.private_key,
    );
    console.log(`\n${chain.name} fork: DeployProtocol`);
    const proto = deploy(
      "DeployProtocol",
      {
        CHAIN: String(chain.id),
        MARKETPLACE_GOVERNOR: governor.address,
        PLATFORM_FEE_RECIPIENT: feeRecipient.address,
        DEPLOY_MOCK_ASSET: "true",
      },
      deployer.private_key,
    );

    const d = lc(deployer.address);
    const gov = lc(org.GovernanceModule);
    console.log(`\n${chain.name} fork: post-deploy state`);
    for (const [n, a] of Object.entries({ ...org, ...proto })) {
      check(cast(["code", a, "--rpc-url", rpc]).length > 4, `${n} has code`);
    }

    // Owners and governor.
    check(addr(org.OrgRegistry, "root()(address)") === d, "OrgRegistry.root is the human root");
    check(
      addr(org.GovernanceModule, "humanRoot()(address)") === d,
      "GovernanceModule.humanRoot is the human root",
    );
    check(
      addr(org.SessionRegistry, "humanRoot()(address)") === d,
      "SessionRegistry.humanRoot is the human root",
    );
    for (const n of [
      "OrgRegistry",
      "SessionRegistry",
      "Treasury",
      "EscalationRouter",
      "EpochStreamer",
      "WhitelistPolicy",
      "SpendCapPolicy",
    ]) {
      check(addr(org[n], "governor()(address)") === gov, `${n}.governor is the GovernanceModule`);
    }
    check(
      addr(proto.MarketplacePayments, "governor()(address)") === lc(governor.address),
      "MarketplacePayments.governor is the explicit governor",
    );
    check(
      addr(proto.MarketplacePayments, "feeRecipient()(address)") === lc(feeRecipient.address),
      "MarketplacePayments.feeRecipient is the explicit recipient",
    );

    // No leftover bootstrap admin.
    check(addr(org.WhitelistPolicy, "admin()(address)") === ZERO, "WhitelistPolicy.admin is zero");
    check(addr(org.SpendCapPolicy, "admin()(address)") === ZERO, "SpendCapPolicy.admin is zero");
    check(
      cast(["call", org.RateLimitPolicy, "recorderLocked()(bool)", "--rpc-url", rpc]) === "true",
      "RateLimitPolicy recorder is locked",
    );

    // Wiring.
    check(
      addr(org.Treasury, "spender()(address)") === lc(org.EscalationRouter),
      "Treasury.spender is the EscalationRouter",
    );
    check(
      addr(org.Treasury, "streamer()(address)") === lc(org.EpochStreamer),
      "Treasury.streamer is the EpochStreamer",
    );
    check(
      addr(org.Treasury, "token()(address)") === lc(org.MockUSDC),
      "Treasury.token is the asset",
    );
    check(
      addr(org.EscalationRouter, "treasury()(address)") === lc(org.Treasury),
      "EscalationRouter.treasury is the Treasury",
    );
    check(
      addr(org.EscalationRouter, "rateRecorder()(address)") === lc(org.RateLimitPolicy),
      "EscalationRouter.rateRecorder is the RateLimitPolicy",
    );
    check(
      addr(org.EscalationRouter, "sessionRegistry()(address)") === lc(org.SessionRegistry),
      "EscalationRouter.sessionRegistry is the SessionRegistry",
    );
    check(
      addr(org.RateLimitPolicy, "recorder()(address)") === lc(org.EscalationRouter),
      "RateLimitPolicy.recorder is the EscalationRouter",
    );
    check(
      addr(org.SessionRegistry, "escalationRouter()(address)") === lc(org.EscalationRouter),
      "SessionRegistry.escalationRouter is the EscalationRouter",
    );
    check(
      addr(proto.MarketplacePayments, "token()(address)") === lc(proto.MockUSDC),
      "MarketplacePayments.token is the asset",
    );

    // The deployer must be refused by every bootstrap setter. `cast call --from`
    // simulates the call, so a revert means the authority is gone.
    const other = feeRecipient.address;
    const bootstrap = [
      [org.OrgRegistry, "setGovernor(address)", other],
      [org.SessionRegistry, "setGovernor(address)", other],
      [org.Treasury, "setGovernor(address)", other],
      [org.Treasury, "setStreamer(address)", other],
      [org.EscalationRouter, "setGovernor(address)", other],
      [org.EscalationRouter, "setTreasury(address)", other],
      [org.WhitelistPolicy, "setAllowed(address,bool)", other, "true"],
      [org.SpendCapPolicy, "setAgentCap(address,uint256)", other, "1"],
      [org.RateLimitPolicy, "setRecorder(address)", other],
    ];
    for (const [target, sig, ...args] of bootstrap) {
      const r = sh("cast", [
        "call",
        target,
        sig,
        ...args,
        "--rpc-url",
        rpc,
        "--from",
        deployer.address,
      ]);
      check(
        r.status !== 0,
        `deployer is refused by ${sig} on ${[...Object.entries({ ...org, ...proto })].find(([, a]) => a === target)[0]}`,
      );
    }
    const fromOther = sh("cast", [
      "call",
      proto.MarketplacePayments,
      "setGovernor(address)",
      other,
      "--rpc-url",
      rpc,
      "--from",
      deployer.address,
    ]);
    check(
      fromOther.status !== 0,
      "deployer is refused by setGovernor(address) on MarketplacePayments",
    );
  } finally {
    anvil.kill();
  }
  return failures;
}

function main() {
  for (const tool of ["forge", "cast", "anvil"]) {
    if (sh(tool, ["--version"]).status !== 0) {
      console.error(`error: ${tool} not found; install Foundry (https://getfoundry.sh).`);
      process.exit(1);
    }
  }
  if (!existsSync(join(contracts, "lib", "forge-std"))) {
    console.error(
      "error: contracts/lib is missing; run `bash script/install-libs.sh` in contracts/.",
    );
    process.exit(1);
  }
  const wanted = process.argv.slice(2).filter((a) => a !== "--");
  const picked = wanted.length ? wanted : Object.keys(CHAINS);
  for (const k of picked) {
    if (!CHAINS[k]) {
      console.error(`error: unknown chain "${k}" (use ${Object.keys(CHAINS).join(" | ")})`);
      process.exit(1);
    }
  }
  return picked;
}

const picked = main();
const all = [];
for (const k of picked) {
  try {
    all.push(...(await rehearse(CHAINS[k])));
  } catch (e) {
    all.push(`${CHAINS[k].name}: ${e.message}`);
  }
}
if (all.length) {
  console.error(`\nRehearsal failed:\n${all.map((f) => `  - ${f}`).join("\n")}`);
  process.exit(1);
}
console.log(`\nRehearsal passed on ${picked.map((k) => CHAINS[k].name).join(" and ")}.`);
