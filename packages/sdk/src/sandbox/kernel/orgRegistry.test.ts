import { describe, it } from "node:test";
import assert from "node:assert/strict";

import * as orgRegistry from "./orgRegistry.js";
import { NodeKind } from "./orgRegistry.js";
import { MANAGER, ROOT, STRANGER, Sim, T0, WORKER } from "./testkit.test.js";
import { ZERO_ADDRESS, type Address } from "./types.js";
import { allocateAddress, blankWorld, transact } from "./world.js";

const GOVERNOR = `0x${"99".repeat(20)}` as Address;
const A = `0x${"01".repeat(20)}` as Address;
const B = `0x${"02".repeat(20)}` as Address;
const C = `0x${"03".repeat(20)}` as Address;

function registry(): Sim {
  const world = transact(blankWorld(), { sender: STRANGER, at: T0 }, (ctx) =>
    orgRegistry.deploy(ctx, allocateAddress(ctx), ROOT),
  ).world;
  return new Sim(world);
}

describe("kernel OrgRegistry", () => {
  it("is constructed with the human root as its only node", () => {
    const sim = registry();
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getNode(ctx, ROOT)),
      { account: ROOT, kind: NodeKind.HumanRoot, parent: ZERO_ADDRESS, active: true },
    );
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)),
      [],
    );
    assert.equal(sim.world.orgRegistry.root, ROOT);
  });

  it("refuses a zero human root", () => {
    assert.throws(
      () =>
        transact(blankWorld(), { sender: STRANGER, at: T0 }, (ctx) =>
          orgRegistry.deploy(ctx, allocateAddress(ctx), ZERO_ADDRESS),
        ),
      { errorName: "ZeroAddress" },
    );
  });

  it("adds a manager and a worker and reports them as children", () => {
    const sim = registry();
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, MANAGER, NodeKind.ManagerAgent, ROOT));
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, WORKER, NodeKind.WorkerAgent, MANAGER));
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getNode(ctx, WORKER)),
      { account: WORKER, kind: NodeKind.WorkerAgent, parent: MANAGER, active: true },
    );
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)),
      [MANAGER],
    );
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, MANAGER)),
      [WORKER],
    );
    assert.deepEqual(sim.lastEvent("NodeAdded").args, {
      account: WORKER,
      kind: NodeKind.WorkerAgent,
      parent: MANAGER,
    });
  });

  it("treats two spellings of an address as one node", () => {
    const sim = registry();
    sim.send(ROOT, (ctx) =>
      orgRegistry.addNode(ctx, MANAGER.toUpperCase().replace("0X", "0x") as Address, 1, ROOT),
    );
    sim.reverts("NodeAlreadyExists", ROOT, (ctx) => orgRegistry.addNode(ctx, MANAGER, 1, ROOT));
  });

  it("lets only the root mutate until a governor is bound, then only the governor", () => {
    const sim = registry();
    sim.reverts("NotAuthorized", STRANGER, (ctx) => orgRegistry.addNode(ctx, A, 2, ROOT));
    sim.reverts("NotAuthorized", STRANGER, (ctx) => orgRegistry.setGovernor(ctx, GOVERNOR));
    sim.reverts("ZeroAddress", ROOT, (ctx) => orgRegistry.setGovernor(ctx, ZERO_ADDRESS));

    sim.send(ROOT, (ctx) => orgRegistry.setGovernor(ctx, GOVERNOR));
    sim.reverts("NotAuthorized", ROOT, (ctx) => orgRegistry.addNode(ctx, A, 2, ROOT));
    sim.reverts("NotAuthorized", ROOT, (ctx) => orgRegistry.setGovernor(ctx, ROOT));
    sim.send(GOVERNOR, (ctx) => orgRegistry.addNode(ctx, A, 2, ROOT));
    sim.send(GOVERNOR, (ctx) => orgRegistry.setGovernor(ctx, ROOT));
    assert.equal(sim.world.orgRegistry.governor, ROOT);
  });

  it("rejects a duplicate node and an unknown parent", () => {
    const sim = registry();
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, 2, ROOT));
    sim.reverts("NodeAlreadyExists", ROOT, (ctx) => orgRegistry.addNode(ctx, A, 2, ROOT));
    sim.reverts("InvalidParent", ROOT, (ctx) => orgRegistry.addNode(ctx, B, 2, C));
  });

  it("soft-deactivates a node but never the root", () => {
    const sim = registry();
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, 2, ROOT));
    sim.reverts("NodeNotFound", ROOT, (ctx) => orgRegistry.setActive(ctx, B, false));
    sim.reverts("CannotMutateRoot", ROOT, (ctx) => orgRegistry.setActive(ctx, ROOT, false));
    sim.send(ROOT, (ctx) => orgRegistry.setActive(ctx, A, false));
    assert.equal(sim.read((ctx) => orgRegistry.getNode(ctx, A)).active, false);
    assert.deepEqual(sim.lastEvent("NodeActiveUpdated").args, { account: A, active: false });
    sim.send(ROOT, (ctx) => orgRegistry.setActive(ctx, A, true));
    assert.equal(sim.read((ctx) => orgRegistry.getNode(ctx, A)).active, true);
  });

  it("removing a node rewires its children to its parent", () => {
    const sim = registry();
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, MANAGER, 1, ROOT));
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, 2, MANAGER));
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, B, 2, MANAGER));
    sim.send(ROOT, (ctx) => orgRegistry.removeNode(ctx, MANAGER));

    sim.reverts("NodeNotFound", ROOT, (ctx) => orgRegistry.getNode(ctx, MANAGER));
    assert.equal(sim.read((ctx) => orgRegistry.getNode(ctx, A)).parent, ROOT);
    assert.equal(sim.read((ctx) => orgRegistry.getNode(ctx, B)).parent, ROOT);
    // The children are appended before the removed node is swap-and-popped out.
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)),
      [B, A],
    );
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, MANAGER)),
      [],
    );
    assert.deepEqual(sim.lastEvent("NodeRemoved").args, { account: MANAGER, formerParent: ROOT });
  });

  it("cannot remove the root or a node that is not there", () => {
    const sim = registry();
    sim.reverts("CannotMutateRoot", ROOT, (ctx) => orgRegistry.removeNode(ctx, ROOT));
    sim.reverts("NodeNotFound", ROOT, (ctx) => orgRegistry.removeNode(ctx, A));
    sim.reverts("NotAuthorized", STRANGER, (ctx) => orgRegistry.removeNode(ctx, A));
  });

  it("reparents a node and keeps sibling order the contract's way", () => {
    const sim = registry();
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, 1, ROOT));
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, B, 1, ROOT));
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, C, 2, ROOT));
    sim.send(ROOT, (ctx) => orgRegistry.reparent(ctx, A, B));
    assert.equal(sim.read((ctx) => orgRegistry.getNode(ctx, A)).parent, B);
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)),
      [C, B],
    );
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, B)),
      [A],
    );
    assert.deepEqual(sim.lastEvent("NodeReparented").args, {
      account: A,
      oldParent: ROOT,
      newParent: B,
    });
  });

  it("rejects cycles, root moves, unknown parents; a move to the same parent is a no-op", () => {
    const sim = registry();
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, 1, ROOT));
    sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, B, 2, A));
    sim.reverts("CyclicParent", ROOT, (ctx) => orgRegistry.reparent(ctx, A, A));
    sim.reverts("CyclicParent", ROOT, (ctx) => orgRegistry.reparent(ctx, A, B));
    sim.reverts("CannotMutateRoot", ROOT, (ctx) => orgRegistry.reparent(ctx, ROOT, A));
    sim.reverts("InvalidParent", ROOT, (ctx) => orgRegistry.reparent(ctx, B, C));
    sim.reverts("NodeNotFound", ROOT, (ctx) => orgRegistry.reparent(ctx, C, A));

    const mark = sim.events.length;
    sim.send(ROOT, (ctx) => orgRegistry.reparent(ctx, B, A));
    assert.deepEqual(sim.eventNames(mark), []);
  });

  it("refuses the zero address as a node", () => {
    // A node whose account is zero would read as absent while still listed as a child.
    const sim = registry();
    sim.reverts("ZeroAddress", ROOT, (ctx) => orgRegistry.addNode(ctx, ZERO_ADDRESS, 2, ROOT));
    sim.reverts("NodeNotFound", ROOT, (ctx) => orgRegistry.getNode(ctx, ZERO_ADDRESS));
    assert.deepEqual(
      sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)),
      [],
    );
  });

  describe("fan-out cap (MAX_CHILDREN)", () => {
    const MAX = 100;
    const seat = (i: number) => `0x${(0x1000 + i).toString(16).padStart(40, "0")}` as Address;

    /** A registry whose root has `n` workers (seat(0..n-1)). */
    function fanOut(n: number): Sim {
      const sim = registry();
      for (let i = 0; i < n; i++) {
        sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, seat(i), NodeKind.WorkerAgent, ROOT));
      }
      return sim;
    }

    it("addNode refuses the 101st child with TooManyChildren(parent)", () => {
      const sim = fanOut(MAX);
      sim.reverts("TooManyChildren", ROOT, (ctx) =>
        orgRegistry.addNode(ctx, A, NodeKind.WorkerAgent, ROOT),
      );
      assert.equal(sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)).length, MAX);
      // The cap is per parent: another parent still takes a report.
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, NodeKind.WorkerAgent, seat(0)));
    });

    it("names the parent in the error", () => {
      const sim = fanOut(MAX);
      assert.throws(
        () => sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, NodeKind.WorkerAgent, ROOT)),
        { errorName: "TooManyChildren", args: { parent: ROOT } },
      );
    });

    it("removeNode refuses when the parent would end up over the cap", () => {
      // root: 99 workers + manager; manager: 2 reports. Removing manager leaves 99 + 2 = 101.
      const sim = fanOut(MAX - 1);
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, MANAGER, NodeKind.ManagerAgent, ROOT));
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, NodeKind.WorkerAgent, MANAGER));
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, B, NodeKind.WorkerAgent, MANAGER));
      sim.reverts("TooManyChildren", ROOT, (ctx) => orgRegistry.removeNode(ctx, MANAGER));
      // Nothing moved.
      assert.equal(sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)).length, MAX);
      assert.deepEqual(
        sim.read((ctx) => orgRegistry.getChildren(ctx, MANAGER)),
        [A, B],
      );
      // One report fewer lands exactly on the cap and is allowed.
      sim.send(ROOT, (ctx) => orgRegistry.removeNode(ctx, B));
      sim.send(ROOT, (ctx) => orgRegistry.removeNode(ctx, MANAGER));
      assert.equal(sim.read((ctx) => orgRegistry.getChildren(ctx, ROOT)).length, MAX);
    });

    it("reparent refuses a full new parent, and allows a no-op move onto it", () => {
      const sim = fanOut(MAX);
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, MANAGER, NodeKind.ManagerAgent, seat(0)));
      sim.reverts("TooManyChildren", ROOT, (ctx) => orgRegistry.reparent(ctx, MANAGER, ROOT));
      // Already a child of its parent: nothing to move, so the cap is not consulted.
      sim.send(ROOT, (ctx) => orgRegistry.reparent(ctx, seat(1), ROOT));
      // Room opens once a seat leaves.
      sim.send(ROOT, (ctx) => orgRegistry.removeNode(ctx, seat(2)));
      sim.send(ROOT, (ctx) => orgRegistry.reparent(ctx, MANAGER, ROOT));
    });
  });

  describe("depth cap (MAX_DEPTH)", () => {
    const MAX_DEPTH = 32;
    const seat = (i: number) => `0x${(0x3000 + i).toString(16).padStart(40, "0")}` as Address;

    /** A chain seat(1) .. seat(n), seat(1) under the root: seat(i) sits at depth i. */
    function chain(n: number): Sim {
      const sim = registry();
      for (let i = 1; i <= n; i++) {
        sim.send(ROOT, (ctx) =>
          orgRegistry.addNode(ctx, seat(i), NodeKind.ManagerAgent, i === 1 ? ROOT : seat(i - 1)),
        );
      }
      return sim;
    }

    it("addNode refuses a seat below depth 32 with MaxDepthExceeded(account)", () => {
      const sim = chain(MAX_DEPTH);
      assert.throws(
        () => sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, NodeKind.WorkerAgent, seat(32))),
        { errorName: "MaxDepthExceeded", args: { account: A } },
      );
      assert.equal(sim.read((ctx) => orgRegistry.getChildren(ctx, seat(32))).length, 0);
      // Depth 32 itself is allowed: the parent one level up still takes a report.
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, NodeKind.WorkerAgent, seat(31)));
    });

    it("reparent can build past the cap; walks over it then name the node they started from", () => {
      const sim = chain(MAX_DEPTH);
      // A short branch moved under the deepest seat ends up 33..35 deep: reparent checks no depth.
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, A, NodeKind.ManagerAgent, ROOT));
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, B, NodeKind.ManagerAgent, A));
      sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, C, NodeKind.ManagerAgent, B));
      sim.send(ROOT, (ctx) => orgRegistry.reparent(ctx, A, seat(32)));
      // The ancestor walk from C is 35 hops: refused, naming C.
      assert.throws(() => sim.send(ROOT, (ctx) => orgRegistry.reparent(ctx, seat(1), C)), {
        errorName: "MaxDepthExceeded",
        args: { account: C },
      });
      // addNode under A (depth 33): `_depth` overruns and names the parent, not the new account.
      assert.throws(
        () => sim.send(ROOT, (ctx) => orgRegistry.addNode(ctx, WORKER, NodeKind.WorkerAgent, A)),
        { errorName: "MaxDepthExceeded", args: { account: A } },
      );
    });
  });
});
