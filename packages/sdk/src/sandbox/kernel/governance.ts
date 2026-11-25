/**
 * GovernanceModule: quorum voting for constitutional actions.
 * Mirrors `contracts/src/GovernanceModule.sol`.
 */

import { asSender, emit, externalCall } from "./frame.js";
import * as orgRegistry from "./orgRegistry.js";
import * as sessionRegistry from "./sessionRegistry.js";
import {
  EVM_REVERT,
  SimRevert,
  ZERO_ADDRESS,
  addr,
  byteLength,
  checkedAdd,
  checkedSub,
  type Address,
  type Hex,
} from "./types.js";
import type { Ctx } from "./world.js";

const CONTRACT = "GovernanceModule";

/** Enums by ABI value. */
export const Tier = { Low: 0, High: 1 } as const;
export const ProposalState = {
  Active: 0,
  Executed: 1,
  Vetoed: 2,
  Defeated: 3,
  Expired: 4,
} as const;
export const SeatRole = { None: 0, Human: 1, Agent: 2 } as const;

export const MIN_VOTING_PERIOD = 3_600n;
export const MAX_VOTING_PERIOD = 30n * 86_400n;
export const MAX_TIMELOCK = 30n * 86_400n;
/** How long a proposal stays executable once voting has closed and its delay has elapsed. */
export const EXECUTION_WINDOW = 14n * 86_400n;

/** `bytes4(keccak256("setGovernor(address)"))`. */
export const SET_GOVERNOR_SELECTOR = "0xc42cf535";
/** `bytes4(keccak256("rotateRoot(address)"))`. */
export const ROTATE_ROOT_SELECTOR = "0x611ab368";
/** `bytes4(keccak256("rotateRoot(address,address[])"))`: the module's own rotation. */
export const ROTATE_ROOT_ROOTED_SELECTOR = "0x86c505da";
/** `bytes4(keccak256("setIssuer(address)"))`. */
export const SET_ISSUER_SELECTOR = "0x55cc4e57";
/** `bytes4(keccak256("withdraw(address,uint256)"))`: Treasury's outflow, always High tier. */
export const WITHDRAW_SELECTOR = "0xf3fef3a3";
/** `bytes4(keccak256("addNode(address,uint8,address)"))`: the one selector seeded as low tier. */
export const ADD_NODE_SELECTOR = "0x38a08841";
/** Default minimum age of a low-tier proposal before it may execute. */
export const DEFAULT_LOW_TIER_DELAY = 86_400n;
/** `IOrgRegistry.NodeKind.HumanRoot`, as `addNode` ABI-encodes it. */
const HUMAN_ROOT_KIND = 0n;

export interface ProposalRecord {
  proposer: Address;
  tier: number;
  target: Address;
  actionHash: Hex;
  data: Hex;
  yesVotes: bigint;
  noVotes: bigint;
  yesHumanVotes: bigint;
  deadline: bigint;
  eta: bigint;
  state: number;
}

export interface GovernanceState {
  humanRoot: Address;
  nextProposalId: bigint;
  /** Keyed by proposal id as a decimal string. */
  proposals: Record<string, ProposalRecord>;
  /**
   * Human-seat no-weight by proposal id: what counts against a high-tier
   * proposal. Optional because a world saved before it existed has none.
   */
  noHumanVotes?: Record<string, bigint>;
  hasVoted: Record<string, Record<Address, boolean>>;
  /**
   * Human seats that voted yes, by proposal id, in vote order: what `veto` asks
   * when the outgoing root tries to veto its own replacement. Optional because a
   * world saved before it existed has none.
   */
  yesHumanVoters?: Record<string, Address[]>;
  votingPower: Record<Address, bigint>;
  seatRole: Record<Address, number>;
  totalVotingPower: bigint;
  totalHumanVotingPower: bigint;
  humanSeatCount: bigint;
  quorumYes: bigint;
  quorumHumanYes: bigint;
  votingPeriod: bigint;
  highTierTimelock: bigint;
  unanimityFastPath: boolean;
  /**
   * Minimum age of a low-tier proposal before it may execute. Optional because a
   * world saved before it existed has none: it reads as the default.
   */
  lowTierDelay?: bigint;
  /**
   * Selectors (lower-case `0x` + 8 hex) a proposal may carry on the low tier.
   * Optional because a world saved before it existed has none: it reads as the
   * constructor's seed, `addNode` alone.
   */
  lowTierSelector?: Record<string, boolean>;
}

