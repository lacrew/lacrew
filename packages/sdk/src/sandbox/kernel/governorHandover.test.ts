import { describe, it } from "node:test";
import assert from "node:assert/strict";

import * as epochStreamer from "./epochStreamer.js";
import * as escalationRouter from "./escalationRouter.js";
import * as governance from "./governance.js";
import { Tier } from "./governance.js";
import * as orgRegistry from "./orgRegistry.js";
import * as policies from "./policies.js";
import * as sessionRegistry from "./sessionRegistry.js";
import { ROOT, STRANGER, Sim, T0, TARGET } from "./testkit.test.js";
import * as token from "./token.js";
import * as treasury from "./treasury.js";
import { ZERO_ADDRESS, type Address, type Hex } from "./types.js";
import { allocateAddress, blankWorld, transact, type Ctx } from "./world.js";

const DEPLOYER = `0x${"11".repeat(20)}` as Address;
const GOV = `0x${"33".repeat(20)}` as Address;
const NEXT = `0x${"66".repeat(20)}` as Address;
const WRONG = `0x${"77".repeat(20)}` as Address;
const PROBE = `0x${"88".repeat(20)}` as Address;

interface Governed {
  name: string;
  /** Who makes the one-time bind. */
  binder: Address;
  bind: (ctx: Ctx, governor: Address) => void;
  setPending: (ctx: Ctx, pending: Address) => void;
  accept: (ctx: Ctx) => void;
  pending: (sim: Sim) => Address;
  governor: (sim: Sim) => Address;
  /** One call only the governor may make. */
  probe: (ctx: Ctx) => void;
}

