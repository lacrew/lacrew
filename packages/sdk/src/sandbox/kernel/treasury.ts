/**
 * Treasury: holds the org's funds and streams allowances downward.
 * Mirrors `contracts/src/Treasury.sol`.
 */

import { asSender, emit } from "./frame.js";
import * as orgRegistry from "./orgRegistry.js";
import * as token from "./token.js";
import { EVM_REVERT, SimRevert, ZERO_ADDRESS, addr, type Address } from "./types.js";
import type { Ctx } from "./world.js";

const CONTRACT = "Treasury";

export interface TreasuryState {
  orgRegistry: Address;
  token: Address;
  /** Holds bootstrap authority until `governor` is bound. */
  deployer: Address;
  spender: Address;
  governor: Address;
  /** Named by the governor to take over; holds no power until it accepts. */
  pendingGovernor?: Address;
  streamer: Address;
  totalReserved: bigint;
  allowanceBalance: Record<Address, bigint>;
  /**
   * The registry incarnation each node's current allowance was granted under.
   * Optional because a world saved before it existed has none.
   */
  allowanceGeneration?: Record<Address, bigint>;
}

export function blankTreasury(): TreasuryState {
  return {
    orgRegistry: ZERO_ADDRESS,
    token: ZERO_ADDRESS,
    deployer: ZERO_ADDRESS,
    spender: ZERO_ADDRESS,
    governor: ZERO_ADDRESS,
    streamer: ZERO_ADDRESS,
    totalReserved: 0n,
    allowanceBalance: {},
    allowanceGeneration: {},
  };
}

export function deploy(
  ctx: Ctx,
  address: Address,
  orgRegistry_: Address,
  token_: Address,
  spender_: Address,
): void {
  if (addr(orgRegistry_) === ZERO_ADDRESS || addr(token_) === ZERO_ADDRESS) {
    throw new SimRevert("ZeroAddress");
  }
  ctx.world.addresses.treasury = address;
  ctx.world.treasury = {
    ...blankTreasury(),
    orgRegistry: addr(orgRegistry_),
    token: addr(token_),
    spender: addr(spender_),
    deployer: ctx.sender,
  };
}

