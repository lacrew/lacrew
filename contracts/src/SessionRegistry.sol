// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {SessionScopes} from "./SessionScopes.sol";
import {IOrgRegistry} from "./interfaces/IOrgRegistry.sol";

/// @title SessionRegistry
/// @notice Onchain registry of scoped, expiring agent session keys.
/// @dev Phase 0 bridge before ERC-4337 session modules (F1.3). Root issues and revokes;
///      orchestrator holds only the ephemeral private key off-chain.
///
///      A bound `governor` (GovernanceModule) is the authority above the root: it can
///      replace or revoke a compromised issuer, revoke any session, and rotate the root
///      key itself. Everything else stays the root's, so day-to-day issuance never
///      waits on a vote.
///      EscalationRouter enforces `scopeMask`, `maxValue`, and optional
///      `allowedTarget` (`address(0)` = any target that still passes policy).
///
///      Scopes are a bitmask so the chain can test membership on its own. A
///      digest of the scope list could not be gated on without the caller also
///      supplying the preimage, which would let the caller pick the answer.
contract SessionRegistry {
    /// @notice Mirrors of `SessionScopes`, exposed so off-chain callers can read
    ///         the vocabulary from the deployment they are actually talking to.
    uint256 public constant SCOPE_PROPOSE_INTENT = SessionScopes.PROPOSE_INTENT;
    uint256 public constant SCOPE_SPEND_WHITELIST = SessionScopes.SPEND_WHITELIST;
    /// @dev Anything outside this is rejected at issue time, so a typo'd scope
    ///      cannot be mistaken for a granted one.
    uint256 public constant SCOPE_ALL = SessionScopes.ALL;

    struct Session {
        address agent;
        address key;
        uint64 expiresAt;
        uint256 scopeMask;
        uint256 maxValue;
        address allowedTarget;
        bool revoked;
        bool exists;
        // Daily allowed window in seconds since midnight UTC, `[windowStart,
        // windowEnd)`. Both zero = no window (any time). Enforced by
        // EscalationRouter on propose, the same shape as TimeWindowPolicy.
        uint32 windowStart;
        uint32 windowEnd;
    }

    /// @notice The org's root key. Rotated only by the governor (or by itself before
    ///         one is bound), so a lost or compromised key is recoverable.
    address public humanRoot;
    /// @notice When non-zero, may set the issuer, revoke sessions and rotate the root.
    address public governor;
    /// @notice Address named by the governor to take over; it has no power until it accepts.
    address public pendingGovernor;
    /// @notice Org tree consulted so a delegated issuer can only mint keys for agent nodes.
    IOrgRegistry public immutable orgRegistry;
    /// @notice Optional issuer (orchestrator EOA). Defaults to humanRoot.
    address public issuer;
    /// @notice Longest lifetime the issuer may give a session, in seconds. Root-set;
    ///         the root itself is not bound by it.
    /// @dev The threat model says a compromised orchestrator leaks only short-lived
    ///      keys. That is only true if the chain refuses to mint it a long-lived one:
    ///      without this ceiling the issuer could hand itself a key that outlives any
    ///      rotation, and "short-lived" would rest on the compromised party's goodwill.
    uint64 public maxIssuerTtl = 30 days;

    uint256 public nextSessionId = 1;
    mapping(uint256 => Session) public sessions;
    /// @notice Who issued each session. A delegated issuer may only revoke its own.
    /// @dev Kept beside `Session` rather than in it so the public `sessions` getter keeps its shape.
    mapping(uint256 => address) public issuedBy;
    /// @notice The agent's `OrgRegistry` incarnation when the session was issued. A key
    ///         from before the agent was removed and re-added no longer validates.
    mapping(uint256 => uint64) public agentGenerationOf;
    mapping(address => uint256[]) private _byAgent;
    /// @dev agent => key => sessionId (0 = none / cleared)
    mapping(address => mapping(address => uint256)) public activeKeySession;
    /// @dev sessionId => pinned targets (empty = any policy-allowed target)
    mapping(uint256 => address[]) private _sessionTargets;
    mapping(uint256 => mapping(address => bool)) private _targetAllowed;

    /// @notice Per-session propose rate limit and its running window counter.
    /// @dev `maxProposals == 0` disables it. The counter resets when the current
    ///      window (`ratePeriod` seconds from `windowStart`) has elapsed.
    struct RateLimit {
        uint32 maxProposals;
        uint32 ratePeriod;
        uint64 windowStart;
        uint32 count;
    }

    /// @dev sessionId => rate limit config + counter.
    mapping(uint256 => RateLimit) public rateLimits;

    /// @notice The only contract allowed to record proposals (the EscalationRouter).
    /// @dev Zero = rate-limiting not wired; recordProposal is then a no-op, the
    ///      same opt-in shape as the router's `setSessionRegistry`.
    address public escalationRouter;

    event IssuerUpdated(address indexed issuer);
    event GovernorUpdated(address indexed governor);
    event PendingGovernorUpdated(address indexed pendingGovernor);
    event RootRotated(address indexed oldRoot, address indexed newRoot);
    event MaxIssuerTtlUpdated(uint64 maxIssuerTtl);
    event EscalationRouterUpdated(address indexed escalationRouter);
    event SessionIssued(
        uint256 indexed sessionId,
        address indexed agent,
        address indexed key,
        uint64 expiresAt,
        uint256 scopeMask,
        uint256 maxValue,
        address allowedTarget
    );
    event SessionRevoked(uint256 indexed sessionId, address indexed by);
    /// @notice Emitted alongside SessionIssued when more than one target is pinned.
    event SessionTargetsPinned(uint256 indexed sessionId, address[] targets);

    error NotAuthorized(address caller);
    /// @dev The delegated issuer tried to mint a key for something other than an
    ///      active manager/worker agent node (the root, a peer human, or an unknown account).
    error IssuerAgentNotEligible(address agent);
    error ZeroAddress();
    /// @dev `acceptGovernor` was called by an address that is not the pending governor.
    error NotPendingGovernor(address caller);
    error GovernorAlreadySet();
    error InvalidExpiry(uint64 expiresAt);
    error ExpiryExceedsIssuerTtl(uint64 expiresAt, uint64 maxExpiresAt);
    error ZeroTtl();
    error SessionNotFound(uint256 sessionId);
    error AlreadyRevoked(uint256 sessionId);
    /// @dev An empty mask would be a session that can do nothing; an unknown bit
    ///      is almost always a caller encoding scopes against a newer vocabulary.
    error InvalidScopeMask(uint256 scopeMask);
    error InvalidWindow(uint32 windowStart, uint32 windowEnd);
    error InvalidRateLimit(uint32 maxProposals, uint32 ratePeriod);
    error RateLimitExceeded(address agent, address key, uint32 maxProposals);

    modifier onlyRootOrIssuer() {
        if (msg.sender != humanRoot && msg.sender != issuer) revert NotAuthorized(msg.sender);
        _;
    }

    /// @dev The root, or the governor once bound.
    modifier onlyRootOrGovernor() {
        if (msg.sender != humanRoot && (governor == address(0) || msg.sender != governor)) {
            revert NotAuthorized(msg.sender);
        }
        _;
    }

    constructor(address humanRoot_, address orgRegistry_) {
        if (humanRoot_ == address(0) || orgRegistry_ == address(0)) revert ZeroAddress();
        humanRoot = humanRoot_;
        orgRegistry = IOrgRegistry(orgRegistry_);
        issuer = humanRoot_;
    }

    /// @notice Bind governance, once, by the root. Handing it on afterwards is two
    ///         steps: `setPendingGovernor`, then `acceptGovernor`.
    function setGovernor(address governor_) external {
        if (governor_ == address(0)) revert ZeroAddress();
        if (governor != address(0)) revert GovernorAlreadySet();
        if (msg.sender != humanRoot) revert NotAuthorized(msg.sender);
        governor = governor_;
        emit GovernorUpdated(governor_);
    }

    /// @notice Name the address that may take over governance. Current governor only;
    ///         naming another address replaces the pending one, and the zero address
    ///         cancels it. The governor keeps every power until the pending address calls
    ///         `acceptGovernor`, so a wrong address is corrected by naming the right one.
    function setPendingGovernor(address pending) external {
        if (governor == address(0) || msg.sender != governor) revert NotAuthorized(msg.sender);
        pendingGovernor = pending;
        emit PendingGovernorUpdated(pending);
    }

    /// @notice Complete the hand-over: only the pending governor may call it.
    function acceptGovernor() external {
        if (pendingGovernor == address(0) || msg.sender != pendingGovernor) {
            revert NotPendingGovernor(msg.sender);
        }
        governor = msg.sender;
        pendingGovernor = address(0);
        emit GovernorUpdated(msg.sender);
    }

    /// @notice Hand the root key to `newRoot`. Governor-only once one is bound (the
    ///         recovery path for a lost or compromised key); the root itself before.
    /// @dev An issuer still set to the old root follows it to `newRoot`: the old key is
    ///      retired because it may be compromised, so it keeps no issuing authority. A
    ///      separate issuer (the orchestrator) is left as it is.
    function rotateRoot(address newRoot) external {
        if (governor != address(0)) {
            if (msg.sender != governor) revert NotAuthorized(msg.sender);
        } else if (msg.sender != humanRoot) {
            revert NotAuthorized(msg.sender);
        }
        if (newRoot == address(0)) revert ZeroAddress();
        address oldRoot = humanRoot;
        humanRoot = newRoot;
        emit RootRotated(oldRoot, newRoot);
        if (issuer == oldRoot) {
            issuer = newRoot;
            emit IssuerUpdated(newRoot);
        }
    }

    /// @notice Replace the issuer. Root or governor: governance can swap out a
    ///         compromised orchestrator key without the root's signature.
    function setIssuer(address issuer_) external onlyRootOrGovernor {
        if (issuer_ == address(0)) revert ZeroAddress();
        issuer = issuer_;
        emit IssuerUpdated(issuer_);
    }

    /// @notice Cap how far ahead the issuer may set a session's expiry. Root-only.
    function setMaxIssuerTtl(uint64 maxIssuerTtl_) external {
        if (msg.sender != humanRoot) revert NotAuthorized(msg.sender);
        if (maxIssuerTtl_ == 0) revert ZeroTtl();
        maxIssuerTtl = maxIssuerTtl_;
        emit MaxIssuerTtlUpdated(maxIssuerTtl_);
    }

    /// @notice Wire the EscalationRouter so it (and only it) can record proposals
    ///         against a session's rate limit. Root-only; unset = no rate-limiting.
    function setEscalationRouter(address escalationRouter_) external {
        if (msg.sender != humanRoot) revert NotAuthorized(msg.sender);
        if (escalationRouter_ == address(0)) revert ZeroAddress();
        escalationRouter = escalationRouter_;
        emit EscalationRouterUpdated(escalationRouter_);
    }

    /// @notice Register an ephemeral key for `agent` until `expiresAt` (unix seconds).
    /// @param maxValue Max propose value (`type(uint256).max` = unlimited).
    /// @param allowedTarget Sole allowed target (`address(0)` = any policy-allowed target).
    function issue(
        address agent,
        address key,
        uint64 expiresAt,
        uint256 scopeMask,
        uint256 maxValue,
        address allowedTarget
    ) external onlyRootOrIssuer returns (uint256 sessionId) {
        address[] memory targets;
        if (allowedTarget != address(0)) {
            targets = new address[](1);
            targets[0] = allowedTarget;
        }
        return _issue(agent, key, expiresAt, scopeMask, maxValue, targets, 0, 0, 0, 0);
    }

    /// @notice Issue a session pinned to several targets (empty = any policy-allowed target).
    /// @dev Multi-target sessions are checked with `isTargetAllowed`; `keyLimits`
    ///      reports only the first target so naive consumers fail closed.
    function issueScoped(
        address agent,
        address key,
        uint64 expiresAt,
        uint256 scopeMask,
        uint256 maxValue,
        address[] calldata allowedTargets
    ) external onlyRootOrIssuer returns (uint256 sessionId) {
        return _issue(agent, key, expiresAt, scopeMask, maxValue, allowedTargets, 0, 0, 0, 0);
    }

    /// @notice Issue a session with the full onchain scope ceiling: an optional
    ///         daily UTC window and an optional propose rate limit.
    /// @param windowStart Inclusive start, seconds since midnight UTC.
    /// @param windowEnd Exclusive end (`> windowStart`, `<= 86400`). Both zero = any time.
    /// @param maxProposals Max proposals per `ratePeriod` (`0` = unlimited).
    /// @param ratePeriod Rate window in seconds (required when maxProposals > 0).
    /// @dev Carries a flow's time-window and rate scopes onto the key, so the
    ///      chain — not just the orchestrator — enforces them on propose.
    function issueScopedTimed(
        address agent,
        address key,
        uint64 expiresAt,
        uint256 scopeMask,
        uint256 maxValue,
        address[] calldata allowedTargets,
        uint32 windowStart,
        uint32 windowEnd,
        uint32 maxProposals,
        uint32 ratePeriod
    ) external onlyRootOrIssuer returns (uint256 sessionId) {
        return _issue(
            agent, key, expiresAt, scopeMask, maxValue, allowedTargets, windowStart, windowEnd, maxProposals, ratePeriod
        );
    }

    function _issue(
        address agent,
        address key,
        uint64 expiresAt,
        uint256 scopeMask,
        uint256 maxValue,
        address[] memory allowedTargets,
        uint32 windowStart,
        uint32 windowEnd,
        uint32 maxProposals,
        uint32 ratePeriod
    ) private returns (uint256 sessionId) {
        if (agent == address(0) || key == address(0)) revert ZeroAddress();
        if (expiresAt <= block.timestamp) revert InvalidExpiry(expiresAt);
        if (msg.sender != humanRoot) {
            uint64 maxExpiresAt = uint64(block.timestamp) + maxIssuerTtl;
            if (expiresAt > maxExpiresAt) revert ExpiryExceedsIssuerTtl(expiresAt, maxExpiresAt);
            // The orchestrator-held issuer may only act for agents. A key minted for the
            // root or a peer human would let it propose as that human, with no approver above.
            _requireAgentNode(agent);
        }
        if (scopeMask == 0 || scopeMask & ~SessionScopes.ALL != 0) revert InvalidScopeMask(scopeMask);
        // A window is optional (both zero disables it); when set it must be a
        // real slice of a day, matching TimeWindowPolicy's `[start, end)` rule.
        if (windowStart != 0 || windowEnd != 0) {
            if (windowEnd <= windowStart || windowEnd > 1 days) revert InvalidWindow(windowStart, windowEnd);
        }
        // A rate limit is optional; a cap with no period (or a period with no cap)
        // is a caller error, not a disabled limit.
        if (maxProposals != 0 || ratePeriod != 0) {
            if (maxProposals == 0 || ratePeriod == 0) revert InvalidRateLimit(maxProposals, ratePeriod);
        }

        // Revoke any prior active session for this key binding.
        uint256 prior = activeKeySession[agent][key];
        if (prior != 0 && !sessions[prior].revoked) {
            // A delegated issuer must not be able to displace a session the root issued.
            if (msg.sender != humanRoot && issuedBy[prior] != msg.sender) revert NotAuthorized(msg.sender);
            sessions[prior].revoked = true;
            emit SessionRevoked(prior, msg.sender);
        }

        sessionId = nextSessionId++;
        address first;
        for (uint256 i = 0; i < allowedTargets.length; i++) {
            address t = allowedTargets[i];
            if (t == address(0)) revert ZeroAddress();
            if (_targetAllowed[sessionId][t]) continue;
            _targetAllowed[sessionId][t] = true;
            _sessionTargets[sessionId].push(t);
            if (first == address(0)) first = t;
        }

        sessions[sessionId] = Session({
            agent: agent,
            key: key,
            expiresAt: expiresAt,
            scopeMask: scopeMask,
            maxValue: maxValue,
            allowedTarget: first,
            revoked: false,
            exists: true,
            windowStart: windowStart,
            windowEnd: windowEnd
        });
        issuedBy[sessionId] = msg.sender;
        agentGenerationOf[sessionId] = orgRegistry.generationOf(agent);
        _byAgent[agent].push(sessionId);
        activeKeySession[agent][key] = sessionId;

        if (maxProposals != 0) {
            // windowStart 0 / count 0: the first recorded proposal opens the window.
            rateLimits[sessionId] = RateLimit(maxProposals, ratePeriod, 0, 0);
        }

        emit SessionIssued(sessionId, agent, key, expiresAt, scopeMask, maxValue, first);
        if (_sessionTargets[sessionId].length > 1) {
            emit SessionTargetsPinned(sessionId, _sessionTargets[sessionId]);
        }
    }

    /// @dev Reverts unless `agent` is an existing, active ManagerAgent/WorkerAgent node.
    function _requireAgentNode(address agent) private view {
        // getNode reverts with NodeNotFound for an unknown account; make that our own error.
        try orgRegistry.getNode(agent) returns (IOrgRegistry.Node memory node) {
            if (!node.active || node.kind == IOrgRegistry.NodeKind.HumanRoot) {
                revert IssuerAgentNotEligible(agent);
            }
        } catch {
            revert IssuerAgentNotEligible(agent);
        }
    }

    /// @notice Root or governor revokes any session. The delegated issuer may revoke only
    ///         sessions it issued. Product rule: prefer root-driven revoke; the governor
    ///         path covers a root that cannot act.
    function revoke(uint256 sessionId) external {
        bool rootOrGovernor = msg.sender == humanRoot
            || (governor != address(0) && msg.sender == governor);
        if (!rootOrGovernor && msg.sender != issuer) revert NotAuthorized(msg.sender);
        Session storage s = sessions[sessionId];
        if (!s.exists) revert SessionNotFound(sessionId);
        if (!rootOrGovernor && issuedBy[sessionId] != msg.sender) revert NotAuthorized(msg.sender);
        if (s.revoked) revert AlreadyRevoked(sessionId);
        s.revoked = true;
        if (activeKeySession[s.agent][s.key] == sessionId) {
            activeKeySession[s.agent][s.key] = 0;
        }
        emit SessionRevoked(sessionId, msg.sender);
    }

    function isValid(uint256 sessionId) public view returns (bool) {
        Session storage s = sessions[sessionId];
        if (!s.exists || s.revoked) return false;
        if (agentGenerationOf[sessionId] != orgRegistry.generationOf(s.agent)) return false;
        return block.timestamp < s.expiresAt;
    }

    function isKeyValid(address agent, address key) external view returns (bool) {
        uint256 id = activeKeySession[agent][key];
        if (id == 0) return false;
        return isValid(id);
    }

    /// @notice Limits for an active key. `valid` is false when missing/expired/revoked.
    /// @dev `allowedTarget` is the FIRST pinned target; multi-target sessions must be
    ///      checked with `isTargetAllowed` (naive consumers therefore fail closed).
    function keyLimits(address agent, address key)
        external
        view
        returns (bool valid, uint256 maxValue, address allowedTarget, uint256 scopeMask)
    {
        uint256 id = activeKeySession[agent][key];
        if (id == 0) return (false, 0, address(0), 0);
        Session storage s = sessions[id];
        if (!isValid(id)) {
            return (false, 0, address(0), 0);
        }
        return (true, s.maxValue, s.allowedTarget, s.scopeMask);
    }

    /// @notice Whether an active key may propose at the current time.
    /// @dev True when the key has no window, or `block.timestamp`'s time of day is
    ///      in `[windowStart, windowEnd)`. A missing/invalid session is left to
    ///      `keyLimits` to reject, so this returns true rather than double-judging.
    function withinTimeWindow(address agent, address key) external view returns (bool) {
        uint256 id = activeKeySession[agent][key];
        if (id == 0) return true;
        Session storage s = sessions[id];
        if (s.windowEnd == 0) return true;
        // Time-of-day check, not randomness — same suppression as TimeWindowPolicy.
        // slither-disable-next-line weak-prng
        uint256 tod = block.timestamp % 1 days;
        return tod >= s.windowStart && tod < s.windowEnd;
    }

    /// @notice Count a proposal against an active key's rate limit, reverting when
    ///         the limit is exceeded. Called by the EscalationRouter on `propose`.
    /// @dev No-op when rate-limiting is unwired, the key has no session, or the
    ///      session has no rate limit. The counter increments before the check,
    ///      so a reverting propose rolls the increment back and does not count.
    function recordProposal(address agent, address key) external {
        if (escalationRouter == address(0)) return;
        if (msg.sender != escalationRouter) revert NotAuthorized(msg.sender);
        uint256 id = activeKeySession[agent][key];
        if (id == 0) return;
        RateLimit storage r = rateLimits[id];
        if (r.maxProposals == 0) return;
        if (r.windowStart == 0 || block.timestamp >= r.windowStart + r.ratePeriod) {
            // First proposal, or the prior window has elapsed: start a new one.
            r.windowStart = uint64(block.timestamp);
            r.count = 1;
        } else {
            r.count += 1;
            if (r.count > r.maxProposals) revert RateLimitExceeded(agent, key, r.maxProposals);
        }
    }

    /// @notice Targets pinned to a session (empty = any policy-allowed target).
    function allowedTargetsOf(uint256 sessionId) external view returns (address[] memory) {
        return _sessionTargets[sessionId];
    }

    /// @notice Whether an active key may call `target`. Unpinned sessions allow any.
    function isTargetAllowed(address agent, address key, address target)
        external
        view
        returns (bool)
    {
        uint256 id = activeKeySession[agent][key];
        if (id == 0 || !isValid(id)) return false;
        if (_sessionTargets[id].length == 0) return true;
        return _targetAllowed[id][target];
    }

    function sessionsOf(address agent) external view returns (uint256[] memory) {
        return _byAgent[agent];
    }
}
