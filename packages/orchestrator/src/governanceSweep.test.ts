import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { autoExecuteEnabled, decideAutoExecute } from "./governanceSweep.js";
import type { GovernanceProposal } from "@lacrew/core";

const NOW = 1_800_000_000;

function proposal(over: Partial<GovernanceProposal> = {}): GovernanceProposal {
  return {
    id: "1",
    proposer: "0x0000000000000000000000000000000000000001",
    tier: "low",
    target: "0x0000000000000000000000000000000000000002",
    actionHash: "0x00",
    data: "0x00",
    yesVotes: 2,
    noVotes: 0,
    deadline: NOW + 3600,
    eta: 0,
    state: "active",
    ...over,
  };
}

/** The bars a proposal is snapshotted with, by tier. */
interface Bars {
  quorumYes: string;
  quorumHumanYes: string;
  totalHumanVotingPower: string;
  unanimityFastPath: boolean;
}

const CONFIG: Bars = {
  quorumYes: "2",
  quorumHumanYes: "1",
  totalHumanVotingPower: "2",
  unanimityFastPath: true,
};

/** Attach the creation snapshot `execute()` gates on, then decide. */
function decide(p: GovernanceProposal, bars: Bars = CONFIG) {
  const snapshot = {
    seatEpoch: "1",
    quorum: p.tier === "high" ? bars.quorumHumanYes : bars.quorumYes,
    totalVotingPower: "3",
    totalHumanVotingPower: bars.totalHumanVotingPower,
    unanimityFastPath: bars.unanimityFastPath,
  };
  return decideAutoExecute({ snapshot, ...p }, NOW);
}

describe("decideAutoExecute", () => {
  it("skips anything not active", () => {
    for (const state of ["executed", "vetoed", "defeated"] as const) {
      assert.deepEqual(decide(proposal({ state })), {
        execute: false,
        reason: "not_active",
      });
    }
  });

  it("executes a low-tier proposal at quorum", () => {
    assert.deepEqual(decide(proposal()), {
      execute: true,
      via: "quorum",
    });
  });

  it("holds a low-tier proposal below quorum", () => {
    assert.deepEqual(decide(proposal({ yesVotes: 1 })), {
      execute: false,
      reason: "quorum_not_met",
    });
  });

  it("never spends gas to finalize a defeat", () => {
    // Lapsed and losing: the contract's execute() would mark it Defeated and
    // return success — bookkeeping the sweep must not pay for.
    const p = proposal({ deadline: NOW - 10, yesVotes: 1, noVotes: 2 });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "would_defeat",
    });
  });

  it("holds a low-tier proposal through its delay unless every human backs it", () => {
    const p = proposal({ eta: NOW + 600 });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "timelock_pending",
    });
    assert.deepEqual(decide({ ...p, yesHumanVotes: 2 }), {
      execute: true,
      via: "unanimity",
    });
  });

  it("skips a proposal that does not out-vote its noes while voting is open", () => {
    // Two agents for, the root against: quorum is met but the tally is a tie.
    assert.deepEqual(decide(proposal({ yesVotes: 2, noVotes: 2 })), {
      execute: false,
      reason: "outvoted",
    });
    const high = proposal({ tier: "high", yesHumanVotes: 1, noHumanVotes: 1, eta: NOW - 1 });
    assert.deepEqual(decide(high), {
      execute: false,
      reason: "outvoted",
    });
  });

  it("still executes past the deadline when the yeses hold", () => {
    const p = proposal({ deadline: NOW - 10, yesVotes: 2, noVotes: 1 });
    assert.deepEqual(decide(p), { execute: true, via: "quorum" });
  });

  it("holds a high-tier proposal through its timelock", () => {
    const p = proposal({ tier: "high", yesHumanVotes: 1, eta: NOW + 600 });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "timelock_pending",
    });
  });

  it("executes a high-tier proposal once the timelock elapses", () => {
    const p = proposal({ tier: "high", yesHumanVotes: 1, eta: NOW - 1 });
    assert.deepEqual(decide(p), {
      execute: true,
      via: "timelock_elapsed",
    });
  });

  it("takes the unanimity fast path only when every seated human backs it", () => {
    const unanimous = proposal({ tier: "high", yesHumanVotes: 2, eta: NOW + 600 });
    assert.deepEqual(decide(unanimous), {
      execute: true,
      via: "unanimity",
    });
    // Fast path off → the same tally waits for the timelock.
    assert.deepEqual(decide(unanimous, { ...CONFIG, unanimityFastPath: false }), {
      execute: false,
      reason: "timelock_pending",
    });
  });

  it("gates high tier on the human tally, not the total", () => {
    const p = proposal({ tier: "high", yesVotes: 5, yesHumanVotes: 0, eta: NOW - 1 });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "quorum_not_met",
    });
  });

  it("does not let agent no-weight defeat a lapsed high-tier proposal", () => {
    // Outvoted in total, backed by the humans: the contract executes it.
    const p = proposal({
      tier: "high",
      deadline: NOW - 10,
      eta: NOW - 1,
      yesVotes: 2,
      noVotes: 5,
      yesHumanVotes: 2,
      noHumanVotes: 0,
    });
    assert.deepEqual(decide(p), {
      execute: true,
      via: "timelock_elapsed",
    });
  });

  it("skips a lapsed high-tier proposal the human noes won", () => {
    // Ahead in total, refused by the humans: the contract marks it Defeated.
    const p = proposal({
      tier: "high",
      deadline: NOW - 10,
      eta: NOW - 1,
      yesVotes: 6,
      noVotes: 2,
      yesHumanVotes: 1,
      noHumanVotes: 2,
    });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "would_defeat",
    });
  });

  it("counts the human no tally before the deadline too", () => {
    const p = proposal({ tier: "high", eta: NOW - 1, yesHumanVotes: 1, noHumanVotes: 2 });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "outvoted",
    });
  });

  it("keeps defeating a lapsed low-tier proposal on total weight", () => {
    const p = proposal({
      deadline: NOW - 10,
      yesVotes: 2,
      noVotes: 3,
      yesHumanVotes: 2,
      noHumanVotes: 0,
    });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "would_defeat",
    });
  });

  it("skips a lapsed high-tier proposal whose human no tally is missing", () => {
    const p = proposal({ tier: "high", deadline: NOW - 10, eta: NOW - 1, yesHumanVotes: 1 });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "config_unreadable",
    });
  });

  it("skips rather than guesses when the snapshot or tally is unreadable", () => {
    assert.deepEqual(decideAutoExecute(proposal(), NOW), {
      execute: false,
      reason: "config_unreadable",
    });
    const p = proposal({ tier: "high", yesHumanVotes: undefined, eta: NOW - 1 });
    assert.deepEqual(decide(p), {
      execute: false,
      reason: "config_unreadable",
    });
  });
});

describe("autoExecuteEnabled", () => {
  it("is opt-in and reads only the exact flag", () => {
    assert.equal(autoExecuteEnabled({} as NodeJS.ProcessEnv), false);
    assert.equal(autoExecuteEnabled({ LACREW_AUTO_EXECUTE: "1" } as NodeJS.ProcessEnv), true);
    assert.equal(autoExecuteEnabled({ LACREW_AUTO_EXECUTE: "true" } as NodeJS.ProcessEnv), false);
  });
});
