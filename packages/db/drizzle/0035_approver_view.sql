CREATE TABLE "orchestrator_target_abis" (
	"org_id" text DEFAULT 'default' NOT NULL,
	"target" text NOT NULL,
	"name" text NOT NULL,
	"abi" jsonb NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "orchestrator_target_abis_org_id_target_pk" PRIMARY KEY("org_id","target")
);
--> statement-breakpoint
ALTER TABLE "orchestrator_agent_controls" ADD COLUMN "approver_narrative" text;