function build(): { sim: Sim; all: Governed[] } {
  let world = blankWorld();
  const run = (fn: (ctx: Ctx) => void) => {
    world = transact(world, { sender: DEPLOYER, at: T0 }, fn).world;
  };
  run((ctx) => token.deploy(ctx, allocateAddress(ctx)));
  world = transact(world, { sender: ROOT, at: T0 }, (ctx) =>
    orgRegistry.deploy(ctx, allocateAddress(ctx), ROOT),
  ).world;
  run((ctx) =>
    sessionRegistry.deploy(ctx, allocateAddress(ctx), ROOT, ctx.world.addresses.orgRegistry),
  );
  run((ctx) => policies.deploySpendCapPolicy(ctx, allocateAddress(ctx), 50n));
  const cap = world.addresses.spendCapPolicy ?? ZERO_ADDRESS;
  run((ctx) => policies.deployWhitelistPolicy(ctx, allocateAddress(ctx)));
  const whitelist = world.addresses.whitelistPolicy ?? ZERO_ADDRESS;
  run((ctx) =>
    escalationRouter.deploy(ctx, allocateAddress(ctx), ctx.world.addresses.orgRegistry, whitelist),
  );
  run((ctx) =>
    treasury.deploy(
      ctx,
      allocateAddress(ctx),
      ctx.world.addresses.orgRegistry,
      ctx.world.addresses.token,
      ctx.world.addresses.escalationRouter,
    ),
  );
  run((ctx) =>
    epochStreamer.deploy(
      ctx,
      allocateAddress(ctx),
      ctx.world.addresses.treasury,
      DEPLOYER,
      T0,
      86_400n,
    ),
  );

  const all: Governed[] = [
    {
      name: "OrgRegistry",
      binder: ROOT,
      bind: (ctx, g) => orgRegistry.setGovernor(ctx, g),
      setPending: (ctx, p) => orgRegistry.setPendingGovernor(ctx, p),
      accept: (ctx) => orgRegistry.acceptGovernor(ctx),
      pending: (s) => s.world.orgRegistry.pendingGovernor ?? ZERO_ADDRESS,
      governor: (s) => s.world.orgRegistry.governor,
      probe: (ctx) => orgRegistry.addNode(ctx, allocateAddress(ctx), 1, ROOT),
    },
    {
      name: "SessionRegistry",
      binder: ROOT,
      bind: (ctx, g) => sessionRegistry.setGovernor(ctx, g),
      setPending: (ctx, p) => sessionRegistry.setPendingGovernor(ctx, p),
      accept: (ctx) => sessionRegistry.acceptGovernor(ctx),
      pending: (s) => s.world.sessionRegistry.pendingGovernor ?? ZERO_ADDRESS,
      governor: (s) => s.world.sessionRegistry.governor ?? ZERO_ADDRESS,
      probe: (ctx) => sessionRegistry.setIssuer(ctx, PROBE),
    },
    {
      name: "Treasury",
      binder: DEPLOYER,
      bind: (ctx, g) => treasury.setGovernor(ctx, g),
      setPending: (ctx, p) => treasury.setPendingGovernor(ctx, p),
      accept: (ctx) => treasury.acceptGovernor(ctx),
      pending: (s) => s.world.treasury.pendingGovernor ?? ZERO_ADDRESS,
      governor: (s) => s.world.treasury.governor,
      probe: (ctx) => treasury.setSpender(ctx, PROBE),
    },
    {
      name: "EscalationRouter",
      binder: DEPLOYER,
      bind: (ctx, g) => escalationRouter.setGovernor(ctx, g),
      setPending: (ctx, p) => escalationRouter.setPendingGovernor(ctx, p),
      accept: (ctx) => escalationRouter.acceptGovernor(ctx),
      pending: (s) => s.world.escalationRouter.pendingGovernor ?? ZERO_ADDRESS,
      governor: (s) => s.world.escalationRouter.governor,
      probe: (ctx) => escalationRouter.setIntentTtl(ctx, 7_200n),
    },
    {
      name: "EpochStreamer",
      binder: DEPLOYER,
      bind: (ctx, g) => epochStreamer.setGovernor(ctx, g),
      setPending: (ctx, p) => epochStreamer.setPendingGovernor(ctx, p),
      accept: (ctx) => epochStreamer.acceptGovernor(ctx),
      pending: (s) => s.world.epochStreamer.pendingGovernor ?? ZERO_ADDRESS,
      governor: (s) => s.world.epochStreamer.governor,
      probe: (ctx) => epochStreamer.setGrant(ctx, PROBE, 1n),
    },
    {
      name: "SpendCapPolicy",
      binder: DEPLOYER,
      bind: (ctx, g) => policies.setGovernor(ctx, cap, g),
      setPending: (ctx, p) => policies.setPendingGovernor(ctx, cap, p),
      accept: (ctx) => policies.acceptGovernor(ctx, cap),
      pending: (s) => s.read((ctx) => policies.pendingGovernorOf(ctx, cap)),
      governor: (s) => (s.world.policies[cap] as policies.SpendCapPolicyState).governor,
      probe: (ctx) => policies.setAgentCap(ctx, cap, PROBE, 3n),
    },
    {
      name: "WhitelistPolicy",
      binder: DEPLOYER,
      bind: (ctx, g) => policies.setGovernor(ctx, whitelist, g),
      setPending: (ctx, p) => policies.setPendingGovernor(ctx, whitelist, p),
      accept: (ctx) => policies.acceptGovernor(ctx, whitelist),
      pending: (s) => s.read((ctx) => policies.pendingGovernorOf(ctx, whitelist)),
      governor: (s) => (s.world.policies[whitelist] as policies.WhitelistPolicyState).governor,
      probe: (ctx) => policies.setAllowed(ctx, whitelist, PROBE, true),
    },
  ];
  return { sim: new Sim(world), all };
}

/** Whether `caller` can make the probe call, without keeping its effect. */
function can(sim: Sim, g: Governed, caller: Address): boolean {
  try {
    transact(sim.world, { sender: caller, at: T0 }, g.probe);
    return true;
  } catch {
    return false;
  }
}

