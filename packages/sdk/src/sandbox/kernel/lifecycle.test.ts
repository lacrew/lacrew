import { describe, it } from "node:test";
import assert from "node:assert/strict";

import * as epochStreamer from "./epochStreamer.js";
import * as escalationRouter from "./escalationRouter.js";
import * as orgRegistry from "./orgRegistry.js";
import { NodeKind } from "./orgRegistry.js";
import * as sessionRegistry from "./sessionRegistry.js";
import { SCOPE_ALL } from "./sessionRegistry.js";
import {
  KEY,
  MANAGER,
  ROOT,
  SECOND_HUMAN,
  STRANGER,
  TARGET,
  USDC,
  WORKER,
  bootstrapOrg,
  crewOrg,
  type Sim,
} from "./testkit.test.js";
import * as treasury from "./treasury.js";
import type { Ctx } from "./world.js";

const DAY = 86_400n;
const HOUR = 3_600n;

const propose = (value: bigint) => (ctx: Ctx) =>
  escalationRouter.propose(ctx, WORKER, TARGET, value, "0x");
const ttlOf = (sim: Sim) => sim.read((ctx) => escalationRouter.intentTtl(ctx));

const generation = (sim: Sim, account: `0x${string}`) =>
  sim.read((ctx) => orgRegistry.generationOf(ctx, account));

function readd(sim: Sim, account: `0x${string}`, kind: number, parent: `0x${string}`): void {
  sim.send(ROOT, (ctx) => orgRegistry.removeNode(ctx, account));
  sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, account, kind, parent));
}

describe("kernel OrgRegistry generations", () => {
  it("starts the root at 1, counts every addNode, and keeps the count through a removal", () => {
    const sim = bootstrapOrg();
    assert.equal(generation(sim, ROOT), 1n);
    assert.equal(generation(sim, MANAGER), 0n);
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, MANAGER, NodeKind.ManagerAgent, ROOT));
    assert.equal(generation(sim, MANAGER), 1n);
    sim.send(ROOT, (ctx) => orgRegistry.removeNode(ctx, MANAGER));
    assert.equal(generation(sim, MANAGER), 1n);
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, MANAGER, NodeKind.ManagerAgent, ROOT));
    assert.equal(generation(sim, MANAGER), 2n);
  });

  it("bumps a fresh root on rotation but not a promoted HumanRoot child", () => {
    const sim = bootstrapOrg();
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, SECOND_HUMAN, NodeKind.HumanRoot, ROOT));
    assert.equal(generation(sim, SECOND_HUMAN), 1n);
    sim.send(ROOT, (ctx) => orgRegistry.rotateRoot(ctx, SECOND_HUMAN));
    assert.equal(generation(sim, SECOND_HUMAN), 1n);
    // The old root is gone; rotating back to it makes it a fresh root.
    sim.send(SECOND_HUMAN, (ctx) => orgRegistry.rotateRoot(ctx, ROOT));
    assert.equal(generation(sim, ROOT), 2n);
    assert.equal(generation(sim, SECOND_HUMAN), 1n);
  });
});

describe("kernel EscalationRouter intent expiry", () => {
  it("defaults to seven days and records the lifetime and generations on each intent", () => {
    const sim = crewOrg();
    assert.equal(ttlOf(sim), 7n * DAY);
    sim.send(WORKER, propose(75n * USDC));
    const life = sim.read((ctx) => escalationRouter.intentLife(ctx, 1n));
    assert.deepEqual(life, {
      expiresAt: sim.now + 7n * DAY,
      agentGeneration: 1n,
      approverGeneration: 1n,
    });
    assert.deepEqual(
      sim.read((ctx) => escalationRouter.intentLife(ctx, 99n)),
      { expiresAt: 0n, agentGeneration: 0n, approverGeneration: 0n },
    );
  });

  it("bounds the lifetime, gates it on the authority, and applies it to new intents only", () => {
    const sim = crewOrg();
    sim.send(WORKER, propose(75n * USDC));
    sim.reverts("NotAuthorized", STRANGER, (ctx) => escalationRouter.setIntentTtl(ctx, HOUR));
    sim.reverts("InvalidIntentTtl", ROOT, (ctx) => escalationRouter.setIntentTtl(ctx, HOUR - 1n));
    sim.reverts("InvalidIntentTtl", ROOT, (ctx) =>
      escalationRouter.setIntentTtl(ctx, 365n * DAY + 1n),
    );
    sim.send(ROOT, (ctx) => escalationRouter.setIntentTtl(ctx, 365n * DAY));
    sim.send(ROOT, (ctx) => escalationRouter.setIntentTtl(ctx, HOUR));
    assert.equal(ttlOf(sim), HOUR);
    assert.equal(sim.lastEvent("IntentTtlUpdated").args.intentTtl, HOUR);
    sim.send(WORKER, propose(76n * USDC));
    assert.equal(sim.read((ctx) => escalationRouter.intentLife(ctx, 2n)).expiresAt - sim.now, HOUR);
    assert.equal(
      sim.read((ctx) => escalationRouter.intentLife(ctx, 1n)).expiresAt - sim.now,
      7n * DAY,
    );
  });

  it("refuses resolve once expired, and lets anyone close it exactly then", () => {
    const sim = crewOrg();
    sim.send(WORKER, propose(75n * USDC));
    sim.warp(7n * DAY - 1n);
    sim.reverts("IntentNotExpired", STRANGER, (ctx) => escalationRouter.closeExpired(ctx, 1n));
    sim.warp(1n);
    sim.reverts("IntentHasExpired", MANAGER, (ctx) => escalationRouter.resolve(ctx, 1n, true));
    sim.reverts("IntentHasExpired", ROOT, (ctx) => escalationRouter.resolve(ctx, 1n, false));
    sim.send(STRANGER, (ctx) => escalationRouter.closeExpired(ctx, 1n));
    assert.deepEqual(sim.eventNames().slice(-2), ["IntentExpired", "IntentResolved"]);
    assert.equal(sim.lastEvent("IntentExpired").args.closedBy, STRANGER);
    assert.equal(sim.read((ctx) => escalationRouter.intents(ctx, 1n)).approved, false);
    assert.equal(sim.read((ctx) => escalationRouter.intents(ctx, 1n)).resolved, true);
    sim.reverts("IntentAlreadyResolved", STRANGER, (ctx) => escalationRouter.closeExpired(ctx, 1n));
    sim.reverts("IntentNotFound", STRANGER, (ctx) => escalationRouter.closeExpired(ctx, 9n));
  });

  it("treats an agent or approver of another generation as inactive", () => {
    const sim = crewOrg();
    sim.send(WORKER, propose(75n * USDC));
    sim.send(WORKER, propose(76n * USDC));
    readd(sim, WORKER, NodeKind.WorkerAgent, MANAGER);
    sim.reverts("InactiveAgent", MANAGER, (ctx) => escalationRouter.resolve(ctx, 1n, true));
    sim.send(MANAGER, (ctx) => escalationRouter.resolve(ctx, 1n, false));

    readd(sim, MANAGER, NodeKind.ManagerAgent, ROOT);
    sim.reverts("InactiveApprover", MANAGER, (ctx) => escalationRouter.resolve(ctx, 2n, false));
    sim.reverts("NotAwaitingApprover", STRANGER, (ctx) => escalationRouter.resolve(ctx, 2n, false));
    sim.send(ROOT, (ctx) => escalationRouter.resolve(ctx, 2n, false));
  });
});

