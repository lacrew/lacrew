// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @notice A contract whose root key GovernanceModule can rotate.
interface IRootRotatable {
    function rotateRoot(address newRoot) external;
}

/// @title GovernanceModule
/// @notice Quorum voting for constitutional actions (hire/fire, budgets, policy upgrades).
/// @dev Low tier: all-seat quorum, more yes-weight than no-weight, and a short delay
///      (`lowTierDelay`) that gives every human seat a window to vote it down or veto
///      it. Only allow-listed actions may ride the low tier (`lowTierSelector`, seeded
///      with an agent hire); every other call — firing, reparenting, treasury spenders,
///      router policies, grants, governor transfers, this module — is High tier.
///      High tier: human-seat quorum + timelock; agent seats may vote as review
///      authority but do not satisfy high-tier final say. On both tiers a proposal
///      executes only while its own electorate's yes-weight exceeds its no-weight.
///      Any funded Human seat (root included) may veto before execution — the human
///      safety valve is shared, never delegated to agents. Power is role-weighted per seat.
///
///      Bootstrap-safe by construction: the effective quorum never exceeds the weight the
///      seated electorate can actually deliver, so a solo human root is never deadlocked
///      behind a quorum sized for seats that do not exist yet. And when every human seat
///      has voted yes, the high-tier timelock is skippable (`unanimityFastPath`) — the
///      delay protects humans who have not weighed in, and there are none left.
///
///      **Multi-human orgs.** An org may seat any number of Human seats, and the seat
///      roster itself is constitutional property: `admitHuman` / `removeHuman` (and any
///      `setVotingPower` that creates, re-weights, or revokes a Human seat) execute only
///      as governance, which `propose` forces to High tier when the target is this module.
///      A partner therefore cannot be added or fired from a private key — every change to
///      who holds final say passes the humans already seated, any one of whom can veto it.
///      The last Human seat can never be revoked: an org whose humans have all been
///      removed would leave agent seats as the only electorate, which is the one outcome
///      the tier split exists to prevent.
///
///      The root address keeps its direct admin over the non-seat parameters (quorums,
///      timing, agent seats) only while it holds a funded Human seat — or while nobody
///      does, the bootstrap of an org deployed with `rootPower_ = 0`. Governance that
///      revokes the root's seat revokes its veto and its parameter admin with it, so
///      "root" is a seat that can change hands, not a permanent key.
///
///      **Root rotation.** The root key itself is replaceable: `rotateRoot` moves it, its
///      seat, and — in the same transaction — the root of every contract that names one
///      (OrgRegistry, SessionRegistry), so a lost or compromised key is a High-tier
///      proposal away from recovery rather than a redeploy. Any proposal that reaches a
///      root rotation or a session issuer change on another contract is forced High tier
///      too, alongside governor transfers.
contract GovernanceModule {
    enum Tier {
        Low,
        High
    }

    enum ProposalState {
        Active,
        Executed,
        Vetoed,
        Defeated
    }

    /// @notice Seat classification. Agents review; humans decide high-tier final say.
    enum SeatRole {
        None,
        Human,
        Agent
    }

    struct Proposal {
        address proposer;
        Tier tier;
        address target;
        bytes32 actionHash;
        bytes data;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 yesHumanVotes;
        uint256 deadline;
        uint256 eta;
        ProposalState state;
    }

    /// @notice The org's root key. Changed only by `rotateRoot`.
    address public humanRoot;

    uint256 public nextProposalId = 1;
    mapping(uint256 => Proposal) public proposals;
    /// @notice Human-seat no-weight per proposal: the only weight that counts against
    ///         a high-tier proposal, as `yesHumanVotes` is the only weight that counts
    ///         for one. Kept beside the struct so the `proposals` getter keeps its shape.
    mapping(uint256 => uint256) public noHumanVotes;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @notice Role-weighted seat power. Zero means the address cannot vote.
    mapping(address => uint256) public votingPower;
    /// @notice Human vs agent seat. Agent yes-weight counts for low tier only.
    mapping(address => SeatRole) public seatRole;
    /// @notice Sum of all seat weight. Caps the effective low-tier quorum.
    uint256 public totalVotingPower;
    /// @notice Sum of human-seat weight. Caps the effective high-tier quorum and
    ///         defines unanimity for the timelock fast path.
    uint256 public totalHumanVotingPower;
    /// @notice How many funded Human seats exist. Weight answers "how much say";
    ///         this answers "how many humans" — the number the last-human guard
    ///         and every multi-human UI are actually about.
    uint256 public humanSeatCount;
    /// @notice Yes-weight required to execute low-tier proposals (all seats).
    uint256 public quorumYes = 2;
    /// @notice Human yes-weight required to execute high-tier proposals.
    uint256 public quorumHumanYes = 1;

    /// @notice Voting window applied to proposals at creation time.
    uint256 public votingPeriod = 3 days;
    /// @notice Delay after the voting deadline before high-tier execution. May be zero.
    uint256 public highTierTimelock = 1 days;
    /// @notice When true, a proposal backed by ALL human voting weight executes without
    ///         waiting for its delay (the high-tier timelock or the low-tier delay).
    bool public unanimityFastPath = true;
    /// @notice Minimum age before a low-tier proposal may execute, so no agent majority
    ///         can pass and execute an action in the block it was proposed. Every seated
    ///         human gets this long to vote it down or veto it. May be zero.
    uint256 public lowTierDelay = 1 days;
    /// @notice Function selectors a proposal may carry on the low tier. Anything not
    ///         listed is High tier. Curated by the root or by governance.
    mapping(bytes4 => bool) public lowTierSelector;

    uint256 public constant MIN_VOTING_PERIOD = 1 hours;
    uint256 public constant MAX_VOTING_PERIOD = 30 days;
    uint256 public constant MAX_TIMELOCK = 30 days;

    /// @notice `setGovernor(address)` — the selector every governed contract (OrgRegistry,
    ///         Treasury, EscalationRouter, MarketplacePayments, the policies) uses to hand
    ///         its constitutional authority to a new address.
    /// @dev Rebinding a governor is re-weighting the electorate by another name: whoever
    ///      receives it can skip this module entirely. So, like a proposal that targets
    ///      this module, it is never Low tier — it always passes the human quorum, the
    ///      timelock, and the veto window.
    bytes4 public constant SET_GOVERNOR_SELECTOR = bytes4(keccak256("setGovernor(address)"));
    /// @notice `rotateRoot(address)` — OrgRegistry's and SessionRegistry's root handover.
    /// @dev Replacing the root moves the tree's top, the fallback resolve authority and
    ///      session issuance, so a proposal calling it directly is High tier.
    bytes4 public constant ROTATE_ROOT_SELECTOR = bytes4(keccak256("rotateRoot(address)"));
    /// @notice `setIssuer(address)` — SessionRegistry's session-minting authority.
    /// @dev Whoever is the issuer mints agent session keys, so naming one is High tier:
    ///      agent seats must never be able to hand themselves issuance.
    bytes4 public constant SET_ISSUER_SELECTOR = bytes4(keccak256("setIssuer(address)"));

    /// @notice `withdraw(address,uint256)` — Treasury's outflow to an arbitrary address.
    ///         Proposals carrying it are always High tier.
    bytes4 public constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(address,uint256)"));
    /// @notice `OrgRegistry.addNode(address,NodeKind,address)` — hiring an agent, the one
    ///         action seeded as low tier. A `HumanRoot` kind is refused on the low tier:
    ///         the router treats such a node as a final approver.
    bytes4 public constant ADD_NODE_SELECTOR = bytes4(keccak256("addNode(address,uint8,address)"));
    /// @dev `IOrgRegistry.NodeKind.HumanRoot`, as `addNode` ABI-encodes it.
    uint256 private constant HUMAN_ROOT_KIND = 0;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        Tier tier,
        address target,
        bytes32 actionHash
    );
    event Voted(
        uint256 indexed proposalId, address indexed voter, bool support, uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId, address indexed vetoer);
    event ProposalDefeated(uint256 indexed proposalId);
    event VotingPowerUpdated(address indexed voter, uint256 power, SeatRole role);
    event HumanAdmitted(address indexed human, uint256 power);
    event HumanRemoved(address indexed human);
    event QuorumYesUpdated(uint256 quorumYes);
    event QuorumHumanYesUpdated(uint256 quorumHumanYes);
    event TimingUpdated(uint256 votingPeriod, uint256 highTierTimelock);
    event UnanimityFastPathUpdated(bool enabled);
    event RootRotated(address indexed oldRoot, address indexed newRoot);
    event LowTierDelayUpdated(uint256 lowTierDelay);
    event LowTierSelectorUpdated(bytes4 indexed selector, bool allowed);

    error ProposalNotActive(uint256 proposalId);
    error ProposalNotFound(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId, address voter);
    error NoVotingPower(address voter);
    error QuorumNotMet(uint256 proposalId);
    error TimelockNotElapsed(uint256 proposalId, uint256 eta);
    error NotHumanRoot(address caller);
    error NotHumanSeat(address caller);
    /// @dev Seat admin over humans is constitutional: only an executed proposal
    ///      (or the root of an org with no human seated yet) may change it.
    error NotGovernance(address caller);
    error LastHumanSeat(address human);
    error NotAHumanSeat(address account);
    error ZeroPower();
    error ActionFailed(address target);
    error ZeroAddress();
    error ZeroQuorum();
    error InvalidSeatRole(SeatRole role);
    error InvalidTiming(uint256 votingPeriod, uint256 highTierTimelock);
    error SelfTargetNotHighTier();
    error GovernorTransferNotHighTier();
    error WithdrawNotHighTier();
    error RootAuthorityNotHighTier();
    /// @dev A root is a human; an agent seat cannot be handed one.
    error RootIsAgentSeat(address account);
    /// @dev The action is not allow-listed for the low tier; propose it as High tier.
    error ActionNotLowTier(bytes4 selector);
    /// @dev Yes-weight does not exceed no-weight; the proposal cannot execute yet.
    error Outvoted(uint256 proposalId);
    error InvalidLowTierDelay(uint256 lowTierDelay);

    /// @dev Root acts directly; the module itself qualifies so an executed High-tier
    ///      proposal targeting this contract can retune parameters through governance.
    modifier onlyRootOrGovernance() {
        if (msg.sender != address(this) && !_rootMayAct()) {
            revert NotHumanRoot(msg.sender);
        }
        _;
    }

    /// @dev The root's direct authority is the privilege of a seated human, not of an
    ///      address. It holds while the root has a funded Human seat, and — so an org
    ///      deployed with `rootPower_ = 0` is not born ungovernable — while no human is
    ///      seated at all. Once governance revokes the root's seat, the root is a
    ///      stranger to this module.
    function _rootMayAct() private view returns (bool) {
        if (msg.sender != humanRoot) return false;
        return humanSeatCount == 0 || seatRole[humanRoot] == SeatRole.Human;
    }

    /// @param humanRoot_ The org's root human; sole direct admin of seats and params.
    /// @param rootPower_ Voting weight seeded for the root at deploy. Non-zero keeps a
    ///        fresh org governable by its only human from block one; pass a weight above
    ///        the default agent weight (e.g. 2) so humans outweigh agent seats. Zero
    ///        skips seeding for orgs that configure seats explicitly.
    constructor(address humanRoot_, uint256 rootPower_) {
        if (humanRoot_ == address(0)) revert ZeroAddress();
        humanRoot = humanRoot_;
        lowTierSelector[ADD_NODE_SELECTOR] = true;
        emit LowTierSelectorUpdated(ADD_NODE_SELECTOR, true);
        if (rootPower_ > 0) {
            votingPower[humanRoot_] = rootPower_;
            seatRole[humanRoot_] = SeatRole.Human;
            totalVotingPower = rootPower_;
            totalHumanVotingPower = rootPower_;
            humanSeatCount = 1;
            emit VotingPowerUpdated(humanRoot_, rootPower_, SeatRole.Human);
        }
    }

    /// @notice Configure a seat's voting weight and role. Pass power 0 to revoke.
    /// @dev Agent seats are root-or-governance, as before. Anything that touches a
    ///      Human seat — creating one, re-weighting one, or revoking one — is seat
    ///      admin and takes the governance path (see `admitHuman`).
    function setVotingPower(address voter, uint256 power, SeatRole role) external {
        if (voter == address(0)) revert ZeroAddress();
        if (power == 0) {
            role = SeatRole.None;
        } else if (role == SeatRole.None) {
            revert InvalidSeatRole(role);
        }
        if (role == SeatRole.Human || seatRole[voter] == SeatRole.Human) {
            _authorizeSeatAdmin();
        } else if (msg.sender != address(this) && !_rootMayAct()) {
            revert NotHumanRoot(msg.sender);
        }
        _setSeat(voter, power, role);
    }

    /// @notice Seat a human (or re-weight one already seated). Governance only.
    /// @dev This is the multi-human primitive: an org admits a partner by passing a
    ///      High-tier proposal, so the humans already seated see it, can vote it down,
    ///      and can veto it. `power` is the weight the new seat votes with — it also
    ///      raises the unanimity bar, since the fast path needs every human's yes.
    function admitHuman(address human, uint256 power) external {
        if (human == address(0)) revert ZeroAddress();
        // A human seat is by definition funded: power 0 is a revocation, and
        // revocation has its own governance-checked entry point.
        if (power == 0) revert ZeroPower();
        _authorizeSeatAdmin();
        _setSeat(human, power, SeatRole.Human);
        emit HumanAdmitted(human, power);
    }

    /// @notice Revoke a human's seat — their vote and their veto. Governance only.
    /// @dev Refuses the last one. An org with no human seat has handed high-tier final
    ///      say to nobody at all (agent yes-weight never satisfies it), which would
    ///      freeze the constitution permanently rather than pass it on.
    function removeHuman(address human) external {
        if (seatRole[human] != SeatRole.Human) revert NotAHumanSeat(human);
        _authorizeSeatAdmin();
        _setSeat(human, 0, SeatRole.None);
        emit HumanRemoved(human);
    }

    /// @dev Who may change the human roster: an executed proposal, or — while the org
    ///      has no human seat to consult — the root, which is how a `rootPower_ = 0`
    ///      deployment seats its first human.
    function _authorizeSeatAdmin() private view {
        if (msg.sender == address(this)) return;
        if (humanSeatCount == 0 && msg.sender == humanRoot) return;
        revert NotGovernance(msg.sender);
    }

    /// @dev Single writer for seat state, so the weight sums and the human head count
    ///      cannot drift apart, and the last-human guard has exactly one place to sit.
    function _setSeat(address voter, uint256 power, SeatRole role) private {
        uint256 prevPower = votingPower[voter];
        SeatRole prevRole = seatRole[voter];
        if (prevRole == SeatRole.Human && role != SeatRole.Human) {
            if (humanSeatCount == 1) revert LastHumanSeat(voter);
            humanSeatCount -= 1;
        } else if (prevRole != SeatRole.Human && role == SeatRole.Human) {
            humanSeatCount += 1;
        }
        totalVotingPower = totalVotingPower - prevPower + power;
        if (prevRole == SeatRole.Human) totalHumanVotingPower -= prevPower;
        if (role == SeatRole.Human) totalHumanVotingPower += power;
        votingPower[voter] = power;
        seatRole[voter] = role;
        emit VotingPowerUpdated(voter, power, role);
    }

    /// @notice Rotate the org's root key to `newRoot` here and on each of `rooted`
    ///         (OrgRegistry, SessionRegistry — any contract exposing `rotateRoot(address)`
    ///         with this module as its governor). Governance only, so always High tier:
    ///         the human quorum, the timelock and the veto window all apply.
    /// @dev The old root's Human seat moves to `newRoot` with its weight; if `newRoot`
    ///      already holds a Human seat (a partner being promoted), the old seat is simply
    ///      revoked. Either way the retired key loses its vote, its veto and its direct
    ///      admin in the same step it loses the root. Votes it already cast on open
    ///      proposals stand; any remaining human can veto those.
    ///
    ///      Rotating every contract in one call keeps them from disagreeing about who
    ///      the root is; a rotation that fails on any of them reverts as a whole.
    ///      Before any human is seated the root itself may call this (the same
    ///      bootstrap as `admitHuman`).
    function rotateRoot(address newRoot, address[] calldata rooted) external {
        _authorizeSeatAdmin();
        if (newRoot == address(0)) revert ZeroAddress();
        address oldRoot = humanRoot;
        SeatRole newRole = seatRole[newRoot];
        if (newRole == SeatRole.Agent) revert RootIsAgentSeat(newRoot);
        if (seatRole[oldRoot] == SeatRole.Human && newRoot != oldRoot) {
            uint256 power = votingPower[oldRoot];
            if (newRole == SeatRole.None) _setSeat(newRoot, power, SeatRole.Human);
            _setSeat(oldRoot, 0, SeatRole.None);
        }
        humanRoot = newRoot;
        emit RootRotated(oldRoot, newRoot);
        for (uint256 i = 0; i < rooted.length; i++) {
            IRootRotatable(rooted[i]).rotateRoot(newRoot);
        }
    }

    /// @notice Update the all-seat yes quorum (low tier).
    function setQuorumYes(uint256 quorumYes_) external onlyRootOrGovernance {
        if (quorumYes_ == 0) revert ZeroQuorum();
        quorumYes = quorumYes_;
        emit QuorumYesUpdated(quorumYes_);
    }

    /// @notice Update the human-seat yes quorum (high tier final say).
    function setQuorumHumanYes(uint256 quorumHumanYes_) external onlyRootOrGovernance {
        if (quorumHumanYes_ == 0) revert ZeroQuorum();
        quorumHumanYes = quorumHumanYes_;
        emit QuorumHumanYesUpdated(quorumHumanYes_);
    }

    /// @notice Update the voting window and high-tier timelock for future proposals.
    ///         Existing proposals keep the deadline/eta captured at creation.
    function setTiming(uint256 votingPeriod_, uint256 highTierTimelock_)
        external
        onlyRootOrGovernance
    {
        if (
            votingPeriod_ < MIN_VOTING_PERIOD || votingPeriod_ > MAX_VOTING_PERIOD
                || highTierTimelock_ > MAX_TIMELOCK
        ) {
            revert InvalidTiming(votingPeriod_, highTierTimelock_);
        }
        votingPeriod = votingPeriod_;
        highTierTimelock = highTierTimelock_;
        emit TimingUpdated(votingPeriod_, highTierTimelock_);
    }

    /// @notice Enable or disable immediate execution on unanimous human yes.
    function setUnanimityFastPath(bool enabled) external onlyRootOrGovernance {
        unanimityFastPath = enabled;
        emit UnanimityFastPathUpdated(enabled);
    }

    /// @notice Update the minimum age of a low-tier proposal before it may execute.
    function setLowTierDelay(uint256 lowTierDelay_) external onlyRootOrGovernance {
        if (lowTierDelay_ > MAX_TIMELOCK) revert InvalidLowTierDelay(lowTierDelay_);
        lowTierDelay = lowTierDelay_;
        emit LowTierDelayUpdated(lowTierDelay_);
    }

    /// @notice Allow or refuse a function selector on the low tier. A governor transfer
    ///         can never be allow-listed.
    function setLowTierSelector(bytes4 selector, bool allowed) external onlyRootOrGovernance {
        if (allowed && selector == SET_GOVERNOR_SELECTOR) revert GovernorTransferNotHighTier();
        lowTierSelector[selector] = allowed;
        emit LowTierSelectorUpdated(selector, allowed);
    }

    /// @notice Low-tier quorum actually enforced: never more yes-weight than the
    ///         seated electorate holds, so quorum cannot demand absent voters.
    function effectiveQuorumYes() public view returns (uint256) {
        uint256 available = totalVotingPower;
        if (available > 0 && available < quorumYes) return available;
        return quorumYes;
    }

    /// @notice High-tier human quorum actually enforced, capped at seated human weight.
    function effectiveQuorumHumanYes() public view returns (uint256) {
        uint256 available = totalHumanVotingPower;
        if (available > 0 && available < quorumHumanYes) return available;
        return quorumHumanYes;
    }

    /// @notice Create a constitutional proposal bound to executable calldata. Only a
    ///         seated voter (or the root while it may act) may propose.
    ///         Proposals targeting this module (parameter changes) must be High tier
    ///         so agent seats can never re-weight the electorate via a low-tier vote;
    ///         the same holds for any proposal that would rebind a governed contract's
    ///         governor (`SET_GOVERNOR_SELECTOR`), which is the electorate by proxy.
    ///         Beyond those, a low-tier proposal must carry an allow-listed selector.
    function propose(
        Tier tier,
        address target,
        bytes calldata data
    ) external returns (uint256 proposalId) {
        if (votingPower[msg.sender] == 0 && !_rootMayAct()) revert NoVotingPower(msg.sender);
        if (target == address(0)) revert ZeroAddress();
        if (target == address(this) && tier != Tier.High) revert SelfTargetNotHighTier();
        if (tier != Tier.High && data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            if (selector == SET_GOVERNOR_SELECTOR) revert GovernorTransferNotHighTier();
            if (selector == ROTATE_ROOT_SELECTOR || selector == SET_ISSUER_SELECTOR) {
                revert RootAuthorityNotHighTier();
            }
        }
        if (tier != Tier.High && data.length >= 4 && bytes4(data[:4]) == WITHDRAW_SELECTOR) {
            revert WithdrawNotHighTier();
        }
        // Everything not allow-listed (the explicit refusals above name the governed
        // actions that have their own error) is High tier only.
        if (tier != Tier.High) _requireLowTierAction(target, data);
        proposalId = nextProposalId++;
        bytes32 actionHash = keccak256(abi.encode(target, data));
        uint256 deadline = block.timestamp + votingPeriod;
        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            tier: tier,
            target: target,
            actionHash: actionHash,
            data: data,
            yesVotes: 0,
            noVotes: 0,
            yesHumanVotes: 0,
            deadline: deadline,
            eta: tier == Tier.High ? deadline + highTierTimelock : block.timestamp + lowTierDelay,
            state: ProposalState.Active
        });
        emit ProposalCreated(proposalId, msg.sender, tier, target, actionHash);
    }

    /// @dev What may ride the low tier: never this module, never a governor transfer,
    ///      and otherwise only an allow-listed selector. A hire may not seat a
    ///      `HumanRoot` node, which the router would accept as a final approver.
    function _requireLowTierAction(address target, bytes calldata data) private view {
        if (target == address(this)) revert SelfTargetNotHighTier();
        if (data.length < 4) revert ActionNotLowTier(bytes4(0));
        bytes4 selector = bytes4(data[:4]);
        if (selector == SET_GOVERNOR_SELECTOR) revert GovernorTransferNotHighTier();
        if (!lowTierSelector[selector]) revert ActionNotLowTier(selector);
        if (
            selector == ADD_NODE_SELECTOR
                && (data.length < 100 || uint256(bytes32(data[36:68])) == HUMAN_ROOT_KIND)
        ) {
            revert ActionNotLowTier(selector);
        }
    }

    /// @notice Cast a yes/no vote weighted by the caller's seat.
    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Active || block.timestamp > p.deadline) {
            revert ProposalNotActive(proposalId);
        }
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        uint256 weight = votingPower[msg.sender];
        if (weight == 0) revert NoVotingPower(msg.sender);

        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            p.yesVotes += weight;
            if (seatRole[msg.sender] == SeatRole.Human) {
                p.yesHumanVotes += weight;
            }
        } else {
            p.noVotes += weight;
            if (seatRole[msg.sender] == SeatRole.Human) {
                noHumanVotes[proposalId] += weight;
            }
        }
        emit Voted(proposalId, msg.sender, support, weight);
    }

    /// @notice Veto an active proposal before execution. Any funded Human seat may —
    ///         multi-human orgs share the safety valve, and no seat outranks another
    ///         in holding it. The root qualifies through its own seat (or, before any
    ///         human is seated, as the bootstrap holder of one).
    function veto(uint256 proposalId) external {
        bool humanSeat = votingPower[msg.sender] > 0 && seatRole[msg.sender] == SeatRole.Human;
        if (!humanSeat && !_rootMayAct()) revert NotHumanSeat(msg.sender);
        Proposal storage p = proposals[proposalId];
        // An unused id reads as an Active zero struct. `propose` never stores a zero
        // target, so that is what tells a real proposal from an empty slot; a veto
        // written to an empty slot would be overwritten by the proposal that takes it.
        if (p.target == address(0)) revert ProposalNotFound(proposalId);
        if (p.state != ProposalState.Active) revert ProposalNotActive(proposalId);
        p.state = ProposalState.Vetoed;
        emit ProposalVetoed(proposalId, msg.sender);
    }

    /// @notice Execute a proposal that has met the tier's effective quorum, whose
    ///         yes-weight exceeds its no-weight, and whose delay has elapsed (the
    ///         high-tier timelock or the low-tier delay) — unless every human seat has
    ///         already voted yes.
    /// @dev Each tier is carried and defeated by the same electorate: all seats on low
    ///      tier, human seats only on high tier. Agent seats review a high-tier
    ///      proposal; their weight neither defeats one the humans backed nor rescues
    ///      one the humans voted down. A proposal whose yes-weight does not exceed its
    ///      no-weight reverts `Outvoted` while voting is open and is closed as Defeated
    ///      once the voting deadline has passed.
    function execute(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.state != ProposalState.Active) revert ProposalNotActive(proposalId);

        bool high = p.tier == Tier.High;
        if (high) {
            if (p.yesHumanVotes < effectiveQuorumHumanYes()) revert QuorumNotMet(proposalId);
        } else if (p.yesVotes < effectiveQuorumYes()) {
            revert QuorumNotMet(proposalId);
        }
        if (block.timestamp < p.eta && !_unanimousHumanYes(p)) {
            revert TimelockNotElapsed(proposalId, p.eta);
        }

        bool carried = high
            ? p.yesHumanVotes > noHumanVotes[proposalId]
            : p.yesVotes > p.noVotes;
        if (!carried) {
            if (block.timestamp <= p.deadline) revert Outvoted(proposalId);
            p.state = ProposalState.Defeated;
            emit ProposalDefeated(proposalId);
            return;
        }

        p.state = ProposalState.Executed;
        (bool ok, ) = p.target.call(p.data);
        if (!ok) revert ActionFailed(p.target);
        emit ProposalExecuted(proposalId);
    }

    /// @dev The delay shields humans who have not voted; unanimity means none remain.
    ///      Any human no-vote (or weight granted after the yes votes) breaks unanimity,
    ///      so the fast path only fires when every seated human backs the action now.
    function _unanimousHumanYes(Proposal storage p) private view returns (bool) {
        return unanimityFastPath && totalHumanVotingPower > 0
            && p.yesHumanVotes >= totalHumanVotingPower;
    }
}