/** Bind constitutional authority, once, by the deployer. */
export function setGovernor(ctx: Ctx, governor_: Address): void {
  const governor = addr(governor_);
  if (governor === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  if (ctx.world.treasury.governor !== ZERO_ADDRESS) throw new SimRevert("GovernorAlreadySet");
  if (ctx.sender !== ctx.world.treasury.deployer) {
    throw new SimRevert("NotAuthorized", { caller: ctx.sender });
  }
  ctx.world.treasury.governor = governor;
  emit(ctx, ctx.world.addresses.treasury, CONTRACT, "GovernorUpdated", { governor });
}

/** Name the address that may take over governance: the current governor only; zero cancels. */
export function setPendingGovernor(ctx: Ctx, pending_: Address): void {
  const state = ctx.world.treasury;
  const pending = addr(pending_);
  if (state.governor === ZERO_ADDRESS || ctx.sender !== state.governor) {
    throw new SimRevert("NotAuthorized", { caller: ctx.sender });
  }
  state.pendingGovernor = pending;
  emit(ctx, ctx.world.addresses.treasury, CONTRACT, "PendingGovernorUpdated", {
    pendingGovernor: pending,
  });
}

/** Complete the hand-over: only the pending governor may call it. */
export function acceptGovernor(ctx: Ctx): void {
  const state = ctx.world.treasury;
  const pending = state.pendingGovernor ?? ZERO_ADDRESS;
  if (pending === ZERO_ADDRESS || ctx.sender !== pending) {
    throw new SimRevert("NotPendingGovernor", { caller: ctx.sender });
  }
  state.governor = pending;
  state.pendingGovernor = ZERO_ADDRESS;
  emit(ctx, ctx.world.addresses.treasury, CONTRACT, "GovernorUpdated", { governor: pending });
}

export function setStreamer(ctx: Ctx, streamer_: Address): void {
  const streamer = addr(streamer_);
  onlyGovernorOrBootstrap(ctx);
  ctx.world.treasury.streamer = streamer;
  emit(ctx, ctx.world.addresses.treasury, CONTRACT, "StreamerUpdated", { streamer });
}

export function setSpender(ctx: Ctx, spender_: Address): void {
  const spender = addr(spender_);
  onlyGovernorOrBootstrap(ctx);
  if (spender === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  ctx.world.treasury.spender = spender;
  emit(ctx, ctx.world.addresses.treasury, CONTRACT, "SpenderUpdated", { spender });
}

export function deposit(ctx: Ctx, amount: bigint): void {
  const self = ctx.world.addresses.treasury;
  requireToken(ctx);
  token.transferFrom(asSender(ctx, self), ctx.sender, self, amount);
  emit(ctx, self, CONTRACT, "Deposited", { from: ctx.sender, amount });
}

export function streamAllowance(ctx: Ctx, node_: Address, amount: bigint, epoch: bigint): void {
  const state = ctx.world.treasury;
  const node = addr(node_);
  if (state.governor !== ZERO_ADDRESS || state.streamer !== ZERO_ADDRESS) {
    if (ctx.sender !== state.governor && ctx.sender !== state.streamer) {
      throw new SimRevert("NotAuthorized", { caller: ctx.sender });
    }
  } else if (ctx.sender !== state.deployer) {
    throw new SimRevert("NotAuthorized", { caller: ctx.sender });
  }
  if (node === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  const liquid = liquidBalance(ctx);
  if (liquid < amount) {
    throw new SimRevert("InsufficientTreasury", { requested: amount, available: liquid });
  }

  bindGeneration(ctx, node);
  state.allowanceBalance[node] = (state.allowanceBalance[node] ?? 0n) + amount;
  state.totalReserved += amount;
  emit(ctx, ctx.world.addresses.treasury, CONTRACT, "AllowanceStreamed", { node, amount, epoch });
}

/**
 * Both `spendAllowance` overloads: with `to`, tokens go to that recipient
 * (and a zero recipient is refused); without it, they go to the spender.
 */
export function spendAllowance(ctx: Ctx, node: Address, amount: bigint, to?: Address): void {
  const state = ctx.world.treasury;
  if (ctx.sender !== state.spender) throw new SimRevert("NotSpender", { caller: ctx.sender });
  if (to === undefined) {
    spend(ctx, addr(node), amount, ctx.sender);
    return;
  }
  if (addr(to) === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  spend(ctx, addr(node), amount, addr(to));
}

/**
 * Pull settlement, second half: the spender returns what the target did not
 * pull (transferFrom the spender) and `node` gets that much allowance back.
 */
export function refundAllowance(ctx: Ctx, node_: Address, amount: bigint): void {
  const state = ctx.world.treasury;
  const self = ctx.world.addresses.treasury;
  if (ctx.sender !== state.spender) throw new SimRevert("NotSpender", { caller: ctx.sender });
  const node = addr(node_);
  if (node === ZERO_ADDRESS) throw new SimRevert("ZeroAddress");
  requireToken(ctx);
  token.transferFrom(asSender(ctx, self), ctx.sender, self, amount);
  bindGeneration(ctx, node);
  state.allowanceBalance[node] = (state.allowanceBalance[node] ?? 0n) + amount;
  state.totalReserved += amount;
  emit(ctx, self, CONTRACT, "AllowanceRefunded", { node, amount });
}

/**
 * Return `amount` of `node`'s allowance to the liquid balance. Governor only;
 * the deployer while no governor is bound. Emptying it clears its generation.
 */
export function revokeAllowance(ctx: Ctx, node_: Address, amount: bigint): void {
  const state = ctx.world.treasury;
  const node = addr(node_);
  onlyGovernorOrBootstrap(ctx);
  const available = state.allowanceBalance[node] ?? 0n;
  if (available < amount) {
    throw new SimRevert("InsufficientAllowance", { node, requested: amount, available });
  }
  state.allowanceBalance[node] = available - amount;
  state.totalReserved -= amount;
  if (available === amount) delete state.allowanceGeneration?.[node];
  emit(ctx, ctx.world.addresses.treasury, CONTRACT, "AllowanceRevoked", { node, amount });
}

/** `allowanceGeneration(node)`. */
export function allowanceGeneration(ctx: Ctx, node: Address): bigint {
  return ctx.world.treasury.allowanceGeneration?.[addr(node)] ?? 0n;
}

/**
 * An empty allowance starts under the node's current incarnation; a non-empty
 * one must already belong to it.
 */
function bindGeneration(ctx: Ctx, node: Address): void {
  const state = ctx.world.treasury;
  const current = registryGeneration(ctx, node);
  if ((state.allowanceBalance[node] ?? 0n) === 0n) {
    (state.allowanceGeneration ??= {})[node] = current;
  } else if (allowanceGeneration(ctx, node) !== current) {
    throw new SimRevert("StaleAllowance", { node });
  }
}

/** `IOrgRegistry(orgRegistry).generationOf`: only the simulated registry has code. */
function registryGeneration(ctx: Ctx, node: Address): bigint {
  if (ctx.world.treasury.orgRegistry !== ctx.world.addresses.orgRegistry) {
    throw new SimRevert(EVM_REVERT);
  }
  return orgRegistry.generationOf(ctx, node);
}

/** How far the balance has fallen below what is reserved. */
export function shortfall(ctx: Ctx): bigint {
  requireToken(ctx);
  const bal = token.balanceOf(ctx, ctx.world.addresses.treasury);
  const reserved = ctx.world.treasury.totalReserved;
  return reserved > bal ? reserved - bal : 0n;
}

export function liquidBalance(ctx: Ctx): bigint {
  requireToken(ctx);
  const bal = token.balanceOf(ctx, ctx.world.addresses.treasury);
  const reserved = ctx.world.treasury.totalReserved;
  return bal > reserved ? bal - reserved : 0n;
}

/** Governor once bound; the deployer until then. */
function onlyGovernorOrBootstrap(ctx: Ctx): void {
  const state = ctx.world.treasury;
  const authority = state.governor === ZERO_ADDRESS ? state.deployer : state.governor;
  if (ctx.sender !== authority) throw new SimRevert("NotAuthorized", { caller: ctx.sender });
}

function spend(ctx: Ctx, node: Address, amount: bigint, to: Address): void {
  const state = ctx.world.treasury;
  const self = ctx.world.addresses.treasury;
  const available = state.allowanceBalance[node] ?? 0n;
  if (available < amount) {
    throw new SimRevert("InsufficientAllowance", { node, requested: amount, available });
  }
  if (allowanceGeneration(ctx, node) !== registryGeneration(ctx, node)) {
    throw new SimRevert("StaleAllowance", { node });
  }
  state.allowanceBalance[node] = available - amount;
  state.totalReserved -= amount;
  requireToken(ctx);
  token.transfer(asSender(ctx, self), to, amount);
  emit(ctx, self, CONTRACT, "AllowanceSpent", { node, amount, to });
}

/** The token is an immutable address; anything but the simulated token has no code to call. */
function requireToken(ctx: Ctx): void {
  if (ctx.world.treasury.token !== ctx.world.addresses.token) throw new SimRevert(EVM_REVERT);
}