export function blankGovernance(): GovernanceState {
  return {
    humanRoot: ZERO_ADDRESS,
    nextProposalId: 1n,
    proposals: {},
    noHumanVotes: {},
    hasVoted: {},
    yesHumanVoters: {},
    votingPower: {},
    seatRole: {},
    totalVotingPower: 0n,
    totalHumanVotingPower: 0n,
    humanSeatCount: 0n,
    quorumYes: 2n,
    quorumHumanYes: 1n,
    votingPeriod: 3n * 86_400n,
    highTierTimelock: 86_400n,
    unanimityFastPath: true,
    lowTierDelay: DEFAULT_LOW_TIER_DELAY,
    lowTierSelector: { [ADD_NODE_SELECTOR]: true },
  };
}

/** `lowTierDelay()`. */
export function lowTierDelay(ctx: Ctx): bigint {
  return ctx.world.governance.lowTierDelay ?? DEFAULT_LOW_TIER_DELAY;
}

function lowTierSelectors(state: GovernanceState): Record<string, boolean> {
  return (state.lowTierSelector ??= { [ADD_NODE_SELECTOR]: true });
}

/** `lowTierSelector(selector)`. */
export function lowTierSelector(ctx: Ctx, selector: Hex): boolean {
  return lowTierSelectors(ctx.world.governance)[selector.toLowerCase()] ?? false;
}

const ZERO_HASH: Hex = `0x${"0".repeat(64)}`;

/** `proposals[id]`: an unset slot reads as the zero struct (Low tier, Active). */
function blankProposal(): ProposalRecord {
  return {
    proposer: ZERO_ADDRESS,
    tier: Tier.Low,
    target: ZERO_ADDRESS,
    actionHash: ZERO_HASH,
    data: "0x",
    yesVotes: 0n,
    noVotes: 0n,
    yesHumanVotes: 0n,
    deadline: 0n,
    eta: 0n,
    state: ProposalState.Active,
  };
}

/** A storage reference: the slot is materialised so a write through it lands. */
function proposalRef(state: GovernanceState, proposalId: bigint): ProposalRecord {
  return (state.proposals[proposalId.toString()] ??= blankProposal());
}

/** `proposals(id)`. */
export function proposals(ctx: Ctx, proposalId: bigint): ProposalRecord {
  return { ...(ctx.world.governance.proposals[proposalId.toString()] ?? blankProposal()) };
}

/** `noHumanVotes(id)`. */
export function noHumanVotes(ctx: Ctx, proposalId: bigint): bigint {
  return ctx.world.governance.noHumanVotes?.[proposalId.toString()] ?? 0n;
}

export function hasVoted(ctx: Ctx, proposalId: bigint, voter: Address): boolean {
  return ctx.world.governance.hasVoted[proposalId.toString()]?.[addr(voter)] ?? false;
}

function powerOf(state: GovernanceState, voter: Address): bigint {
  return state.votingPower[voter] ?? 0n;
}

function roleOf(state: GovernanceState, voter: Address): number {
  return state.seatRole[voter] ?? SeatRole.None;
}

/**
 * The root's direct authority holds while it has a funded Human seat, and
 * while no human is seated at all.
 */
function rootMayAct(ctx: Ctx): boolean {
  const state = ctx.world.governance;
  if (ctx.sender !== state.humanRoot) return false;
  return state.humanSeatCount === 0n || roleOf(state, state.humanRoot) === SeatRole.Human;
}

function isSelf(ctx: Ctx): boolean {
  return ctx.sender === ctx.world.addresses.governanceModule;
}

function onlyRootOrGovernance(ctx: Ctx): void {
  if (!isSelf(ctx) && !rootMayAct(ctx)) {
    throw new SimRevert("NotHumanRoot", { caller: ctx.sender });
  }
}

