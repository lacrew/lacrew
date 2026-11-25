/**
 * The gas guards of #624: a node has at most MAX_CHILDREN (100) direct reports,
 * and the payroll has at most MAX_RECIPIENTS (100) recipients. Every path that
 * grows either list must refuse the 101st entry the same way on the simulator
 * and on a chain.
 */

import { KIND, scenario, type Scenario } from "../scenario.js";

const MAX = 100;

/** Seat `i` as a literal address: refs may be hex, and the cast has far fewer than 100 names. */
const seat = (base: number, i: number): string => `0x${(base + i).toString(16).padStart(40, "0")}`;

export const fanOutScenarios: Scenario[] = [
  scenario(
    "a node takes at most 100 reports: addNode, reparent and removeNode all refuse the 101st",
    (b) => {
      // 99 workers and a manager fill the root exactly.
      for (let i = 0; i < MAX - 1; i++) {
        b.call("root", "@registry", "addNode", [seat(0x1000, i), KIND.worker, "root"]);
      }
      b.call("root", "@registry", "addNode", ["manager", KIND.manager, "root"]);
      b.call("root", "@registry", "addNode", ["worker", KIND.worker, "manager"]);
      b.call("root", "@registry", "addNode", ["worker2", KIND.worker, "manager"]);

      // addNode: the root is full.
      b.reverts("TooManyChildren", "root", "@registry", "addNode", ["target", KIND.worker, "root"]);
      // reparent: so is the place the worker would move to.
      b.reverts("TooManyChildren", "root", "@registry", "reparent", ["worker", "root"]);
      // removeNode: the root would lose the manager but gain two reports, ending on 101.
      b.reverts("TooManyChildren", "root", "@registry", "removeNode", ["manager"]);
      // A refused call changed nothing.
      b.expect({
        nodes: {
          manager: { parent: "root" },
          worker: { parent: "manager" },
          worker2: { parent: "manager" },
          target: null,
        },
      });

      // With one report fewer the manager's removal lands exactly on the cap.
      b.call("root", "@registry", "removeNode", ["worker2"]);
      b.call("root", "@registry", "removeNode", ["manager"], { events: ["NodeRemoved"] });
      b.expect({ nodes: { manager: null, worker: { parent: "root" } } });
      // Full again, so a new seat is refused once more.
      b.reverts("TooManyChildren", "root", "@registry", "addNode", ["target", KIND.worker, "root"]);
      // A move to the parent the node already has is a no-op, not a cap breach.
      b.call("root", "@registry", "reparent", ["worker", "root"], { events: [] });
      // Another parent is unaffected by the root's cap, and a seat freed makes room.
      b.call("root", "@registry", "addNode", ["manager2", KIND.manager, seat(0x1000, 0)]);
      b.call("root", "@registry", "removeNode", [seat(0x1000, 1)]);
      b.call("root", "@registry", "reparent", ["manager2", "root"]);
    },
  ),

  scenario("rotating the root cannot push the promoted peer past 100 reports", (b) => {
    b.call("root", "@registry", "addNode", ["human2", KIND.human, "root"]);
    b.call("root", "@registry", "addNode", ["manager", KIND.manager, "human2"]);
    b.call("root", "@registry", "addNode", ["manager2", KIND.manager, "human2"]);
    // The root gets 98 workers plus one more: human2 and 99 reports make 100 seats.
    for (let i = 0; i < MAX - 2; i++) {
      b.call("root", "@registry", "addNode", [seat(0x1000, i), KIND.worker, "root"]);
    }
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "root"]);
    // human2 would hold its 2 reports plus the root's 99 others: 101.
    b.reverts("TooManyChildren", "root", "@registry", "rotateRoot", ["human2"]);
    b.expect({ nodes: { human2: { parent: "root" }, root: { parent: null } } });
    // One fewer lands exactly on 100.
    b.call("root", "@registry", "removeNode", ["worker"]);
    b.call("root", "@registry", "rotateRoot", ["human2"]);
    b.expect({ nodes: { root: null, human2: { parent: null }, manager: { parent: "human2" } } });
  }),

  scenario("the payroll takes at most 100 recipients", (b) => {
    for (let i = 0; i < MAX; i++) {
      b.call("root", "@streamer", "setGrant", [seat(0x2000, i), 1n]);
    }
    b.reverts("TooManyRecipients", "root", "@streamer", "setGrant", ["worker", 1n]);
    b.reverts("TooManyRecipients", "root", "@streamer", "setGrants", [["worker"], [1n]]);
    // A current recipient is not a new one; clearing a grant frees a slot.
    b.call("root", "@streamer", "setGrant", [seat(0x2000, 0), 7n]);
    b.call("root", "@streamer", "setGrant", [seat(0x2000, 1), 0n]);
    b.call("root", "@streamer", "setGrant", ["worker", 1n]);
    b.reverts("TooManyRecipients", "root", "@streamer", "setGrant", ["worker2", 1n]);
  }),
];
