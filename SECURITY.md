# Security

LaCrew’s product promise is **bounded blast radius**: agents can spend only what policy allows, overages escalate, and constitutional changes go through governance with a human veto on high-tier actions.

## Status (honest)

This repository is **pre-audit** Phase 0/1 scaffolding. Treat all deployments as test-only until a professional audit is published (see PRD F1.2).

| Control                                                            | Code status                                                                                                                                                          |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Policy stack (DENY / ESCALATE / ALLOW)                             | Implemented (+ fuzz: first-DENY-wins)                                                                                                                                |
| Escalation climb + ALLOW spend execution                           | Implemented (EOA/router path; not ERC-4337 yet)                                                                                                                      |
| Treasury conservation                                              | Invariant suite (reserved ≤ balance; sum allowances)                                                                                                                 |
| Governance execute → OrgRegistry / Treasury / EpochStreamer grants | Implemented (role-weighted seats; human high-tier quorum)                                                                                                            |
| High-tier timelock + human veto                                    | Implemented (+ fuzz: unbypassable timelock / veto)                                                                                                                   |
| Multi-human seat admin                                             | Implemented (`admitHuman` / `removeHuman` governance-only; last human seat unremovable)                                                                              |
| Session keys                                                       | `SessionRegistry` ephemeral EOAs; `propose` gated by key + `maxValue` + optional target; not ERC-4337                                                                |
| Bootstrap authority                                                | `Treasury` / `EscalationRouter` setters and `RateLimitPolicy.setRecorder` are deployer-only until a governor is bound — never permissionless                         |
| Router as a confused deputy                                        | `EscalationRouter.propose` refuses the contracts that trust the router as `msg.sender` (itself, Treasury, SessionRegistry, its rate recorders), whatever policy says |
| Call settlement                                                    | Pull-based: target approved for exactly `value`, approval revoked after the call, unpulled rest refunded; the treasury token is a protected target; `nonReentrant`   |
| Cumulative spend                                                   | `CumulativeValuePolicy` budgets settled value per agent (and per target) over a window, so many small ALLOWs escalate once they add up                               |
| Non-vanilla tokens                                                 | Fee-on-transfer refused (`TransferAmountMismatch`); rebasing unsupported (`Treasury.shortfall()`); issuer blocklists scoped per asset stack (`SPEC.md §4.2`)         |
| Governor hand-over                                                 | `GovernanceModule` forces High tier for any `setGovernor(address)` payload, same as proposals targeting the module itself                                            |
| Issuer key lifetime                                                | `SessionRegistry.maxIssuerTtl` (root-set, 30 days default) bounds how far ahead the issuer may set a session expiry; root is unbound                                 |
| Professional audit / Slither gate                                  | Slither in CI (`fail-on: high`); no formal audit yet                                                                                                                 |

Docs that describe ERC-4337 / passkey AA roots are **design targets**, not current guarantees. Session scoping on `propose` is live on Anvil.

## Threat model (intended)

| Threat                   | Intended bound                                                                                                          |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Compromised agent        | Remaining streamed allowance on whitelisted targets; escalations climb the tree                                         |
| Compromised orchestrator | Session keys **plus every manager seat it holds a key for** (below) — never a passkey-Safe root, never treasury custody |
| Compromised quorum       | High-tier timelock + veto from any funded human seat                                                                    |
| Compromised root         | Bounded by the other human seats (below); still holds the wallet in v1                                                  |

### The orchestrator keyring is a trust boundary

"The orchestrator only holds session keys" is true of **workers**, not of
**AI-manager seats**. A manager approves an escalated intent by sending
`EscalationRouter.resolve` from its own node address (`SPEC.md §5`), and the
reference orchestrator signs that call itself, from its keyring:

| Key the process may hold | Env                         | What it signs                                                          |
| ------------------------ | --------------------------- | ---------------------------------------------------------------------- |
| Main account             | `LACREW_PRIVATE_KEY`        | `propose`, bootstrap/demo writes; `resolve` when no manager key is set |
| Manager seat             | `MANAGER_PRIVATE_KEY`       | `resolve` for intents awaiting that manager; its governance vote       |
| Session issuer           | `LACREW_ISSUER_PRIVATE_KEY` | `SessionRegistry.issue` / `revoke`                                     |

So the boundary an attacker has to cross is **the orchestrator host and its
secrets**, not a worker's sandbox. Compromising a worker buys that worker's
session key. Compromising the orchestrator buys every key above, and with them:

| A stolen orchestrator keyring can                                                                                        | It cannot                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Approve any intent awaiting a manager seat it holds, up to **that manager's own policy stack** (`resolve` re-checks it)  | Approve past the manager's bounds — over them the intent climbs toward the human root                                      |
| Propose as its workers, then approve its own proposals at manager depth — a self-dealing loop capped by the manager tier | Resolve as a passkey-Safe root: that seat signs only through the Safe's own `execTransaction`, with no key in this process |
| Mint session keys through the issuer role, within `maxIssuerTtl` (every issue emits `SessionIssued`)                     | Move treasury balance directly, or pass a high-tier proposal (agent yes-weight never satisfies high tier; humans can veto) |
| Cast the manager seat's governance vote on low-tier proposals                                                            | Survive the root revoking its sessions or governance removing the manager seat                                             |

