/**
 * `deployOrg` with a marketplace hands MarketplacePayments to the GovernanceModule
 * like every other contract: afterwards the human root can no longer use its
 * governor-only setters. The simulator does not model MarketplacePayments, so this
 * runs against the real contracts only (it needs `anvil`, like the conformance run).
 */

import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { createPublicClient, createWalletClient, http, type Address } from "viem";
import { foundry } from "viem/chains";
import { marketplacePaymentsAbi } from "@lacrew/core";
import { deployOrg } from "@lacrew/sdk";

import { findAnvil } from "./anvilDriver.js";

const binary = findAnvil();
const required = Boolean(process.env.CONFORMANCE_REQUIRE_ANVIL);

if (!binary && required) {
  it("finds anvil", () => {
    assert.fail("CONFORMANCE_REQUIRE_ANVIL is set but no anvil binary was found");
  });
}

const ROOT = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as Address;
const FEE_TO = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as Address;

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const a = server.address();
      const port = typeof a === "object" && a ? a.port : 0;
      server.close(() => resolve(port));
    });
  });
}

describe("deployOrg: marketplace governor handover", { skip: !binary }, () => {
  let child: ChildProcess;
  let url: string;

  before(async () => {
    const port = await freePort();
    child = spawn(binary!, ["--port", String(port), "--auto-impersonate", "--silent"], {
      stdio: "ignore",
    });
    url = `http://127.0.0.1:${port}`;
    const probe = createPublicClient({ transport: http(url), chain: foundry });
    for (let i = 0; ; i++) {
      try {
        await probe.getChainId();
        return;
      } catch (err) {
        if (i > 100 || child.exitCode !== null) throw new Error(`anvil did not start: ${err}`);
        await new Promise((r) => setTimeout(r, 50));
      }
    }
  });
  after(() => {
    child?.kill();
  });

  it("leaves the root with none of MarketplacePayments' governor-only setters", async () => {
    const transport = http(url);
    const deployed = await deployOrg({
      transport,
      chain: foundry,
      account: ROOT,
      pollingInterval: 20,
      marketplace: { feeRecipient: FEE_TO },
    });
    const market = deployed.addresses.marketplacePayments!;
    const gov = deployed.addresses.governanceModule;
    const publicClient = createPublicClient({ transport, chain: foundry });
    const wallet = createWalletClient({ transport, chain: foundry, account: ROOT });

    const governor = await publicClient.readContract({
      address: market,
      abi: marketplacePaymentsAbi,
      functionName: "governor",
    });
    assert.equal(governor.toLowerCase(), gov.toLowerCase());

    const attempts = [
      { functionName: "setFeeBps", args: [100] },
      { functionName: "setFeeRecipient", args: [ROOT] },
      { functionName: "setSettlementRouter", args: [ROOT] },
      { functionName: "sweepUnallocated", args: [ROOT] },
      { functionName: "setPendingGovernor", args: [ROOT] },
      { functionName: "acceptGovernor", args: [] },
    ] as const;
    for (const attempt of attempts) {
      await assert.rejects(
        publicClient.simulateContract({
          address: market,
          abi: marketplacePaymentsAbi,
          account: wallet.account,
          ...attempt,
        } as never),
        attempt.functionName === "acceptGovernor" ? /NotPendingGovernor/ : /NotGovernor/,
        attempt.functionName,
      );
    }
  });

  it("keeps the root as governor when bindGovernor is false", async () => {
    const transport = http(url);
    const deployed = await deployOrg({
      transport,
      chain: foundry,
      account: ROOT,
      pollingInterval: 20,
      bindGovernor: false,
      marketplace: {},
    });
    const publicClient = createPublicClient({ transport, chain: foundry });
    assert.equal(
      await publicClient.readContract({
        address: deployed.addresses.marketplacePayments!,
        abi: marketplacePaymentsAbi,
        functionName: "governor",
      }),
      ROOT,
    );
  });
});