export function deploy(ctx: Ctx, address: Address, humanRoot_: Address, rootPower_: bigint): void {
  const humanRoot = addr(humanRoot_);
  if (humanRoot === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  ctx.world.addresses.governanceModule = address;
  const state = { ...blankGovernance(), humanRoot };
  ctx.world.governance = state;
  emit(ctx, address, CONTRACT, "LowTierSelectorUpdated", {
    selector: ADD_NODE_SELECTOR,
    allowed: true,
  });
  if (rootPower_ > 0n) {
    state.votingPower[humanRoot] = rootPower_;
    state.seatRole[humanRoot] = SeatRole.Human;
    state.totalVotingPower = rootPower_;
    state.totalHumanVotingPower = rootPower_;
    state.humanSeatCount = 1n;
    emit(ctx, address, CONTRACT, "VotingPowerUpdated", {
      voter: humanRoot,
      power: rootPower_,
      role: SeatRole.Human,
    });
  }
}

export function setVotingPower(ctx: Ctx, voter_: Address, power: bigint, role_: number): void {
  const state = ctx.world.governance;
  const voter = addr(voter_);
  let role = role_;
  if (voter === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  if (power === 0n) {
    role = SeatRole.None;
  } else if (role === SeatRole.None) {
    throw new SimRevert("InvalidSeatRole", { role });
  }
  if (role === SeatRole.Human || roleOf(state, voter) === SeatRole.Human) {
    authorizeSeatAdmin(ctx);
  } else if (!isSelf(ctx) && !rootMayAct(ctx)) {
    throw new SimRevert("NotHumanRoot", { caller: ctx.sender });
  }
  setSeat(ctx, voter, power, role);
}

export function admitHuman(ctx: Ctx, human_: Address, power: bigint): void {
  const human = addr(human_);
  if (human === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  if (power === 0n) throw new SimRevert("ZeroPower");
  authorizeSeatAdmin(ctx);
  setSeat(ctx, human, power, SeatRole.Human);
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "HumanAdmitted", { human, power });
}

export function removeHuman(ctx: Ctx, human_: Address): void {
  const human = addr(human_);
  if (roleOf(ctx.world.governance, human) !== SeatRole.Human) {
    throw new SimRevert("NotAHumanSeat", { account: human });
  }
  authorizeSeatAdmin(ctx);
  setSeat(ctx, human, 0n, SeatRole.None);
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "HumanRemoved", { human });
}

/**
 * Rotate the root key here and on each of `rooted`. The old root's Human seat
 * moves to `newRoot` (or is revoked when `newRoot` already holds one).
 */
export function rotateRoot(ctx: Ctx, newRoot_: Address, rooted: Address[]): void {
  const state = ctx.world.governance;
  const self = ctx.world.addresses.governanceModule;
  const newRoot = addr(newRoot_);
  authorizeSeatAdmin(ctx);
  if (newRoot === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  const oldRoot = state.humanRoot;
  const newRole = roleOf(state, newRoot);
  if (newRole === SeatRole.Agent) throw new SimRevert("RootIsAgentSeat", { account: newRoot });
  if (roleOf(state, oldRoot) === SeatRole.Human && newRoot !== oldRoot) {
    const power = powerOf(state, oldRoot);
    if (newRole === SeatRole.None) setSeat(ctx, newRoot, power, SeatRole.Human);
    setSeat(ctx, oldRoot, 0n, SeatRole.None);
  }
  state.humanRoot = newRoot;
  emit(ctx, self, CONTRACT, "RootRotated", { oldRoot, newRoot });
  for (const target_ of rooted) {
    // A typed call: a revert bubbles. The sandbox holds one OrgRegistry and one
    // SessionRegistry; any other address has no `rotateRoot` (or no code), which
    // the EVM answers with an empty revert.
    const target = addr(target_);
    const asGov = asSender(ctx, self);
    if (target === ctx.world.addresses.orgRegistry) orgRegistry.rotateRoot(asGov, newRoot);
    else if (target === ctx.world.addresses.sessionRegistry) {
      sessionRegistry.rotateRoot(asGov, newRoot);
    } else throw new SimRevert(EVM_REVERT);
  }
}

/** An executed proposal, or the root while the org has no human seat to consult. */
function authorizeSeatAdmin(ctx: Ctx): void {
  const state = ctx.world.governance;
  if (isSelf(ctx)) return;
  if (state.humanSeatCount === 0n && ctx.sender === state.humanRoot) return;
  throw new SimRevert("NotGovernance", { caller: ctx.sender });
}

/** Single writer for seat state, so the weight sums and the human head count cannot drift. */
function setSeat(ctx: Ctx, voter: Address, power: bigint, role: number): void {
  const state = ctx.world.governance;
  const prevPower = powerOf(state, voter);
  const prevRole = roleOf(state, voter);
  if (prevRole === SeatRole.Human && role !== SeatRole.Human) {
    if (state.humanSeatCount === 1n) throw new SimRevert("LastHumanSeat", { human: voter });
    state.humanSeatCount -= 1n;
  } else if (prevRole !== SeatRole.Human && role === SeatRole.Human) {
    state.humanSeatCount += 1n;
  }
  state.totalVotingPower = checkedAdd(checkedSub(state.totalVotingPower, prevPower), power);
  if (prevRole === SeatRole.Human) {
    state.totalHumanVotingPower = checkedSub(state.totalHumanVotingPower, prevPower);
  }
  if (role === SeatRole.Human) {
    state.totalHumanVotingPower = checkedAdd(state.totalHumanVotingPower, power);
  }
  state.votingPower[voter] = power;
  state.seatRole[voter] = role;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "VotingPowerUpdated", {
    voter,
    power,
    role,
  });
}

export function setQuorumYes(ctx: Ctx, quorumYes_: bigint): void {
  onlyRootOrGovernance(ctx);
  if (quorumYes_ === 0n) throw new SimRevert("ZeroQuorum");
  ctx.world.governance.quorumYes = quorumYes_;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "QuorumYesUpdated", {
    quorumYes: quorumYes_,
  });
}