describe("kernel SessionRegistry across generations", () => {
  it("records the agent's generation and drops the key when the agent is added again", () => {
    const sim = crewOrg();
    sim.send(ROOT, (ctx) =>
      sessionRegistry.issue(ctx, WORKER, KEY, sim.now + DAY, SCOPE_ALL, 100n * USDC, TARGET),
    );
    assert.equal(
      sim.read((ctx) => sessionRegistry.agentGenerationOf(ctx, 1n)),
      1n,
    );
    assert.equal(
      sim.read((ctx) => sessionRegistry.isValid(ctx, 1n)),
      true,
    );
    readd(sim, WORKER, NodeKind.WorkerAgent, MANAGER);
    assert.equal(
      sim.read((ctx) => sessionRegistry.isValid(ctx, 1n)),
      false,
    );
    assert.equal(
      sim.read((ctx) => sessionRegistry.isKeyValid(ctx, WORKER, KEY)),
      false,
    );
    assert.equal(sim.read((ctx) => sessionRegistry.keyLimits(ctx, WORKER, KEY)).valid, false);
    sim.send(ROOT, (ctx) =>
      sessionRegistry.issue(ctx, WORKER, KEY, sim.now + DAY, SCOPE_ALL, 100n * USDC, TARGET),
    );
    assert.equal(
      sim.read((ctx) => sessionRegistry.agentGenerationOf(ctx, 2n)),
      2n,
    );
    assert.equal(
      sim.read((ctx) => sessionRegistry.isKeyValid(ctx, WORKER, KEY)),
      true,
    );
  });
});

describe("kernel Treasury allowance generations", () => {
  it("binds an empty allowance to the current generation and refuses a stale one", () => {
    const sim = crewOrg();
    assert.equal(
      sim.read((ctx) => treasury.allowanceGeneration(ctx, WORKER)),
      1n,
    );
    readd(sim, WORKER, NodeKind.WorkerAgent, MANAGER);
    sim.reverts("StaleAllowance", ROOT, (ctx) => epochStreamer.runNextEpoch(ctx));
    sim.reverts("StaleAllowance", WORKER, propose(1n));
  });

  it("clears the generation only when a revoke empties the allowance", () => {
    const sim = crewOrg();
    readd(sim, WORKER, NodeKind.WorkerAgent, MANAGER);
    sim.reverts("NotAuthorized", STRANGER, (ctx) => treasury.revokeAllowance(ctx, WORKER, 1n));
    sim.reverts("InsufficientAllowance", ROOT, (ctx) =>
      treasury.revokeAllowance(ctx, WORKER, 200n * USDC + 1n),
    );
    sim.send(ROOT, (ctx) => treasury.revokeAllowance(ctx, WORKER, 150n * USDC));
    assert.equal(
      sim.read((ctx) => treasury.allowanceGeneration(ctx, WORKER)),
      1n,
    );
    sim.reverts("StaleAllowance", ROOT, (ctx) => epochStreamer.runNextEpoch(ctx));
    sim.send(ROOT, (ctx) => treasury.revokeAllowance(ctx, WORKER, 50n * USDC));
    assert.equal(
      sim.read((ctx) => treasury.allowanceGeneration(ctx, WORKER)),
      0n,
    );
    assert.equal(sim.world.treasury.totalReserved, 0n);
    sim.send(ROOT, (ctx) => epochStreamer.runNextEpoch(ctx));
    assert.equal(
      sim.read((ctx) => treasury.allowanceGeneration(ctx, WORKER)),
      2n,
    );
  });
});
