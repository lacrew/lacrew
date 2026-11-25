# Incident playbook: containing and recovering an org

The emergency story for a LaCrew org (deployment plan §3.6). The contracts are not upgradeable
and have no protocol-wide admin, so every step below is taken by the **org's own** humans.
LaCrew cannot pause or drain anyone's org.

## Decision

Containment and recovery use the exits the contracts already have. No new root-only withdrawal
is added: it would be a second path to the treasury that bypasses the governance quorum,
timelock and veto, which is the property the audit is meant to confirm.

- **Stop (no vote needed):** any seated human, or the governance authority, calls `pause()` on
  `Treasury` and `EscalationRouter`. Settlement, streaming and new proposals halt. Reject and
  cancel paths stay open. Only governance can `unpause()`.
- **Cut off identities:** `OrgRegistry.setActive(node, false)` deactivates an agent, and
  `SessionRegistry.revoke(sessionId)` kills a session key. A removed or re-added node starts
  a new generation, so its old intents and allowances do not revive.
- **Reclaim budget:** `Treasury.revokeAllowance(node, amount)` returns an allowance to the
  liquid balance. It is governor-only, so it goes through a proposal.
- **Recover funds:** `Treasury.withdraw(to, amount)` is governor-only and always High tier:
  human quorum, timelock, and a veto window. It moves only the unreserved balance, so revoke
  allowances first.
- **Compromised root:** a High-tier `rotateRoot` proposal replaces the root key, its seat, and
  the root of `OrgRegistry` and `SessionRegistry` in one transaction.

## Steps

1. **Pause** both contracts from any human seat: `Treasury.pause()`, `EscalationRouter.pause()`.
2. **Deactivate** the affected agents and **revoke** their sessions.
3. **Propose** (High tier) `revokeAllowance` for each affected node, then `withdraw` to the
   recovery address. If the root is the compromised party, propose `rotateRoot` first.
4. **Wait out** the timelock. Any seated human can veto a mistaken proposal during it.
   A proposal that is not executed within `EXECUTION_WINDOW` (14 days) after its delay expires
   and has to be proposed again.
5. **Execute**, confirm balances, then decide whether to `unpause()` through governance or
   migrate to a fresh stack.

## Rehearsal

The unit coverage is `EmergencyPause.t.sol`, `RootRotation.t.sol` and the Treasury withdraw
tests. The live rehearsal on a fork (stage 0) and on Base Sepolia (stage 2) follows the steps
above and is part of those stages' exit criteria in the
[deployment plan](./deployment-plan.md).