export function setQuorumHumanYes(ctx: Ctx, quorumHumanYes_: bigint): void {
  onlyRootOrGovernance(ctx);
  if (quorumHumanYes_ === 0n) throw new SimRevert("ZeroQuorum");
  ctx.world.governance.quorumHumanYes = quorumHumanYes_;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "QuorumHumanYesUpdated", {
    quorumHumanYes: quorumHumanYes_,
  });
}

export function setTiming(ctx: Ctx, votingPeriod_: bigint, highTierTimelock_: bigint): void {
  onlyRootOrGovernance(ctx);
  if (
    votingPeriod_ < MIN_VOTING_PERIOD ||
    votingPeriod_ > MAX_VOTING_PERIOD ||
    highTierTimelock_ > MAX_TIMELOCK
  ) {
    throw new SimRevert("InvalidTiming", {
      votingPeriod: votingPeriod_,
      highTierTimelock: highTierTimelock_,
    });
  }
  ctx.world.governance.votingPeriod = votingPeriod_;
  ctx.world.governance.highTierTimelock = highTierTimelock_;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "TimingUpdated", {
    votingPeriod: votingPeriod_,
    highTierTimelock: highTierTimelock_,
  });
}

export function setUnanimityFastPath(ctx: Ctx, enabled: boolean): void {
  onlyRootOrGovernance(ctx);
  ctx.world.governance.unanimityFastPath = enabled;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "UnanimityFastPathUpdated", {
    enabled,
  });
}

export function setLowTierDelay(ctx: Ctx, lowTierDelay_: bigint): void {
  onlyRootOrGovernance(ctx);
  if (lowTierDelay_ > MAX_TIMELOCK) {
    throw new SimRevert("InvalidLowTierDelay", { lowTierDelay: lowTierDelay_ });
  }
  ctx.world.governance.lowTierDelay = lowTierDelay_;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "LowTierDelayUpdated", {
    lowTierDelay: lowTierDelay_,
  });
}

/** Allow or refuse a selector on the low tier. A governor transfer can never be allowed. */
export function setLowTierSelector(ctx: Ctx, selector_: Hex, allowed: boolean): void {
  onlyRootOrGovernance(ctx);
  const selector = selector_.toLowerCase();
  if (allowed && selector === SET_GOVERNOR_SELECTOR) {
    throw new SimRevert("GovernorTransferNotHighTier");
  }
  lowTierSelectors(ctx.world.governance)[selector] = allowed;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "LowTierSelectorUpdated", {
    selector,
    allowed,
  });
}

/** Low-tier quorum actually enforced: never more yes-weight than the seated electorate holds. */
export function effectiveQuorumYes(ctx: Ctx): bigint {
  const state = ctx.world.governance;
  const available = state.totalVotingPower;
  if (available > 0n && available < state.quorumYes) return available;
  return state.quorumYes;
}

/** High-tier human quorum actually enforced, capped at seated human weight. */
export function effectiveQuorumHumanYes(ctx: Ctx): bigint {
  const state = ctx.world.governance;
  const available = state.totalHumanVotingPower;
  if (available > 0n && available < state.quorumHumanYes) return available;
  return state.quorumHumanYes;
}

