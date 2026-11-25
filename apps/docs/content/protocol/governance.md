---
title: "Governance"
---

LaCrew splits decisions into two regimes and refuses to confuse them.

## Operational vs constitutional

| Regime         | Examples                                                        | Path                           |
| -------------- | --------------------------------------------------------------- | ------------------------------ |
| Operational    | Spend, execute, escalate                                        | Policy stack + escalation tree |
| Constitutional | Hire/fire agents, change budgets, upgrade modules, admit humans | GovernanceModule               |

## Risk tiers

- **Low tier** — only actions on the curated `lowTierSelector` allow-list (seeded with an agent hire: `OrgRegistry.addNode` with a non-`HumanRoot` kind). Executes once all-seat yes-weight meets the effective quorum **and** `lowTierDelay` (default 1 day) has passed since it was proposed, so every human seat has a window to vote it down or veto it. Unanimous human yes skips the delay. Every other action (firing, suspending, reparenting, treasury spenders and streams, router wiring and policies, grants, governor transfers, this module) is High tier.
- **High tier** — treasury-touching or policy-touching. Voting deadline + timelock (`eta`, default 1 day); any funded human seat may **`veto`** before execute. When **all** human voting weight has voted yes, execution skips the timelock (`unanimityFastPath`, default on) — the delay protects humans who have not weighed in, and unanimity means there are none left.

## Defeat

A proposal executes only while its yes-weight exceeds its no-weight, and a tie does not carry. While voting is open, `execute` on a tally that does not carry reverts `Outvoted`, and the proposal stays open for more votes. After the voting deadline, `execute` closes it as `Defeated` instead. Each tier is carried and defeated by the electorate that can pass it:

| Tier | Passes on                               | Carried while                  |
| ---- | --------------------------------------- | ------------------------------ |
| Low  | all-seat yes-weight meets the quorum    | `yesVotes > noVotes`           |
| High | human yes-weight meets the human quorum | `yesHumanVotes > noHumanVotes` |

Agent seats may vote on a high-tier proposal, and their weight shows in `yesVotes` / `noVotes`, but it decides nothing there: it cannot defeat a proposal the humans backed, and it cannot rescue one the humans voted down.

`veto` needs a proposal that exists. Vetoing an id nobody has proposed yet reverts with `ProposalNotFound`.

The outgoing root cannot veto its own replacement. On a `rotateRoot` proposal naming a different root, once another seated Human has voted yes, the root's `veto` reverts `OutgoingRootVetoIgnored`. That Human's seat and power are read at veto time, so a yes from someone unseated since no longer counts, and the root's own yes never does. The root's veto stands before that yes vote and on every other proposal, an org whose only Human is the root keeps it, and any other Human's veto still works.

## Execution

Only a seated voter (`votingPower > 0`), or the root while it may act, can `propose`. Proposals bind `target` + `calldata`. On `execute`, the module calls `target.call(data)` after quorum and the tier's `eta` (high-tier timelock or low-tier delay) or human unanimity. OrgRegistry / Treasury accept mutations from the governor address after bootstrap `setGovernor`. Proposals may target the GovernanceModule itself to retune quorums, weights, or timing — but only at High tier, so agent seats can never re-weight the electorate through a low-tier vote.

## Voting power

Seats are role-weighted (`votingPower` + `seatRole`): humans decide high-tier final say; agent yes-weight counts for low tier only. The root is seeded as a human seat at deploy (default weight 2 vs agent weight 1), so a founder outweighs any single agent seat from block one.

**Bootstrap safety:** the quorum `execute()` enforces is the configured value clamped to the seated weight (`effectiveQuorumYes` / `effectiveQuorumHumanYes`). A solo founder is never deadlocked behind a quorum sized for seats that do not exist yet; seating more weight restores the configured bar automatically.

## More than one human

An org can seat any number of humans — agency partners, a club, a community-funded crew — and the roster is itself constitutional:

| Call                                  | Who may make it                              | Tier          |
| ------------------------------------- | -------------------------------------------- | ------------- |
| `setVotingPower(voter, power, Agent)` | The root address, directly                   | —             |
| `admitHuman(human, power)`            | The module itself, i.e. an executed proposal | High (forced) |
| `removeHuman(human)`                  | The module itself                            | High (forced) |

There is no key that can hand out a human seat. `admitHuman` / `removeHuman` — and any `setVotingPower` touching a `Human` seat — accept only the module as caller, and `propose` forces High tier on anything aimed at the module, so admitting a partner passes the humans already seated and any one of them can veto it. `humanSeatCount` reports the head count (weight answers a different question).

**The last human seat cannot be revoked** (`LastHumanSeat`) — not by `removeHuman`, not by demoting it to an agent seat. Agent yes-weight never satisfies high tier, so an org with no human left would be frozen rather than agent-run.

Veto is shared, not delegated: every funded human seat holds it outright, with no quorum and no delay. The root's _extra_ privileges (quorums, timing, agent seats) hold only while it still holds a human seat of its own — revoke the seat and the address is a stranger to the module. The one carve-out is a module deployed with `rootPower_ = 0`: while `humanSeatCount` is zero, the root may seat the first human directly, and the carve-out closes behind it.

A seat with power 0 is a revoked seat, not an observer — `vote()` reverts `NoVotingPower`, and veto rights derive from funded human seats. Watching without voting is a workspace concern, not a chain one.

In the tree, extra humans are `HumanRoot` nodes parented to the org's single root node (one tree, not a forest). The node draws the chart; the seat carries the authority. See [SPEC §3.1 / §6.1](../spec.md) and [Security model](./security.md) for what a compromise of one human out of two actually costs.

## Configuration

All parameters are onchain. Everything above the seat rows is adjustable by the root directly (while it holds a human seat) or via a High-tier proposal targeting the module; the human roster is governance-only:

| Parameter                                 | Default                                  | Setter                                         |
| ----------------------------------------- | ---------------------------------------- | ---------------------------------------------- |
| `quorumYes` (low tier, all seats)         | 2                                        | `setQuorumYes`                                 |
| `quorumHumanYes` (high tier, human seats) | 1                                        | `setQuorumHumanYes`                            |
| `votingPeriod`                            | 3 days (bounds 1h–30d)                   | `setTiming`                                    |
| `highTierTimelock`                        | 1 day (bounds 0–30d)                     | `setTiming`                                    |
| `unanimityFastPath`                       | on                                       | `setUnanimityFastPath`                         |
| `lowTierDelay`                            | 1 day (bounds 0–30d)                     | `setLowTierDelay`                              |
| `lowTierSelector` (low-tier allow-list)   | `addNode` (never `setGovernor`)          | `setLowTierSelector`                           |
| Agent seat weight                         | manager: 1 agent (deploy script)         | `setVotingPower`                               |
| Human seat weight / roster                | root: 2 human (constructor `rootPower_`) | `admitHuman` / `removeHuman` (governance only) |

## Current scaffolding gaps

- Session-key / passkey root binding not onchain yet
- Epoch streaming is on-demand (`runNextEpoch` / `POST /epoch`); `QueueProvider` + pg-boss can schedule epochs when `DATABASE_URL` is set
