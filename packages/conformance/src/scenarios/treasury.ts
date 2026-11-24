/**
 * Money in and out: the epoch streamer, the treasury's own authority, and the
 * token it holds.
 */

import { KIND, MAX_UINT256, USDC, scenario, type Scenario } from "../scenario.js";

export const treasuryScenarios: Scenario[] = [
  scenario("epochs stream grants, and an unspent allowance carries over", (b) => {
    b.call("root", "@registry", "addNode", ["manager", KIND.manager, "root"]);
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "manager"]);
    b.call("root", "@whitelist", "setAllowed", ["target", true]);
    b.fund(1_000n * USDC);
    b.reverts("EmptySchedule", "root", "@streamer", "runNextEpoch");

    b.call("root", "@streamer", "setGrant", ["worker", 200n * USDC], { events: ["GrantUpdated"] });
    b.call("root", "@streamer", "setGrant", ["manager", 50n * USDC]);
    b.call("root", "@streamer", "runNextEpoch", [], {
      events: ["AllowanceStreamed", "AllowanceStreamed", "EpochRun"],
    });
    b.expect({
      epoch: 1,
      allowance: { worker: 200n * USDC, manager: 50n * USDC },
      grants: { worker: 200n * USDC, manager: 50n * USDC },
      treasury: { total: 1_000n * USDC, reserved: 250n * USDC, liquid: 750n * USDC },
    });

    b.allow("worker", "worker", "target", 30n * USDC);
    b.call("root", "@streamer", "runNextEpoch");
    b.expect(
      {
        epoch: 2,
        allowance: { worker: 370n * USDC, manager: 100n * USDC },
        treasury: { total: 970n * USDC, reserved: 470n * USDC, liquid: 500n * USDC },
      },
      "what the worker did not spend is still its own",
    );

    b.call("root", "@streamer", "runNextEpoch");
    b.call("root", "@streamer", "runNextEpoch");
    b.expect({
      epoch: 4,
      allowance: { worker: 770n * USDC, manager: 200n * USDC },
      treasury: { reserved: 970n * USDC, liquid: 0n },
    });

    // One grant the treasury cannot cover refuses the whole epoch.
    b.reverts("InsufficientTreasury", "root", "@streamer", "runNextEpoch", [], "Treasury");
    b.expect({ epoch: 4, allowance: { worker: 770n * USDC } });
  }),

  scenario(
    "epochs unlock one at a time on the clock, never ahead of it",
    (b) => {
      b.call("root", "@registry", "addNode", ["worker", KIND.worker, "root"]);
      b.fund(1_000n * USDC);
      b.call("root", "@streamer", "setGrant", ["worker", 10n * USDC]);
      b.reverts("EpochNotReady", "root", "@streamer", "runNextEpoch");
      b.expect({ epoch: 0 });
      b.warp(1_250);
      b.call("root", "@streamer", "runNextEpoch");
      b.expect({ epoch: 1, allowance: { worker: 10n * USDC } });
      // The next epoch unlocks a full period after the last, however fast it is asked for.
      b.reverts("EpochNotReady", "root", "@streamer", "runNextEpoch");
      b.warp(1_000);
      b.call("root", "@streamer", "runNextEpoch");
      b.expect({ epoch: 2, allowance: { worker: 20n * USDC } });
      // Time passing does not run epochs by itself: a backlog is drained one call at a time.
      b.warp(2_000);
      b.call("root", "@streamer", "runNextEpoch");
      b.call("root", "@streamer", "runNextEpoch");
      b.reverts("EpochNotReady", "root", "@streamer", "runNextEpoch");
      b.expect({ epoch: 4, allowance: { worker: 40n * USDC } });
    },
    // Periods far wider than the few seconds the deployment itself takes on a chain.
    { epoch: { startOffset: 2_000n, duration: 1_000n } },
  ),

  scenario("the grant schedule and the streamer's own authority", (b) => {
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "root"]);
    b.reverts("NotAuthorized", "stranger", "@streamer", "setGrant", ["worker", 1n]);
    b.reverts("NotAuthorized", "stranger", "@streamer", "setGrants", [["worker"], [1n]]);
    b.reverts("ZeroAddress", "root", "@streamer", "setGrant", ["zero", 1n]);
    b.reverts("LengthMismatch", "root", "@streamer", "setGrants", [["worker", "manager"], [1n]]);

    b.call("root", "@streamer", "setGrant", ["worker", 5n]);
    b.call("root", "@streamer", "setGrants", [
      ["worker", "manager", "worker2"],
      [0n, 10n, 20n],
    ]);
    b.expect({ grants: { manager: 10n, worker2: 20n } });
    // Clearing a node that holds no grant is accepted and changes nothing.
    b.call("root", "@streamer", "setGrant", ["worker", 0n], { events: ["GrantUpdated"] });
    b.reverts("ZeroAddress", "root", "@streamer", "setGrants", [
      ["worker", "zero"],
      [1n, 1n],
    ]);
    b.expect({ grants: { manager: 10n, worker2: 20n } });

    for (const fn of ["runNextEpoch"] as const) {
      b.reverts("NotOperator", "stranger", "@streamer", fn);
    }
    b.reverts("NotOperator", "stranger", "@streamer", "setOperator", ["stranger"]);
    b.reverts("NotOperator", "stranger", "@streamer", "setGovernor", ["@gov"]);
    b.reverts("ZeroAddress", "root", "@streamer", "setOperator", ["zero"]);
    b.reverts("ZeroAddress", "root", "@streamer", "setGovernor", ["zero"]);
    b.call("root", "@streamer", "setGovernor", ["human2"]);
    b.reverts("GovernorAlreadySet", "root", "@streamer", "setGovernor", ["@gov"]);

    b.call("root", "@streamer", "setOperator", ["operator2"], { events: ["OperatorUpdated"] });
    b.reverts("NotOperator", "root", "@streamer", "runNextEpoch");
    b.reverts("NotAuthorized", "root", "@streamer", "setGrant", ["worker", 1n]);
    // The governor sets grants; running epochs stays with the operator.
    b.call("human2", "@streamer", "setGrant", ["worker", 3n]);
    b.reverts("NotOperator", "human2", "@streamer", "runNextEpoch");
    b.expect({ grants: { manager: 10n, worker2: 20n, worker: 3n } });
  }),

  scenario("the treasury's authority and both ways it pays out", (b) => {
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "root"]);
    b.call("root", "@token", "mint", ["root", 100n * USDC]);
    b.reverts(
      "ERC20InsufficientAllowance",
      "root",
      "@treasury",
      "deposit",
      [100n * USDC],
      "MockUSDC",
    );
    b.call("root", "@token", "approve", ["@treasury", 500n * USDC]);
    b.reverts(
      "ERC20InsufficientBalance",
      "root",
      "@treasury",
      "deposit",
      [500n * USDC],
      "MockUSDC",
    );
    b.call("root", "@treasury", "deposit", [100n * USDC], { events: ["Transfer", "Deposited"] });

    // With a streamer bound, not even the deployer streams by hand.
    b.reverts("NotAuthorized", "root", "@treasury", "streamAllowance", ["worker", 1n, 1n]);
    b.reverts("NotAuthorized", "stranger", "@treasury", "streamAllowance", ["worker", 1n, 1n]);
    for (const fn of ["setSpender", "setStreamer", "setGovernor"]) {
      b.reverts("NotAuthorized", "stranger", "@treasury", fn, ["stranger"]);
    }
    b.reverts("ZeroAddress", "root", "@treasury", "setSpender", ["zero"]);
    // setGovernor rejects a zero governor before it asks who is calling.
    b.reverts("ZeroAddress", "stranger", "@treasury", "setGovernor", ["zero"]);

    // Unbinding the streamer returns the bootstrap authority to the deployer.
    b.call("root", "@treasury", "setStreamer", ["zero"], { events: ["StreamerUpdated"] });
    b.call("root", "@treasury", "streamAllowance", ["worker", 60n * USDC, 7n], {
      events: ["AllowanceStreamed"],
    });
    // Nothing is booked to the zero address: it could never be spent.
    b.reverts("ZeroAddress", "root", "@treasury", "streamAllowance", ["zero", 1n, 8n]);
    b.reverts("InsufficientTreasury", "root", "@treasury", "streamAllowance", [
      "worker",
      41n * USDC,
      8n,
    ]);

    b.reverts("NotSpender", "stranger", "@treasury", "spendAllowance", ["worker", 1n, "target"]);
    b.reverts("NotSpender", "stranger", "@treasury", "spendAllowance", ["worker", 1n]);
    b.call("root", "@treasury", "setSpender", ["root"], { events: ["SpenderUpdated"] });
    b.reverts("ZeroAddress", "root", "@treasury", "spendAllowance", ["worker", 1n, "zero"]);
    b.reverts("InsufficientAllowance", "root", "@treasury", "spendAllowance", [
      "worker",
      61n * USDC,
      "target",
    ]);
    b.call("root", "@treasury", "spendAllowance", ["worker", 10n * USDC, "target"], {
      events: ["Transfer", "AllowanceSpent"],
    });
    // Without a recipient, the spender itself is paid.
    b.call("root", "@treasury", "spendAllowance", ["worker", 5n * USDC]);

    // A refund is the spender handing unpulled tokens back: only the spender may,
    // the tokens must actually arrive, and the allowance is restored by that much.
    b.reverts("NotSpender", "stranger", "@treasury", "refundAllowance", ["worker", 1n]);
    b.reverts("ZeroAddress", "root", "@treasury", "refundAllowance", ["zero", 1n]);
    b.call("root", "@token", "approve", ["@treasury", 0n]);
    b.reverts(
      "ERC20InsufficientAllowance",
      "root",
      "@treasury",
      "refundAllowance",
      ["worker", 3n * USDC],
      "MockUSDC",
    );
    b.call("root", "@token", "approve", ["@treasury", 3n * USDC]);
    b.call("root", "@treasury", "refundAllowance", ["worker", 3n * USDC], {
      events: ["Transfer", "AllowanceRefunded"],
    });
    b.expect({
      allowance: { worker: 48n * USDC },
      balance: { target: 10n * USDC, root: 2n * USDC },
      treasury: { total: 88n * USDC, reserved: 48n * USDC, liquid: 40n * USDC },
    });

    b.call("root", "@treasury", "setGovernor", ["human2"], { events: ["GovernorUpdated"] });
    b.reverts("NotAuthorized", "root", "@treasury", "setSpender", ["stranger"]);
    b.call("human2", "@treasury", "setSpender", ["@router"]);
    b.call("human2", "@treasury", "streamAllowance", ["worker", 1n, 9n]);
  }),

  scenario("the spend token: minting, transfers and allowances", (b) => {
    b.reverts("NotMinter", "stranger", "@token", "mint", ["stranger", 1n]);
    b.reverts("NotOwner", "stranger", "@token", "setMinter", ["stranger", true]);
    b.call("root", "@token", "setMinter", ["minter", true], { events: ["MinterUpdated"] });
    b.call("minter", "@token", "mint", ["stranger", 100n], { events: ["Transfer"] });
    b.reverts("ERC20InvalidReceiver", "root", "@token", "mint", ["zero", 1n]);
    b.call("root", "@token", "setMinter", ["minter", false]);
    b.reverts("NotMinter", "minter", "@token", "mint", ["stranger", 1n]);

    b.reverts("ERC20InsufficientBalance", "stranger", "@token", "transfer", ["target", 101n]);
    b.reverts("ERC20InvalidReceiver", "stranger", "@token", "transfer", ["zero", 1n]);
    b.call("stranger", "@token", "transfer", ["target", 40n], { events: ["Transfer"] });

    b.reverts("ERC20InvalidSpender", "stranger", "@token", "approve", ["zero", 1n]);
    b.call("stranger", "@token", "approve", ["manager", 50n], { events: ["Approval"] });
    b.reverts("ERC20InsufficientAllowance", "manager", "@token", "transferFrom", [
      "stranger",
      "target2",
      51n,
    ]);
    b.call("manager", "@token", "transferFrom", ["stranger", "target2", 50n], {
      events: ["Transfer"],
    });
    b.reverts("ERC20InsufficientAllowance", "manager", "@token", "transferFrom", [
      "stranger",
      "target2",
      1n,
    ]);
    // An unlimited approval is never drawn down.
    b.call("stranger", "@token", "approve", ["manager", MAX_UINT256]);
    b.call("manager", "@token", "transferFrom", ["stranger", "target2", 4n]);
    b.call("manager", "@token", "transferFrom", ["stranger", "target2", 6n]);
    b.reverts("ERC20InsufficientBalance", "manager", "@token", "transferFrom", [
      "stranger",
      "target2",
      1n,
    ]);
    b.expect({ balance: { stranger: 0n, target: 40n, target2: 60n } });
  }),
];