export function propose(ctx: Ctx, tier: number, target_: Address, data: Hex): bigint {
  const state = ctx.world.governance;
  const self = ctx.world.addresses.governanceModule;
  const target = addr(target_);
  if (powerOf(state, ctx.sender) === 0n && !rootMayAct(ctx)) {
    throw new SimRevert("NoVotingPower", { voter: ctx.sender });
  }
  if (target === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  if (target === self && tier !== Tier.High) throw new SimRevert("SelfTargetNotHighTier");
  if (tier !== Tier.High && byteLength(data) >= 4) {
    const selector = data.slice(0, 10).toLowerCase();
    if (selector === SET_GOVERNOR_SELECTOR) throw new SimRevert("GovernorTransferNotHighTier");
    if (selector === ROTATE_ROOT_SELECTOR || selector === SET_ISSUER_SELECTOR) {
      throw new SimRevert("RootAuthorityNotHighTier");
    }
    if (selector === WITHDRAW_SELECTOR) throw new SimRevert("WithdrawNotHighTier");
  }
  if (tier !== Tier.High) requireLowTierAction(ctx, target, data);
  const proposalId = state.nextProposalId++;
  const actionHash = ctx.env.actionHash(target, data);
  const deadline = ctx.now + state.votingPeriod;
  state.proposals[proposalId.toString()] = {
    proposer: ctx.sender,
    tier,
    target,
    actionHash,
    data,
    yesVotes: 0n,
    noVotes: 0n,
    yesHumanVotes: 0n,
    deadline,
    eta: tier === Tier.High ? deadline + state.highTierTimelock : ctx.now + lowTierDelay(ctx),
    state: ProposalState.Active,
  };
  emit(ctx, self, CONTRACT, "ProposalCreated", {
    proposalId,
    proposer: ctx.sender,
    tier,
    target,
    actionHash,
  });
  return proposalId;
}

/**
 * What may ride the low tier: never this module, never a governor transfer, and
 * otherwise only an allow-listed selector. A hire may not seat a `HumanRoot` node.
 */
function requireLowTierAction(ctx: Ctx, target: Address, data: Hex): void {
  if (target === ctx.world.addresses.governanceModule) {
    throw new SimRevert("SelfTargetNotHighTier");
  }
  const zero = "0x00000000";
  if (byteLength(data) < 4) throw new SimRevert("ActionNotLowTier", { selector: zero });
  const selector = data.slice(0, 10).toLowerCase();
  if (selector === SET_GOVERNOR_SELECTOR) throw new SimRevert("GovernorTransferNotHighTier");
  if (!lowTierSelector(ctx, selector as Hex)) {
    throw new SimRevert("ActionNotLowTier", { selector });
  }
  if (
    selector === ADD_NODE_SELECTOR &&
    (byteLength(data) < 100 || BigInt(`0x${data.slice(2 + 72, 2 + 136)}`) === HUMAN_ROOT_KIND)
  ) {
    throw new SimRevert("ActionNotLowTier", { selector });
  }
}

export function vote(ctx: Ctx, proposalId: bigint, support: boolean): void {
  const state = ctx.world.governance;
  const p = proposalRef(state, proposalId);
  if (p.state !== ProposalState.Active || ctx.now > p.deadline) {
    throw new SimRevert("ProposalNotActive", { proposalId });
  }
  if (hasVoted(ctx, proposalId, ctx.sender)) {
    throw new SimRevert("AlreadyVoted", { proposalId, voter: ctx.sender });
  }

  const weight = powerOf(state, ctx.sender);
  if (weight === 0n) throw new SimRevert("NoVotingPower", { voter: ctx.sender });

  (state.hasVoted[proposalId.toString()] ??= {})[ctx.sender] = true;
  if (support) {
    p.yesVotes = checkedAdd(p.yesVotes, weight);
    if (roleOf(state, ctx.sender) === SeatRole.Human) {
      p.yesHumanVotes = checkedAdd(p.yesHumanVotes, weight);
      ((state.yesHumanVoters ??= {})[proposalId.toString()] ??= []).push(ctx.sender);
    }
  } else {
    p.noVotes = checkedAdd(p.noVotes, weight);
    if (roleOf(state, ctx.sender) === SeatRole.Human) {
      const tally = (state.noHumanVotes ??= {});
      const key = proposalId.toString();
      tally[key] = checkedAdd(tally[key] ?? 0n, weight);
    }
  }
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "Voted", {
    proposalId,
    voter: ctx.sender,
    support,
    weight,
  });
}

