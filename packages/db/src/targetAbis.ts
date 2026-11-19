/** Query helpers for operator-registered target ABIs (keeps Drizzle inside @lacrew/db). */

import { and, eq } from "drizzle-orm";
import { targetAbis } from "./schema/targetAbis.js";
import type { OrgDb } from "./client.js";

export interface TargetAbiRow {
  target: string;
  name: string;
  abi: unknown[];
  updatedAt: string;
}

export async function upsertTargetAbi(handle: OrgDb, row: TargetAbiRow): Promise<void> {
  const values = {
    target: row.target,
    name: row.name,
    abi: row.abi,
    updatedAt: new Date(row.updatedAt),
  };
  await handle.db
    .insert(targetAbis)
    .values({ orgId: handle.orgId, ...values })
    .onConflictDoUpdate({ target: [targetAbis.orgId, targetAbis.target], set: values });
}

export async function deleteTargetAbi(handle: OrgDb, target: string): Promise<void> {
  await handle.db
    .delete(targetAbis)
    .where(and(eq(targetAbis.orgId, handle.orgId), eq(targetAbis.target, target)));
}

/** Every registered ABI; one row per target an operator described. */
export async function listTargetAbis(handle: OrgDb): Promise<TargetAbiRow[]> {
  const rows = await handle.db.select().from(targetAbis).where(eq(targetAbis.orgId, handle.orgId));
  return rows.map((row) => ({
    target: row.target,
    name: row.name,
    abi: row.abi ?? [],
    updatedAt: row.updatedAt.toISOString(),
  }));
}
