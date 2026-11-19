import { jsonb, pgTable, primaryKey, text, timestamp } from "drizzle-orm/pg-core";

/**
 * Operator-registered ABIs for spend targets (PRD F2.6).
 *
 * An AI approver is shown an intent's calldata decoded, so a request described
 * as one thing cannot quietly be another. The protocol and well-known ABIs
 * cover the common cases; this table covers the rest — a DEX router, a vault,
 * any whitelisted contract — keyed by the target, because an ABI an operator
 * vouched for is a statement about one address, not about every contract that
 * happens to share a selector.
 */
export const targetAbis = pgTable(
  "orchestrator_target_abis",
  {
    /** The org this row belongs to. Every read and write is scoped by it. */
    orgId: text("org_id").notNull().default("default"),
    /** Lowercased target address. */
    target: text("target").notNull(),
    /** A name for the contract, shown beside the decoded call. */
    name: text("name").notNull(),
    /** The function fragments, as JSON ABI items. */
    abi: jsonb("abi").notNull().$type<unknown[]>(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (table) => [primaryKey({ columns: [table.orgId, table.target] })],
);