export function veto(ctx: Ctx, proposalId: bigint): void {
  const state = ctx.world.governance;
  const humanSeat = powerOf(state, ctx.sender) > 0n && roleOf(state, ctx.sender) === SeatRole.Human;
  if (!humanSeat && !rootMayAct(ctx)) throw new SimRevert("NotHumanSeat", { caller: ctx.sender });
  // An unused id reads as the zero struct; `propose` never stores a zero target.
  const p = state.proposals[proposalId.toString()];
  if (!p || p.target === ZERO_ADDRESS) throw new SimRevert("ProposalNotFound", { proposalId });
  if (p.state !== ProposalState.Active) throw new SimRevert("ProposalNotActive", { proposalId });
  if (
    ctx.sender === state.humanRoot &&
    rotatesRootAway(state, p) &&
    otherHumanVotedYes(state, proposalId)
  ) {
    throw new SimRevert("OutgoingRootVetoIgnored", { proposalId });
  }
  p.state = ProposalState.Vetoed;
  emit(ctx, ctx.world.addresses.governanceModule, CONTRACT, "ProposalVetoed", {
    proposalId,
    vetoer: ctx.sender,
  });
}

/** True when the proposal calls `rotateRoot` naming a root other than the current one. */
function rotatesRootAway(state: GovernanceState, p: ProposalRecord): boolean {
  // A 4-byte selector plus one address word.
  if (byteLength(p.data) < 36) return false;
  const selector = p.data.slice(0, 10).toLowerCase();
  if (selector !== ROTATE_ROOT_SELECTOR && selector !== ROTATE_ROOT_ROOTED_SELECTOR) return false;
  // The word's low 20 bytes: the contract truncates it to an address.
  return addr(`0x${p.data.slice(2 + 8 + 24, 2 + 8 + 64)}`) !== state.humanRoot;
}

/**
 * Whether a current Human seat other than the root has voted yes. A voter
 * unseated since still sits in the list, so the seat is read at veto time.
 */
function otherHumanVotedYes(state: GovernanceState, proposalId: bigint): boolean {
  const voters = state.yesHumanVoters?.[proposalId.toString()] ?? [];
  return voters.some(
    (v) => v !== state.humanRoot && roleOf(state, v) === SeatRole.Human && powerOf(state, v) > 0n,
  );
}

export function execute(ctx: Ctx, proposalId: bigint): void {
  const state = ctx.world.governance;
  const self = ctx.world.addresses.governanceModule;
  const p = proposalRef(state, proposalId);
  if (p.state !== ProposalState.Active) throw new SimRevert("ProposalNotActive", { proposalId });

  // A stale yes-majority cannot be cashed in: past the window the proposal closes, no revert.
  const executableUntil = (p.eta > p.deadline ? p.eta : p.deadline) + EXECUTION_WINDOW;
  if (ctx.now > executableUntil) {
    p.state = ProposalState.Expired;
    emit(ctx, self, CONTRACT, "ProposalExpired", { proposalId });
    return;
  }

  const high = p.tier === Tier.High;
  if (high) {
    if (p.yesHumanVotes < effectiveQuorumHumanYes(ctx)) {
      throw new SimRevert("QuorumNotMet", { proposalId });
    }
  } else if (p.yesVotes < effectiveQuorumYes(ctx)) {
    throw new SimRevert("QuorumNotMet", { proposalId });
  }
  if (ctx.now < p.eta && !unanimousHumanYes(state, p)) {
    throw new SimRevert("TimelockNotElapsed", { proposalId, eta: p.eta });
  }

  // Each tier is carried by the electorate that can pass it: human seats alone on high tier.
  const carried = high ? p.yesHumanVotes > noHumanVotes(ctx, proposalId) : p.yesVotes > p.noVotes;
  if (!carried) {
    if (ctx.now <= p.deadline) throw new SimRevert("Outvoted", { proposalId });
    p.state = ProposalState.Defeated;
    emit(ctx, self, CONTRACT, "ProposalDefeated", { proposalId });
    return;
  }

  p.state = ProposalState.Executed;
  const { target, data } = p;
  const ok = externalCall(ctx, self, target, data);
  if (!ok) throw new SimRevert("ActionFailed", { target });
  emit(ctx, self, CONTRACT, "ProposalExecuted", { proposalId });
}

/** The delay shields humans who have not voted; unanimity means none remain. */
function unanimousHumanYes(state: GovernanceState, p: ProposalRecord): boolean {
  return (
    state.unanimityFastPath &&
    state.totalHumanVotingPower > 0n &&
    p.yesHumanVotes >= state.totalHumanVotingPower
  );
}
