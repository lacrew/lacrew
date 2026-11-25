import type { Scenario } from "../scenario.js";
import { fanOutScenarios } from "./fanOut.js";
import { governanceScenarios } from "./governance.js";
import { lifecycleScenarios } from "./lifecycle.js";
import { policyScenarios } from "./policies.js";
import { registryScenarios } from "./registry.js";
import { rootRotationScenarios } from "./rootRotation.js";
import { sessionScenarios } from "./sessions.js";
import { spendScenarios } from "./spend.js";
import { treasuryScenarios } from "./treasury.js";

/** Every scenario, in the order the suite runs them. */
export const SCENARIOS: Scenario[] = [
  ...spendScenarios,
  ...sessionScenarios,
  ...policyScenarios,
  ...treasuryScenarios,
  ...registryScenarios,
  ...fanOutScenarios,
  ...governanceScenarios,
  ...rootRotationScenarios,
  ...lifecycleScenarios,
];