**Blast radius, stated plainly:** up to the manager tier's remaining bounds,
per manager seat whose key the orchestrator holds, until a human notices and
revokes. Escalation still works as designed above that line — the passkey root
is outside the boundary — which is why the bound is the manager's policy and
not the treasury.

Two consequences for operators:

1. **The manager's policy stack is the real ceiling on an orchestrator
   compromise.** Size manager spend caps and rate limits as "what we would lose
   if the orchestrator host were owned for one detection window", not as a
   convenience threshold.
2. **High-value manager seats should not live in the orchestrator's keyring.**
   A manager seat can be any address. Holding it in a Safe (passkey or
   multi-signer) moves its approvals outside the boundary, at the cost of a
   human-speed signature for every intent that reaches it. The orchestrator's
   Safe relay path (`execTransaction` for `resolve`) ships today for the
   **root** seat only; using it for manager seats is a design target, not a
   current guarantee. Until then, an org that wants a manager outside the
   keyring runs that manager's key in a separate signer and leaves
   `MANAGER_PRIVATE_KEY` unset.

The cloud orchestrator is the same package under the same boundary: a manager
key held by the hosted orchestrator is a key the hosted operator could sign
with. Root custody never enters it — that is the non-custodial claim — but
manager-tier approvals do, by design, when the manager seat is an AI agent the
cloud runs.

### Two humans: what a compromise of one actually costs

An org with human seats A (the root) and B is the shape agency partners and
clubs ask for. What a stolen A key buys, spelled out:

| A (root) alone can                                               | A alone cannot                                                                                      |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Retune quorums and timing; seat and re-weight **agent** seats    | Admit a human, re-weight one, or fire B — seat admin over humans executes only as a passed proposal |
| Vote its own weight; veto anything                               | Vote B's weight, or stop B vetoing back                                                             |
| Propose anything, including firing B                             | Land it: B vetoes, and B's veto needs no quorum and no delay                                        |
| Sign as session issuer and move the org wallet in v1 (see below) | Reach the treasury through governance without B's silence                                           |

So the multi-human guarantee this repo actually ships is **constitutional, not
custodial**: a compromised A cannot rewrite who governs the org, because B
remains seated and can veto. The last human seat cannot be removed at all, by
anyone, so an org can never be left with agents as its only electorate.

Two exposures are real and deliberately not papered over:

1. **The wallet is still single-holder.** The session-issuer path and the org's
   Safe key off one root address in v1. A compromised A can therefore still move
   funds the wallet controls, on the wallet's own terms — governance is not in
   that path. A club that needs two humans to jointly hold funds must configure
   a 2-of-2 Safe at the wallet layer today. Multi-holder root custody
   (`SPEC.md §6.1`) is a design target, not a current guarantee.
2. **A veto is a stop, not a recovery.** B can block every proposal A makes and
   cannot, alone, evict A: removing A's seat is itself a proposal, and A can
   veto it. Two compromised-but-opposed humans deadlock the constitution rather
   than one winning it. That is the intended failure mode — a frozen org is
   recoverable by agreement; a captured one is not — but it means "add a second
   human" is protection against a rogue partner, not a key-recovery mechanism.

Revoking the root's seat also revokes its parameter admin and its veto, so
governance can demote a root to an ordinary former member — but only while
another human remains seated, and only with that root unable to veto the
proposal, which in practice means with its cooperation.

### Losing or rotating the root key

The root address is replaceable onchain (`SPEC.md §6.2`). One High-tier
`GovernanceModule.rotateRoot` proposal moves the root of the tree, of session
admin and of the governance seat together, and with it the fallback resolve
authority `EscalationRouter` reads from the tree. A **lost** root key is
therefore recoverable by the other humans (or, for a solo org, by the root
rotating to a new key while it still holds the old one). A **compromised** one
is recoverable only if its holder does not veto the rotation: the veto above
still applies, by design.

Independently of rotation, governance can revoke any session and replace the
session issuer (`SessionRegistry.setIssuer`, High tier) without the root's
signature, so a compromised orchestrator issuer is not left in place waiting
for the root.

## Reporting a vulnerability

Please email **security@lacrew.xyz** (or open a private GitHub security advisory on this repo) with:

1. Affected contracts/packages and commit SHA
2. Impact description (funds at risk, privilege escalation, DoS)
3. Proof of concept (local Anvil preferred)

We aim to acknowledge within **72 hours**. Do not open a public issue for fund-draining bugs until we confirm a fix or disclosure timeline.

## Safe testing

- Prefer Anvil / Ethereum Sepolia with throwaway keys
- Never send mainnet funds to undeployed or unaudited addresses
- Published addresses will live in `packages/core/deployments/` and on `lacrew.xyz/protocol` once live
