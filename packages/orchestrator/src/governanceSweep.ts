/**
 * Governance auto-execute sweep (F0.6) — the decision half.
 *
 * Mirrors `GovernanceModule.execute()`'s acceptance rules so the sweep only
 * spends gas on proposals the chain would actually execute. The mirror is an
 * optimization, never the enforcer: a proposal it wrongly deems executable
 * still just reverts onchain, and one it wrongly skips stays available to a
 * human press.
 *
 * Two deliberate asymmetries with the contract:
 *  - `execute()` on a lapsed, losing proposal marks it Defeated and returns
 *    success. The sweep skips that case (`would_defeat`) — finalizing defeats
 *    costs gas for bookkeeping nobody asked this process to do.
 *  - Anything unreadable (missing human tally on a high-tier row) is skipped,
 *    not guessed.
 *
 * Each tier is carried by the electorate that can pass it, and only while its
 * yes-weight exceeds its no-weight: a low-tier ballot by total weight, a
 * high-tier one by human weight alone. Agent seats review a high-tier proposal;
 * however many of them vote no, they cannot defeat it. Both tiers wait out
 * their `eta` (the high-tier timelock or the low-tier delay) unless every
 * human seated when the proposal was created has voted yes.
 *
 * The quorum and the unanimity bar come from the proposal's own snapshot,
 * the values `execute()` gates on; the live governance config would drift
 * from them as soon as a seat or a quorum changed after the proposal.
 */

import type { GovernanceProposal } from "@lacrew/core";

export type SweepDecision =
  | { execute: true; via: "timelock_elapsed" | "unanimity" | "quorum" }
  | {
      execute: false;
      reason:
        | "not_active"
        | "quorum_not_met"
        | "timelock_pending"
        | "outvoted"
        | "would_defeat"
        | "config_unreadable";
    };

export function decideAutoExecute(p: GovernanceProposal, nowSeconds: number): SweepDecision {
  if (p.state !== "active") return { execute: false, reason: "not_active" };

  const lapsed = p.deadline > 0 && nowSeconds > p.deadline;
  const high = p.tier === "high";

  // The tally each tier is carried by: human weight alone on high tier, all
  // seat weight on low tier. Agent no-weight never decides a high-tier ballot.
  let yes: number;
  let no: number;
  if (high) {
    if (p.yesHumanVotes === undefined) return { execute: false, reason: "config_unreadable" };
    yes = p.yesHumanVotes;
    if (lapsed && p.noHumanVotes === undefined) {
      return { execute: false, reason: "config_unreadable" };
    }
    no = p.noHumanVotes ?? 0;
  } else {
    yes = p.yesVotes;
    no = p.noVotes;
  }
  const carried = yes > no;
  // A lapsed ballot that is not carried: execute() would finalize it as Defeated.
  if (lapsed && !carried) return { execute: false, reason: "would_defeat" };

  const snapshot = p.snapshot;
  if (snapshot === undefined) return { execute: false, reason: "config_unreadable" };
  if (BigInt(yes) < BigInt(snapshot.quorum)) return { execute: false, reason: "quorum_not_met" };

  // Both tiers wait out their delay (high-tier timelock, low-tier delay) unless
  // every human seated at creation has voted yes.
  const totalHuman = BigInt(snapshot.totalHumanVotingPower);
  const unanimous =
    snapshot.unanimityFastPath && totalHuman > 0n && BigInt(p.yesHumanVotes ?? 0) >= totalHuman;
  const pending = nowSeconds < p.eta;
  if (pending && !unanimous) return { execute: false, reason: "timelock_pending" };

  // Voting is still open and the noes hold their own: execute() reverts Outvoted.
  if (!carried) return { execute: false, reason: "outvoted" };

  if (pending) return { execute: true, via: "unanimity" };
  return { execute: true, via: high ? "timelock_elapsed" : "quorum" };
}

/** Opt-in flag: executing governance without a human press is a policy decision. */
export function autoExecuteEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.LACREW_AUTO_EXECUTE === "1";
}