describe("kernel two-step governor hand-over", () => {
  it("binds once, then hands over by naming a pending governor that must accept", () => {
    const { sim, all } = build();
    for (const g of all) {
      // Nobody names a successor before a governor is bound.
      sim.reverts("NotAuthorized", g.binder, (ctx) => g.setPending(ctx, NEXT));
      sim.reverts("NotAuthorized", STRANGER, (ctx) => g.bind(ctx, STRANGER));
      sim.send(g.binder, (ctx) => g.bind(ctx, GOV));
      assert.equal(g.governor(sim), GOV, g.name);
      assert.deepEqual(sim.lastEvent("GovernorUpdated").args, { governor: GOV }, g.name);

      // The bind is once: not even the governor binds again.
      sim.reverts("GovernorAlreadySet", g.binder, (ctx) => g.bind(ctx, NEXT));
      sim.reverts("GovernorAlreadySet", GOV, (ctx) => g.bind(ctx, NEXT));

      // Only the governor names a pending one; a stranger, the binder and the pending cannot.
      for (const outsider of [STRANGER, g.binder, NEXT]) {
        sim.reverts("NotAuthorized", outsider, (ctx) => g.setPending(ctx, NEXT));
      }

      // A wrong address is corrected by naming the right one.
      sim.send(GOV, (ctx) => g.setPending(ctx, WRONG));
      assert.deepEqual(
        sim.lastEvent("PendingGovernorUpdated").args,
        { pendingGovernor: WRONG },
        g.name,
      );
      sim.send(GOV, (ctx) => g.setPending(ctx, NEXT));
      assert.equal(g.pending(sim), NEXT, g.name);
      sim.reverts("NotPendingGovernor", WRONG, (ctx) => g.accept(ctx));
      sim.reverts("NotPendingGovernor", STRANGER, (ctx) => g.accept(ctx));
      sim.reverts("NotPendingGovernor", GOV, (ctx) => g.accept(ctx));

      // Until acceptance the old governor keeps its powers and the pending one has none.
      assert.equal(can(sim, g, GOV), true, `${g.name}: old governor keeps power`);
      assert.equal(can(sim, g, NEXT), false, `${g.name}: pending has none`);

      sim.send(NEXT, (ctx) => g.accept(ctx));
      assert.deepEqual(sim.lastEvent("GovernorUpdated").args, { governor: NEXT }, g.name);
      assert.equal(g.governor(sim), NEXT, g.name);
      assert.equal(g.pending(sim), ZERO_ADDRESS, g.name);
      assert.equal(can(sim, g, NEXT), true, `${g.name}: new governor holds power`);
      assert.equal(can(sim, g, GOV), false, `${g.name}: old governor lost power`);
      sim.reverts("NotPendingGovernor", NEXT, (ctx) => g.accept(ctx));
    }
  });

  it("lets the governor cancel a pending hand-over with the zero address", () => {
    const { sim, all } = build();
    for (const g of all) {
      sim.send(g.binder, (ctx) => g.bind(ctx, GOV));
      sim.send(GOV, (ctx) => g.setPending(ctx, WRONG));
      sim.send(GOV, (ctx) => g.setPending(ctx, ZERO_ADDRESS));
      sim.reverts("NotPendingGovernor", WRONG, (ctx) => g.accept(ctx));
      assert.equal(g.governor(sim), GOV, g.name);
    }
  });

  it("never lets naming or accepting a governor ride the low tier", () => {
    const sim = new Sim(
      transact(blankWorld(), { sender: ROOT, at: T0 }, (ctx) => {
        orgRegistry.deploy(ctx, allocateAddress(ctx), ROOT);
        governance.deploy(ctx, allocateAddress(ctx), ROOT, 2n);
      }).world,
    );
    const setPending = `0xf235757f${"00".repeat(32)}` as Hex;
    const accept = "0xe58bb639" as Hex;
    for (const data of [setPending, accept]) {
      sim.reverts("GovernorTransferNotHighTier", ROOT, (ctx) =>
        governance.propose(ctx, Tier.Low, TARGET, data),
      );
      sim.send(ROOT, (ctx) => governance.propose(ctx, Tier.High, TARGET, data));
    }
    for (const selector of [
      governance.SET_PENDING_GOVERNOR_SELECTOR,
      governance.ACCEPT_GOVERNOR_SELECTOR,
    ]) {
      sim.reverts("GovernorTransferNotHighTier", ROOT, (ctx) =>
        governance.setLowTierSelector(ctx, selector as Hex, true),
      );
    }
  });
});
