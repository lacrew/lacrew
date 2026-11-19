/**
 * Bind the MCP tools to the live CrewRuntime so tool calls share the same
 * client, session, and audit trail as the rest of the orchestrator
 * (session-signed onchain proposes when the runtime is onchain).
 */

import type { McpToolBackend } from "@lacrew/adapter-agents-mcp";
import type { SessionScope } from "@lacrew/core";
import { scopeOfThread, type Message } from "./conversation.js";
import type { CrewRuntime } from "./runtime.js";

/**
 * `principal` is the agent a flow run acts as and `ceiling` the flow's scope
 * cap; both are bound per run so tool calls inherit the run's identity rather
 * than the process-wide worker.
 */
export function createRuntimeMcpBackend(
  runtime: CrewRuntime,
  actor: {
    principal?: `0x${string}`;
    ceiling?: `0x${string}`;
    window?: { start: number; end: number };
    rate?: { maxProposals: number; ratePeriod: number };
    scopes?: SessionScope[];
  } = {},
): McpToolBackend {
  return {
    getOrgTree: () => runtime.getClient().getOrgTree(),
    /*
      An approver reads the queue as structured records — decoded call,
      simulation, aggregates — with the requester's own words fenced off as
      untrusted. See `approverView.ts` for why.
    */
    listPendingIntents: () => runtime.approverQueue(actor.principal),
    proposeIntent: async (input) => {
      const { intentId, verdict, txHash, simTxId } = await runtime.propose({
        ...input,
        ceiling: actor.ceiling,
        window: actor.window,
        rate: actor.rate,
        scopes: actor.scopes,
      });
      // A sandbox propose is named by a `simTxId` and never by a `txHash`.
      return { intentId, verdict, txHash, ...(simTxId ? { simTxId } : {}) };
    },
    /*
      An agent settling an intent the human root must settle (one that climbed
      there, or one whose approver is inactive so the root stands in) would be
      the agent approving its own escalation — the tree's top step answered by
      the thing it exists to hold. A tool call carries no root proof and never
      can, so root-depth intents are refused here rather than attempted: on a
      deployment that happens to hold the root key the chain would let it
      through, and the receipt would name the root.
    */
    resolveIntent: async (intentId, approved) => {
      const authority = await runtime.approvalAuthority(intentId);
      if (!authority.found) throw new Error(`intent_not_pending: ${intentId}`);
      if (authority.isRoot) {
        throw new Error(
          `root_approval_required: intent ${intentId} awaits the human root, who must approve it directly`,
        );
      }
      const resolved = await runtime.resolve(
        intentId,
        approved,
        authority.resolver ?? undefined,
        "approver",
      );
      const { intent, escalated, txHash } = resolved;
      const simTxId = "simTxId" in resolved ? resolved.simTxId : undefined;
      return {
        intent: { ...intent, value: intent.value.toString() },
        escalated,
        txHash,
        ...(simTxId ? { simTxId } : {}),
      };
    },
    checkPolicy: (input) => runtime.checkEffectivePolicy({ ...input, ceiling: actor.ceiling }),
    orgAction: (input) => runtime.orgAction({ ...input, ...actor }),
    setBudget: (input) => runtime.setBudget({ ...input, ...actor }),
    governance: (input) => runtime.governanceAction(input),
    /*
      Conversation (F1.7). The author is the run's principal, never something
      the agent supplies: an agent able to name its own author could post as a
      peer, or as a human, and the thread's attribution is the only thing
      making it worth reading.
    */
    postMessage: async (input) => {
      const scope = scopeOfThread(input.thread);
      if (!scope) throw new Error(`unknown_thread: ${input.thread}`);
      return runtime.postMessage({
        scope,
        author: actor.principal ?? runtime.workerAddress,
        authorKind: "agent",
        kind: input.kind,
        body: input.body,
        options: input.options,
        to: input.to,
        blocks: input.blocks,
        refs: (input.refs ?? []).map((r) => ({
          kind: r.kind as "intent" | "proposal" | "tx" | "flowRun",
          id: r.id,
        })),
      });
    },
    readThread: async (input) => {
      const scope = scopeOfThread(input.thread);
      if (!scope) throw new Error(`unknown_thread: ${input.thread}`);
      // Another participant's message is their claim, and a reader deciding
      // anything (an approval above all) must see it as such. A seat whose
      // approver narrative is `off` gets other agents' bodies withheld too:
      // otherwise the requester's words, kept out of the approval queue,
      // would reach the seat through its thread — or through a flow step that
      // interpolates this read into the approver's prompt.
      const reader = (actor.principal ?? runtime.workerAddress).toLowerCase();
      const withhold = runtime.approverNarrativeFor(reader) === "off";
      const view = (m: Message) => {
        if (m.author.toLowerCase() === reader) return m;
        if (withhold && m.authorKind === "agent") return withheldMessage(m);
        return { ...m, untrusted: true as const };
      };
      return {
        thread: input.thread,
        messages: runtime.thread(scope, input.limit ?? 50).map(view),
        openQuestions: runtime.openQuestions(scope).map(view),
        ...(withhold ? { withheld: "agent_bodies" as const } : {}),
      };
    },
    // invokeAgent is layered on in createFlowsSurface: delegation runs a flow,
    // which only the flows surface can do.
  };
}

/**
 * A message with everything its author wrote removed: who, when, what kind,
 * and what it points at stay, so the reader can see that something was said
 * and look it up, but no sentence of it reaches the reader's model.
 */
export function withheldMessage(m: Message): Omit<Message, "body"> & {
  body: "";
  untrusted: true;
  withheld: true;
} {
  return {
    id: m.id,
    threadId: m.threadId,
    at: m.at,
    author: m.author,
    authorKind: m.authorKind,
    kind: m.kind,
    body: "",
    ...(m.replyTo ? { replyTo: m.replyTo } : {}),
    ...(m.to ? { to: m.to } : {}),
    ...(m.refs?.length ? { refs: m.refs } : {}),
    untrusted: true,
    withheld: true,
  };
}
