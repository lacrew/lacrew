/**
 * ABIs an operator registered for spend targets (PRD F2.6).
 *
 * The approver view decodes an intent's calldata so a request described as one
 * thing cannot quietly be another. ERC-20, the protocol contracts and a set of
 * well-known DEX / token contracts are decoded out of the box; this registry is
 * for the rest — a vault, a bespoke router, any whitelisted contract.
 *
 * An entry is keyed by target address, and a decode through it is reported as
 * matched by `target`. That is a stronger statement than a selector match
 * against a well-known ABI: four bytes say which function signature the
 * calldata names, not that the contract at that address is the one the
 * signature belongs to. An operator registering an ABI for an address is
 * vouching for that address.
 *
 * Writes go to memory first and the store after, like agent controls: a store
 * that is down degrades to an in-process registry rather than refusing the
 * write, and decoding is advisory — the chain still enforces every cap.
 */

import { toFunctionSelector, type Abi, type AbiFunction } from "viem";

export type TargetAbiRecord = {
  /** Lowercased target address. */
  target: `0x${string}`;
  name: string;
  /** Function fragments only; everything else is dropped at registration. */
  abi: AbiFunction[];
  updatedAt: string;
};

export interface TargetAbiStore {
  loadTargetAbis(): Promise<TargetAbiRecord[]>;
  saveTargetAbi(record: TargetAbiRecord): Promise<void>;
  removeTargetAbi(target: string): Promise<void>;
}

/** Sized for a contract's interface, not for a payload. */
export const TARGET_ABI_MAX_FUNCTIONS = 200;
export const TARGET_ABI_NAME_MAX = 80;

export class TargetAbiError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "TargetAbiError";
  }
}

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;

/**
 * Check and normalize an untrusted ABI body: an array of JSON ABI items, of
 * which only well-formed `function` fragments are kept. Refuses rather than
 * strips when nothing usable is left — an entry that decodes nothing would
 * read as "registered" while every call still showed `unknown`.
 */
export function normalizeTargetAbi(input: { target?: unknown; name?: unknown; abi?: unknown }): {
  target: `0x${string}`;
  name: string;
  abi: AbiFunction[];
} {
  const target = String(input.target ?? "");
  if (!ADDRESS.test(target)) throw new TargetAbiError("invalid_target");
  const name = String(input.name ?? "").trim();
  if (!name) throw new TargetAbiError("name_required");
  if (name.length > TARGET_ABI_NAME_MAX) throw new TargetAbiError("name_too_long");
  let raw = input.abi;
  if (typeof raw === "string") {
    try {
      raw = JSON.parse(raw);
    } catch {
      throw new TargetAbiError("abi_not_json");
    }
  }
  if (!Array.isArray(raw)) throw new TargetAbiError("abi_must_be_array");
  const functions: AbiFunction[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const fragment = item as Partial<AbiFunction>;
    if (fragment.type !== "function" || typeof fragment.name !== "string") continue;
    if (!Array.isArray(fragment.inputs)) continue;
    const fn = {
      type: "function",
      name: fragment.name,
      inputs: fragment.inputs,
      outputs: Array.isArray(fragment.outputs) ? fragment.outputs : [],
      stateMutability: fragment.stateMutability ?? "nonpayable",
    } as AbiFunction;
    try {
      // A fragment viem cannot compute a selector for cannot decode anything.
      toFunctionSelector(fn);
    } catch {
      throw new TargetAbiError(`invalid_function:${fragment.name}`);
    }
    functions.push(fn);
  }
  if (functions.length === 0) throw new TargetAbiError("abi_has_no_functions");
  if (functions.length > TARGET_ABI_MAX_FUNCTIONS) throw new TargetAbiError("abi_too_large");
  return { target: target.toLowerCase() as `0x${string}`, name, abi: functions };
}

export class TargetAbis {
  private readonly entries = new Map<string, TargetAbiRecord>();
  private store?: TargetAbiStore;
  hydrated = false;

  constructor(store?: TargetAbiStore) {
    this.store = store;
  }

  async hydrate(store = this.store): Promise<{ ok: boolean; loaded: number }> {
    if (!store) return { ok: false, loaded: 0 };
    this.store = store;
    try {
      const records = await store.loadTargetAbis();
      for (const record of records) this.entries.set(record.target.toLowerCase(), record);
      this.hydrated = true;
      return { ok: true, loaded: records.length };
    } catch {
      return { ok: false, loaded: 0 };
    }
  }

  set(
    input: { target?: unknown; name?: unknown; abi?: unknown },
    at = new Date().toISOString(),
  ): TargetAbiRecord {
    const normalized = normalizeTargetAbi(input);
    const record: TargetAbiRecord = { ...normalized, updatedAt: at };
    this.entries.set(record.target, record);
    void this.store?.saveTargetAbi(record).catch(() => {});
    return record;
  }

  remove(target: string): boolean {
    const key = target.toLowerCase();
    const had = this.entries.delete(key);
    if (had) void this.store?.removeTargetAbi(key).catch(() => {});
    return had;
  }

  forTarget(target: string): { name: string; abi: Abi } | null {
    const record = this.entries.get(target.toLowerCase());
    return record ? { name: record.name, abi: record.abi as Abi } : null;
  }

  list(): TargetAbiRecord[] {
    return [...this.entries.values()];
  }
}
