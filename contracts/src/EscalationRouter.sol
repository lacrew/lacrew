// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPolicyModule, Verdict} from "./interfaces/IPolicyModule.sol";
import {IOrgRegistry} from "./interfaces/IOrgRegistry.sol";
import {IRateRecorder} from "./interfaces/IRateRecorder.sol";
import {IValueRecorder} from "./interfaces/IValueRecorder.sol";
import {ITreasurySpender} from "./interfaces/ITreasurySpender.sol";
import {ISettlementContext} from "./interfaces/ISettlementContext.sol";
import {SessionRegistry} from "./SessionRegistry.sol";
import {SessionScopes} from "./SessionScopes.sol";

/// @title EscalationRouter
/// @notice Creates pending intents when a policy returns ESCALATE; parents approve upward.
///         Only active nodes resolve, and only for agents that are still active; the
///         org root covers an approver that has been deactivated or removed.
/// @dev On ALLOW (propose or final resolve), optionally spends allowance and calls `target`.
///      When `sessionRegistry` is set, `propose` must be signed by a valid session key for `agent`
///      (or by `agent` itself for future AA EOAs).
///
///      Settlement has two shapes, chosen by whether the action carries calldata:
///      - **Payment** (`value > 0`, empty `data`): the treasury transfers `value` to `target`.
///      - **Call** (`value > 0`, non-empty `data`): pull-based. The router takes `value` from the
///        treasury, approves `target` for exactly `value`, calls it, revokes the approval and
///        returns whatever `target` did not pull to the agent's allowance. A DEX or any
///        approve/transferFrom protocol works as-is, a contract that ignores the tokens costs
///        nothing, and a failed call costs nothing. Only what `target` kept is charged to the
///        value recorder.
contract EscalationRouter is ReentrancyGuard, ISettlementContext {
    using SafeERC20 for IERC20;

    struct Intent {
        address agent;
        address target;
        uint256 value;
        bytes data;
        address awaitingApprover;
        bool resolved;
        bool approved;
    }

    IOrgRegistry public immutable orgRegistry;
    /// @notice Default policy stack when `policyOf[node]` is unset.
    IPolicyModule public policy;
    ITreasurySpender public treasury;
    IRateRecorder public rateRecorder;
    SessionRegistry public sessionRegistry;
    /// @notice Deployer. Holds bootstrap authority until `governor` is bound, so the
    ///         wiring window is not open to whoever sees the deployment first.
    address public immutable deployer;
    /// @notice GovernanceModule (or the deployer while bootstrapping) for the setters below.
    address public governor;

    /// @notice Emergency stop: while set, anything that would settle (`_finalizeAction`)
    ///         reverts. Rejections and escalation up the tree stay open, so pending
    ///         intents can still be closed.
    bool public paused;

    /// @notice When an intent stops being resolvable, and which incarnation of its agent and
    ///         of its current approver it was made under.
    /// @dev Kept beside `Intent` so the public `intents` getter keeps its shape. A
    ///      generation that no longer matches `OrgRegistry.generationOf` means the address
    ///      was removed and re-added since, so the intent belongs to someone else's seat.
    struct IntentLife {
        uint64 expiresAt;
        uint64 agentGeneration;
        uint64 approverGeneration;
    }

    /// @notice Lifetime given to a new intent, in seconds. Governed.
    uint64 public intentTtl = 7 days;
    uint64 public constant MIN_INTENT_TTL = 1 hours;
    uint64 public constant MAX_INTENT_TTL = 365 days;

    uint256 public nextIntentId = 1;
    mapping(uint256 => Intent) public intents;
    mapping(uint256 => IntentLife) public intentLife;
    /// @notice Optional per-node policy stack override (falls back to `policy`).
    mapping(address => IPolicyModule) public policyOf;
    /// @notice Optional per-node rate recorder (falls back to `rateRecorder`).
    /// A node bound to its own RateLimitPolicy needs its executed actions
    /// counted in that module's windows; the global recorder never sees them.
    mapping(address => IRateRecorder) public rateRecorderOf;
    /// @notice Optional value recorder (a CumulativeValuePolicy) charged with every
    ///         settled spend, so its window budget sees what actually left treasury.
    IValueRecorder public valueRecorder;
    /// @notice Optional per-node value recorder (falls back to `valueRecorder`).
    mapping(address => IValueRecorder) public valueRecorderOf;

    /// @dev How many recorder slots (global or per-node, rate or value) currently point at an
    ///      address. A recorder trusts the router as `msg.sender`, so any bound one is off limits
    ///      as a target for every agent, not just the node it is bound to. Counted rather than
    ///      flagged because one recorder may serve several nodes.
    mapping(address => uint256) private _recorderBindings;

    /// @dev The action being executed: its target and what treasury paid it. Set only
    ///      around the target call in `_finalizeAction`, so a target reads its own
    ///      payment through `currentSettlement` and nothing else's.
    address private transient _settlingTarget;
    uint256 private transient _settlingPaid;

    event IntentCreated(uint256 indexed intentId, address indexed agent, address awaitingApprover);
    event IntentEscalated(uint256 indexed intentId, address indexed from, address indexed to);
    event IntentResolved(uint256 indexed intentId, bool approved);
    /// @notice An intent was closed unapproved after its expiry, by anyone.
    event IntentExpired(uint256 indexed intentId, address indexed closedBy);
    event IntentTtlUpdated(uint64 intentTtl);
    /// @notice `value` is what the action cost the agent's allowance: the full value for a
    ///         payment, and for a pull-settled call only what the target kept.
    /// @dev `callOk` is always true: a failing target call reverts the whole action
    ///      (see `_finalizeAction`). The field stays for ABI stability.
    event ActionExecuted(
        address indexed agent,
        address indexed target,
        uint256 value,
        bool callOk
    );
    event TreasuryUpdated(address indexed treasury);
    event RateRecorderUpdated(address indexed rateRecorder);
    event SessionRegistryUpdated(address indexed sessionRegistry);
    event NodePolicyUpdated(address indexed node, address indexed policyModule);
    event NodeRateRecorderUpdated(address indexed node, address indexed rateRecorder);
    event ValueRecorderUpdated(address indexed valueRecorder);
    event NodeValueRecorderUpdated(address indexed node, address indexed valueRecorder);
    event GovernorUpdated(address indexed governor);
    /// @notice A pull settlement left `returned` unpulled; it went back to `agent`'s allowance.
    event SettlementReturned(address indexed agent, address indexed target, uint256 returned);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error IntentNotFound(uint256 intentId);
    error IntentAlreadyResolved(uint256 intentId);
    error IntentHasExpired(uint256 intentId, uint64 expiresAt);
    error IntentNotExpired(uint256 intentId, uint64 expiresAt);
    error InvalidIntentTtl(uint64 ttl);
    error NotAwaitingApprover(address caller);
    error UnexpectedVerdict(Verdict verdict);
    error NoApprover(address agent);
    error InactiveAgent(address agent);
    error InactiveApprover(address approver);
    error NotAuthorized(address caller);
    error InvalidSession(address agent, address key);
    error SessionValueExceeded(address agent, uint256 value, uint256 maxValue);
    error SessionTargetDenied(address agent, address target, address allowedTarget);
    error SessionScopeDenied(address agent, uint256 required, uint256 granted);
    error SessionTimeWindowDenied(address agent);
    /// @dev The router is `Treasury.spender`, `SessionRegistry.escalationRouter` and the
    ///      bound recorder of its rate and value modules. Letting an agent aim a policy-admitted
    ///      call at one of those would lend it the router's own authority. The treasury's token
    ///      is protected too: the router holds it during a pull settlement, and a call to the
    ///      token itself would spend or approve away that balance outside the settlement.
    error ProtectedTarget(address target);
    error ZeroAddress();
    error EnforcedPause();
    /// @notice The target call reverted without revert data; the whole action is undone.
    error ActionCallFailed(address target);
    error AlreadyPaused();
    error NotPaused();

    constructor(address orgRegistry_, address policy_) {
        if (orgRegistry_ == address(0)) revert ZeroAddress();
        orgRegistry = IOrgRegistry(orgRegistry_);
        policy = IPolicyModule(policy_);
        deployer = msg.sender;
    }

    /// @notice Bind constitutional authority. The deployer binds it first; then only governor.
    function setGovernor(address governor_) external {
        if (governor_ == address(0)) revert ZeroAddress();
        _onlyGovernorOrBootstrap();
        governor = governor_;
        emit GovernorUpdated(governor_);
    }

    /// @notice Emergency stop. Any active human seat in the org tree, or the current
    ///         governance authority, may pause; only that authority (the governor once
    ///         bound, the deployer until then) can unpause, so lifting it goes through
    ///         governance while stopping it needs no vote.
    function pause() external {
        if (paused) revert AlreadyPaused();
        if (!_isHumanSeat(msg.sender) && msg.sender != _authority()) revert NotAuthorized(msg.sender);
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Lift the emergency stop.
    function unpause() external {
        _onlyGovernorOrBootstrap();
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Set the lifetime of intents created from now on.
    function setIntentTtl(uint64 ttl) external {
        _onlyGovernorOrBootstrap();
        if (ttl < MIN_INTENT_TTL || ttl > MAX_INTENT_TTL) revert InvalidIntentTtl(ttl);
        intentTtl = ttl;
        emit IntentTtlUpdated(ttl);
    }

    /// @notice Wire treasury for ALLOW execution.
    function setTreasury(address treasury_) external {
        _onlyGovernorOrBootstrap();
        treasury = ITreasurySpender(treasury_);
        emit TreasuryUpdated(treasury_);
    }

    /// @notice Wire rate-limit recorder.
    function setRateRecorder(address rateRecorder_) external {
        _onlyGovernorOrBootstrap();
        _rebind(address(rateRecorder), rateRecorder_);
        rateRecorder = IRateRecorder(rateRecorder_);
        emit RateRecorderUpdated(rateRecorder_);
    }

    /// @notice Wire SessionRegistry so propose requires a valid session key.
    function setSessionRegistry(address sessionRegistry_) external {
        _onlyGovernorOrBootstrap();
        sessionRegistry = SessionRegistry(sessionRegistry_);
        emit SessionRegistryUpdated(sessionRegistry_);
    }

    /// @notice Bind a policy stack to a node. Pass address(0) to clear (use default `policy`).
    function setNodePolicy(address node, address policyModule) external {
        _onlyGovernorOrBootstrap();
        if (node == address(0)) revert ZeroAddress();
        policyOf[node] = IPolicyModule(policyModule);
        emit NodePolicyUpdated(node, policyModule);
    }

    /// @notice Bind a node's own rate recorder (its custom RateLimitPolicy).
    /// Pass address(0) to clear (fall back to the global `rateRecorder`).
    function setNodeRateRecorder(address node, address rateRecorder_) external {
        _onlyGovernorOrBootstrap();
        if (node == address(0)) revert ZeroAddress();
        _rebind(address(rateRecorderOf[node]), rateRecorder_);
        rateRecorderOf[node] = IRateRecorder(rateRecorder_);
        emit NodeRateRecorderUpdated(node, rateRecorder_);
    }

    /// @notice Wire the value recorder charged with every settled spend.
    function setValueRecorder(address valueRecorder_) external {
        _onlyGovernorOrBootstrap();
        _rebind(address(valueRecorder), valueRecorder_);
        valueRecorder = IValueRecorder(valueRecorder_);
        emit ValueRecorderUpdated(valueRecorder_);
    }

    /// @notice Bind a node's own value recorder (its custom CumulativeValuePolicy).
    /// Pass address(0) to clear (fall back to the global `valueRecorder`).
    function setNodeValueRecorder(address node, address valueRecorder_) external {
        _onlyGovernorOrBootstrap();
        if (node == address(0)) revert ZeroAddress();
        _rebind(address(valueRecorderOf[node]), valueRecorder_);
        valueRecorderOf[node] = IValueRecorder(valueRecorder_);
        emit NodeValueRecorderUpdated(node, valueRecorder_);
    }

    /// @notice Whether `account` is bound as any rate or value recorder, global or per-node.
    function isBoundRecorder(address account) public view returns (bool) {
        return _recorderBindings[account] != 0;
    }

    function _rebind(address oldRecorder, address newRecorder) private {
        if (oldRecorder == newRecorder) return;
        if (oldRecorder != address(0)) _recorderBindings[oldRecorder]--;
        if (newRecorder != address(0)) _recorderBindings[newRecorder]++;
    }

    /// @notice Propose an action; ALLOW executes spend+call, ESCALATE creates an intent, DENY reverts.
    function propose(
        address agent,
        address target,
        uint256 value,
        bytes calldata data
    ) external nonReentrant returns (uint256 intentId, Verdict verdict) {
        IOrgRegistry.Node memory agentNode = orgRegistry.getNode(agent);
        if (!agentNode.active) revert InactiveAgent(agent);
        _requireUnprotectedTarget(target, value, data.length);
        uint256 scopeMask = _requireValidSession(agent, target, value);
        // Count this propose against the key's rate limit (no-op unless wired and
        // the key has one). Reverts here roll back the count, so only a propose
        // that actually proceeds is charged.
        if (address(sessionRegistry) != address(0)) {
            sessionRegistry.recordProposal(agent, msg.sender);
        }

        verdict = _policyFor(agent).check(agent, target, value, data);

        if (verdict == Verdict.DENY) {
            revert UnexpectedVerdict(verdict);
        }

        if (verdict == Verdict.ALLOW) {
            // Settlement is a second grant. A policy ALLOW says the action is
            // within the org's rules; the spend scope says this particular key
            // is allowed to act on that without a human in the loop.
            _requireSpendScope(agent, scopeMask);
            _finalizeAction(agent, target, value, data);
            return (0, verdict);
        }

        if (agentNode.parent == address(0)) revert NoApprover(agent);

        intentId = nextIntentId++;
        intents[intentId] = Intent({
            agent: agent,
            target: target,
            value: value,
            data: data,
            awaitingApprover: agentNode.parent,
            resolved: false,
            approved: false
        });

        intentLife[intentId] = IntentLife({
            expiresAt: uint64(block.timestamp) + intentTtl,
            agentGeneration: orgRegistry.generationOf(agent),
            approverGeneration: orgRegistry.generationOf(agentNode.parent)
        });

        _recordRate(agent);
        emit IntentCreated(intentId, agent, agentNode.parent);
    }

    /// @notice Approve or reject a pending intent.
    /// @dev Authority to resolve belongs to nodes that are in the tree and active now,
    ///      not to whoever held the seat when the intent was created:
    ///
    ///      - The awaiting approver resolves, and only while it is an active node.
    ///        Deactivated or removed, it can neither approve nor reject
    ///        (`InactiveApprover`).
    ///      - An intent awaiting an inactive or removed approver is not stranded: the
    ///        org root (`orgRegistry.root()`, which can be neither deactivated nor
    ///        removed) resolves in its place, under the root's own policy and reserved
    ///        authority. The root is the one stand-in because a removed approver has no
    ///        parent left to fall back on, and one rule for both cases keeps the path
    ///        predictable. While the approver is active the root has no shortcut: it
    ///        waits for the intent to climb like any other ancestor.
    ///      - Approval requires the proposing agent to still be an active node
    ///        (`InactiveAgent`), at every step of the climb, so a deactivated or fired
    ///        agent's pending spend can never execute. Rejection stays open, which is
    ///        how such an intent is closed.
    function resolve(uint256 intentId, bool approved) external nonReentrant {
        Intent storage intent = intents[intentId];
        if (intent.agent == address(0)) revert IntentNotFound(intentId);
        if (intent.resolved) revert IntentAlreadyResolved(intentId);
        IntentLife storage life = intentLife[intentId];
        if (block.timestamp >= life.expiresAt) revert IntentHasExpired(intentId, life.expiresAt);
        address awaiting = intent.awaitingApprover;
        bool awaitingLive = _isCurrentNode(awaiting, life.approverGeneration);
        if (msg.sender == awaiting) {
            if (!awaitingLive) revert InactiveApprover(awaiting);
        } else if (msg.sender != orgRegistry.root() || awaitingLive) {
            revert NotAwaitingApprover(msg.sender);
        }

        if (!approved) {
            intent.resolved = true;
            intent.approved = false;
            emit IntentResolved(intentId, false);
            return;
        }

        if (!_isCurrentNode(intent.agent, life.agentGeneration)) revert InactiveAgent(intent.agent);

        Verdict verdict = _policyFor(msg.sender).check(msg.sender, intent.target, intent.value, intent.data);

        if (verdict == Verdict.DENY) {
            intent.resolved = true;
            intent.approved = false;
            emit IntentResolved(intentId, false);
            return;
        }

        if (verdict == Verdict.ALLOW) {
            intent.resolved = true;
            intent.approved = true;
            _finalizeAction(intent.agent, intent.target, intent.value, intent.data);
            emit IntentResolved(intentId, true);
            return;
        }

        IOrgRegistry.Node memory approver = orgRegistry.getNode(msg.sender);
        if (approver.parent == address(0) || approver.kind == IOrgRegistry.NodeKind.HumanRoot) {
            // Root reserved authority finalizes. A passkey root arrives here as
            // its own Safe: msg.sender is the Safe, and the credential authorized
            // this call through Safe.execTransaction, so the binding is the sender
            // check at the top of this function (F2.6 / F1.3).
            intent.resolved = true;
            intent.approved = true;
            _finalizeAction(intent.agent, intent.target, intent.value, intent.data);
            emit IntentResolved(intentId, true);
            return;
        }

        address nextApprover = approver.parent;
        address previous = intent.awaitingApprover;
        intent.awaitingApprover = nextApprover;
        life.approverGeneration = orgRegistry.generationOf(nextApprover);
        emit IntentEscalated(intentId, previous, nextApprover);
    }

    /// @notice Close an intent that passed its expiry. Anyone may call; it only ever
    ///         rejects, so it needs no authority and frees nobody's funds.
    function closeExpired(uint256 intentId) external {
        Intent storage intent = intents[intentId];
        if (intent.agent == address(0)) revert IntentNotFound(intentId);
        if (intent.resolved) revert IntentAlreadyResolved(intentId);
        uint64 expiresAt = intentLife[intentId].expiresAt;
        if (block.timestamp < expiresAt) revert IntentNotExpired(intentId, expiresAt);
        intent.resolved = true;
        intent.approved = false;
        emit IntentExpired(intentId, msg.sender);
        emit IntentResolved(intentId, false);
    }

    function _finalizeAction(address agent, address target, uint256 value, bytes memory data) private {
        if (paused) revert EnforcedPause();
        uint256 settled = value;
        // A pull settlement records its value after the call, once it knows what the
        // target kept. Every other path charges the value before the call, as before.
        bool pull = value > 0 && data.length > 0 && address(treasury) != address(0);
        if (value > 0 && !pull) {
            if (address(treasury) != address(0)) treasury.spendAllowance(agent, value, target);
            _recordValue(agent, target, value);
        }

        // Count the action before any external call to the target (checks-effects-interactions):
        // a target that calls back into the router must see this action already
        // inside the RateLimitPolicy window.
        _recordRate(agent);

        // Payment and action are atomic: if the target call fails, the whole
        // propose/resolve reverts, so the spend and the counts above are undone, the
        // intent stays unresolved, and no funds are left stranded at a target that never acted.
        if (pull) {
            settled = _settlePull(agent, target, value, data);
            if (settled > 0) _recordValue(agent, target, settled);
        } else if (data.length > 0) {
            _callTarget(target, data, 0);
        }
        emit ActionExecuted(agent, target, settled, true);
    }

    /// @dev Call `target`, bubbling its revert data (`ActionCallFailed` when it has none).
    ///      `paid` is what treasury paid for this action, readable by `target` through
    ///      `currentSettlement` for the length of the call. It is restored afterwards rather
    ///      than cleared, so a nested action cannot erase the context of the one that
    ///      contains it.
    function _callTarget(address target, bytes memory data, uint256 paid) private {
        address outerTarget = _settlingTarget;
        uint256 outerPaid = _settlingPaid;
        _settlingTarget = target;
        _settlingPaid = paid;
        (bool ok, bytes memory ret) = target.call(data);
        _settlingTarget = outerTarget;
        _settlingPaid = outerPaid;
        if (!ok) {
            if (ret.length == 0) revert ActionCallFailed(target);
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @dev Pull settlement. The router holds `value` only for the length of the call, and
    ///      `target`'s approval never outlives it. A failed call reverts the whole action
    ///      (`_callTarget`). Balance is measured against what the router held before, so
    ///      stray tokens sent to the router are never spent or refunded. Tokens a successful
    ///      `target` left unpulled or sent back go back to the agent's allowance. Anything
    ///      above `value` (a target paying the router more than it took) goes to the treasury
    ///      as unreserved funds rather than inflating the agent's allowance.
    function _settlePull(address agent, address target, uint256 value, bytes memory data)
        private
        returns (uint256 settled)
    {
        IERC20 token = treasury.token();
        uint256 before = token.balanceOf(address(this));
        treasury.spendAllowance(agent, value);
        token.forceApprove(target, value);
        _callTarget(target, data, value);
        token.forceApprove(target, 0);

        uint256 held = token.balanceOf(address(this));
        uint256 left = held > before ? held - before : 0;
        uint256 refund = left > value ? value : left;
        if (refund > 0) {
            token.forceApprove(address(treasury), refund);
            treasury.refundAllowance(agent, refund);
            emit SettlementReturned(agent, target, refund);
        }
        if (left > refund) token.safeTransfer(address(treasury), left - refund);
        settled = value - refund;
    }

    /// @inheritdoc ISettlementContext
    function currentSettlement() external view returns (address target, uint256 paid) {
        return (_settlingTarget, _settlingPaid);
    }

    function _recordRate(address agent) private {
        IRateRecorder recorder = rateRecorderOf[agent];
        if (address(recorder) == address(0)) recorder = rateRecorder;
        if (address(recorder) != address(0)) {
            recorder.record(agent);
        }
    }

    function _recordValue(address agent, address target, uint256 value) private {
        IValueRecorder recorder = valueRecorderOf[agent];
        if (address(recorder) == address(0)) recorder = valueRecorder;
        if (address(recorder) != address(0)) {
            recorder.recordValue(agent, target, value);
        }
    }

    /// @dev Unset registry = unit-test bootstrap. Otherwise: valid session + scope
    ///      + maxValue + target. Returns the granted scope mask so the caller can
    ///      gate settlement separately; `type(uint256).max` when the registry is
    ///      unset or the agent is acting for itself (no session to narrow it).
    function _requireValidSession(address agent, address target, uint256 value)
        private
        view
        returns (uint256 scopeMask)
    {
        if (address(sessionRegistry) == address(0)) return type(uint256).max;
        if (msg.sender == agent) return type(uint256).max;
        bool valid;
        uint256 maxValue;
        address allowedTarget;
        (valid, maxValue, allowedTarget, scopeMask) = sessionRegistry.keyLimits(agent, msg.sender);
        if (!valid) revert InvalidSession(agent, msg.sender);
        if (scopeMask & SessionScopes.PROPOSE_INTENT == 0) {
            revert SessionScopeDenied(agent, SessionScopes.PROPOSE_INTENT, scopeMask);
        }
        if (value > maxValue) revert SessionValueExceeded(agent, value, maxValue);
        // Handles both single- and multi-target pins (unpinned = any policy-allowed
        // target); `allowedTarget` is reported only for the revert reason.
        if (!sessionRegistry.isTargetAllowed(agent, msg.sender, target)) {
            revert SessionTargetDenied(agent, target, allowedTarget);
        }
        // A key issued with a daily window can only propose inside it — the flow's
        // time-window scope enforced by the chain, not just the orchestrator.
        if (!sessionRegistry.withinTimeWindow(agent, msg.sender)) {
            revert SessionTimeWindowDenied(agent);
        }
    }

    /// @dev `type(uint256).max` from `_requireValidSession` means no session is
    ///      narrowing this call, so every bit is granted and this passes.
    function _requireSpendScope(address agent, uint256 scopeMask) private view {
        if (address(sessionRegistry) == address(0)) return;
        if (scopeMask & SessionScopes.SPEND_WHITELIST == 0) {
            revert SessionScopeDenied(agent, SessionScopes.SPEND_WHITELIST, scopeMask);
        }
    }

    /// @dev Policy decides what an agent may call; this only refuses the contracts
    ///      that trust the router as `msg.sender`, whatever the policy says. Checked
    ///      at propose so no such intent can even be created for a parent to approve.
    function _requireUnprotectedTarget(
        address target,
        uint256 value,
        uint256 dataLength
    ) private view {
        // Unwired slots are zero; a zero target must not match them.
        if (target == address(0)) return;
        if (
            target == address(this) || target == address(treasury) || target == address(sessionRegistry)
                || isBoundRecorder(target)
        ) {
            revert ProtectedTarget(target);
        }
        // An action with neither value nor calldata touches nothing, so it needs no token
        // lookup; that also keeps a no-op working while the treasury slot is miswired.
        if (value == 0 && dataLength == 0) return;
        if (address(treasury) != address(0) && target == address(treasury.token())) {
            revert ProtectedTarget(target);
        }
    }

    /// @dev In the tree and active. `getNode` reverts for an account with no node,
    ///      which is how a removed node reads; that is an answer here, not a failure.
    function _isActiveNode(address account) private view returns (bool) {
        try orgRegistry.getNode(account) returns (IOrgRegistry.Node memory node) {
            return node.active;
        } catch {
            return false;
        }
    }

    /// @dev Active now and still the incarnation the intent was recorded under.
    function _isCurrentNode(address account, uint64 generation) private view returns (bool) {
        return _isActiveNode(account) && orgRegistry.generationOf(account) == generation;
    }

    function _policyFor(address node) private view returns (IPolicyModule) {
        IPolicyModule nodePolicy = policyOf[node];
        if (address(nodePolicy) != address(0)) return nodePolicy;
        return policy;
    }

    /// @dev Governor once bound; the deployer until then.
    function _authority() private view returns (address) {
        return governor == address(0) ? deployer : governor;
    }

    function _isHumanSeat(address account) private view returns (bool) {
        try orgRegistry.getNode(account) returns (IOrgRegistry.Node memory node) {
            return node.active && node.kind == IOrgRegistry.NodeKind.HumanRoot;
        } catch {
            return false;
        }
    }

    function _onlyGovernorOrBootstrap() private view {
        if (msg.sender != _authority()) revert NotAuthorized(msg.sender);
    }
}
