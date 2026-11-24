---
title: "IPolicyModule"
---

The heart of the protocol. Modules stack on a node; first `DENY` wins; any `ESCALATE` routes upward.

```solidity
interface IPolicyModule {
    function check(
        address agent,
        address target,
        uint256 value,
        bytes calldata data
    ) external view returns (Verdict);
    // Verdict: ALLOW | ESCALATE | DENY
}
```

Standard modules (reference contracts):

| Module                  | Verdict behavior                                                                              |
| ----------------------- | --------------------------------------------------------------------------------------------- |
| `SpendCapPolicy`        | ESCALATE over per-agent / default cap                                                         |
| `WhitelistPolicy`       | DENY non-whitelisted targets                                                                  |
| `RateLimitPolicy`       | ESCALATE when window count ≥ max (router calls `record`)                                      |
| `CumulativeValuePolicy` | ESCALATE when settled value in the window would cross the budget (router calls `recordValue`) |
| `TimeWindowPolicy`      | DENY outside daily UTC window                                                                 |
| Custom                  | Third-party `IPolicyModule` implementations                                                   |

`PolicyStack` composes modules: **first DENY wins**; any ESCALATE is sticky; else ALLOW.

## Cumulative value budgets

`SpendCapPolicy` bounds one call, so ten calls just under the cap all pass. `CumulativeValuePolicy(maxValue, maxValuePerTarget, windowSeconds)` sums what actually settled instead: it escalates when the next spend would take the agent's value inside the window over `maxValue`, and, when `maxValuePerTarget` is non-zero, over that budget to a single payee. A spend that escalates and is then approved still counts, so an approved overage fills the window it landed in.

The router charges the module through `IValueRecorder.recordValue(agent, target, value)` on every settled spend with value — `setValueRecorder` for the org default, `setNodeValueRecorder` for a node with its own module. As with `RateLimitPolicy`, the recorder is bound once by the deployer (`setRecorder`), and both the global and the node's recorder are protected targets an agent cannot call through the router. The SDK's `deployCumulativeValuePolicy` deploys one with its recorder locked to the org's router; binding it takes `setNodePolicy` plus `proposeSetNodeValueRecorder`.

Windows are anchored at the first settled spend after the previous one lapsed. Value settled without escalation is at most `maxValue` within one window, and at most `2 × maxValue` across any span of `windowSeconds` that straddles two windows.

## Per-node stacks

`EscalationRouter` keeps a default `policy` plus optional `policyOf[node]` overrides (`setNodePolicy`). Propose checks the agent's stack; resolve checks the approver's stack. DeployMockOrg wires a worker stack (whitelist + spend cap + rate limit) and a manager stack (whitelist + spend cap, no rate limit).

## TODO

- TODO: Spec module registry + upgrade path via GovernanceModule
- TODO: Publish ABI + abitype package for off-chain preflight
