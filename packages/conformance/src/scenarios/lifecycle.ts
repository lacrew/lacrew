/**
 * How long things last: an intent expires, and state recorded against an
 * address stops counting once that address is removed and added again.
 */

import { DAY, HOUR, KIND, USDC, scenario, type Scenario } from "../scenario.js";

const MIN_TTL = BigInt(HOUR);
const MAX_TTL = BigInt(365 * DAY);
const SETTLED = ["Transfer", "AllowanceSpent", "ActionExecuted", "IntentResolved"];

export const lifecycleScenarios: Scenario[] = [
  scenario("an intent expires after the default seven days and anyone may close it", (b) => {
    b.crew();
    const intent = b.escalate("worker", "worker", "target", 75n * USDC);
    b.reverts("IntentNotExpired", "stranger", "@router", "closeExpired", [BigInt(intent)]);
    b.warp(7 * DAY - HOUR);
    b.reverts("IntentNotExpired", "stranger", "@router", "closeExpired", [BigInt(intent)]);
    b.warp(2 * HOUR);
    // Past its expiry nobody resolves it, the approver and the root included.
    b.reverts("IntentHasExpired", "manager", "@router", "resolve", [BigInt(intent), true]);
    b.reverts("IntentHasExpired", "manager", "@router", "resolve", [BigInt(intent), false]);
    b.reverts("IntentHasExpired", "root", "@router", "resolve", [BigInt(intent), true]);
    b.call("stranger", "@router", "closeExpired", [BigInt(intent)], {
      events: ["IntentExpired", "IntentResolved"],
    });
    b.expect({
      intents: { [intent]: { resolved: true, approved: false } },
      pending: [],
      allowance: { worker: 200n * USDC },
      balance: { target: 0n },
    });
    b.reverts("IntentAlreadyResolved", "stranger", "@router", "closeExpired", [BigInt(intent)]);
    b.reverts("IntentNotFound", "stranger", "@router", "closeExpired", [99n]);
  }),

  scenario("the intent lifetime is governed, bounded, and fixed when an intent is created", (b) => {
    b.crew();
    const before = b.escalate("worker", "worker", "target", 75n * USDC);
    b.reverts("NotAuthorized", "stranger", "@router", "setIntentTtl", [MIN_TTL]);
    b.reverts("NotAuthorized", "manager", "@router", "setIntentTtl", [MIN_TTL]);
    b.reverts("InvalidIntentTtl", "root", "@router", "setIntentTtl", [MIN_TTL - 1n]);
    b.reverts("InvalidIntentTtl", "root", "@router", "setIntentTtl", [0n]);
    b.reverts("InvalidIntentTtl", "root", "@router", "setIntentTtl", [MAX_TTL + 1n]);
    b.call("root", "@router", "setIntentTtl", [MAX_TTL], { events: ["IntentTtlUpdated"] });
    b.call("root", "@router", "setIntentTtl", [MIN_TTL], { events: ["IntentTtlUpdated"] });
    b.call("root", "@router", "setIntentTtl", [2n * MIN_TTL], { events: ["IntentTtlUpdated"] });

    const after = b.escalate("worker", "worker", "target", 76n * USDC);
    b.warp(HOUR + HOUR / 2);
    b.reverts("IntentNotExpired", "stranger", "@router", "closeExpired", [BigInt(after)]);
    b.warp(HOUR);
    b.call("stranger", "@router", "closeExpired", [BigInt(after)]);
    // An intent made under the old lifetime keeps it.
    b.reverts("IntentNotExpired", "stranger", "@router", "closeExpired", [BigInt(before)]);
    b.resolve("manager", before, true, { events: SETTLED });
    b.expect({
      intents: {
        [before]: { resolved: true, approved: true },
        [after]: { resolved: true, approved: false },
      },
    });
  }),

  scenario("an agent removed and added again does not inherit its old intents", (b) => {
    b.crew();
    const held = b.escalate("worker", "worker", "target", 75n * USDC);
    const dropped = b.escalate("worker", "worker", "target", 80n * USDC);
    b.call("root", "@registry", "removeNode", ["worker"]);
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "manager"]);
    b.expect({ nodes: { worker: { parent: "manager", active: true } } });
    // Active again, but not the agent that raised them: rejecting works, approving does not.
    b.reverts("InactiveAgent", "manager", "@router", "resolve", [BigInt(held), true]);
    b.resolve("manager", dropped, false, { events: ["IntentResolved"] });
    b.expect({
      intents: { [held]: { resolved: false }, [dropped]: { resolved: true, approved: false } },
      allowance: { worker: 200n * USDC },
      balance: { target: 0n },
    });
  }),

  scenario("an approver removed and added again no longer holds the intents waiting on it", (b) => {
    b.crew();
    const held = b.escalate("worker", "worker", "target", 75n * USDC);
    const other = b.escalate("worker", "worker", "target", 60n * USDC);
    b.call("root", "@registry", "removeNode", ["manager"]);
    b.call("root", "@registry", "addNode", ["manager", KIND.manager, "root"]);
    b.expect({ nodes: { manager: { parent: "root", active: true } } });
    // The address is active, yet it is a new seat: the root stands in, as for a removed approver.
    b.reverts("InactiveApprover", "manager", "@router", "resolve", [BigInt(held), true]);
    b.reverts("InactiveApprover", "manager", "@router", "resolve", [BigInt(held), false]);
    b.resolve("root", held, true, { events: SETTLED });
    b.resolve("root", other, false, { events: ["IntentResolved"] });
    b.expect({
      intents: {
        [held]: { resolved: true, approved: true },
        [other]: { resolved: true, approved: false },
      },
      pending: [],
      balance: { target: 75n * USDC },
    });
  }),

  scenario("a session key does not outlive the agent it was issued for", (b) => {
    b.crew();
    b.session();
    b.allow("key", "worker", "target", 1n);
    b.expect({ keys: [{ agent: "worker", key: "key", valid: true }] });
    b.call("root", "@registry", "removeNode", ["worker"]);
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "manager"]);
    b.expect({ keys: [{ agent: "worker", key: "key", valid: false }] });
    b.proposeReverts("InvalidSession", "key", "worker", "target", 1n);
    // A fresh session restores the key's reach.
    b.session();
    b.expect({ keys: [{ agent: "worker", key: "key", valid: true }] });
    // The seat's old allowance is stale too; once it is recalled and streamed again, the key spends.
    b.proposeReverts("StaleAllowance", "key", "worker", "target", 1n, "Treasury");
    b.call("root", "@treasury", "revokeAllowance", ["worker", 200n * USDC - 1n]);
    b.call("root", "@streamer", "runNextEpoch");
    b.allow("key", "worker", "target", 1n);
  }),

  scenario("an allowance left by a removed agent is stale until revoked to zero", (b) => {
    b.crew();
    b.call("root", "@registry", "removeNode", ["worker"]);
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "manager"]);
    b.expect({ allowance: { worker: 200n * USDC } });
    // Neither spendable nor toppable.
    b.proposeReverts("StaleAllowance", "worker", "worker", "target", 10n * USDC, "Treasury");
    b.reverts("StaleAllowance", "root", "@streamer", "runNextEpoch", [], "Treasury");

    b.reverts("NotAuthorized", "stranger", "@treasury", "revokeAllowance", ["worker", 1n]);
    b.reverts("InsufficientAllowance", "root", "@treasury", "revokeAllowance", [
      "worker",
      200n * USDC + 1n,
    ]);
    // A partial revoke leaves what remains stale.
    b.call("root", "@treasury", "revokeAllowance", ["worker", 150n * USDC], {
      events: ["AllowanceRevoked"],
    });
    b.expect({ allowance: { worker: 50n * USDC } });
    b.proposeReverts("StaleAllowance", "worker", "worker", "target", 10n * USDC, "Treasury");
    b.reverts("StaleAllowance", "root", "@streamer", "runNextEpoch", [], "Treasury");

    b.call("root", "@treasury", "revokeAllowance", ["worker", 50n * USDC], {
      events: ["AllowanceRevoked"],
    });
    b.expect({ allowance: { worker: 0n } });
    // Empty, the seat starts over under its own incarnation.
    b.call("root", "@streamer", "runNextEpoch");
    b.allow("worker", "worker", "target", 10n * USDC);
    b.expect({ allowance: { worker: 190n * USDC }, balance: { target: 10n * USDC } });
  }),
];
