/**
 * Root key rotation: the root of the tree, of session issuance and of the
 * governance seat is a key that can be replaced, by itself before governance
 * is bound and only by a High-tier proposal after.
 */

import { HIGH, KIND, LOW, SEAT, governed, scenario, type Scenario } from "../scenario.js";

const ROOTED = ["@registry", "@sessions"];

export const rootRotationScenarios: Scenario[] = [
  scenario("root rotation by key, before governance is bound", (b) => {
    b.call("root", "@registry", "addNode", ["manager", KIND.manager, "root"]);
    b.call("root", "@registry", "addNode", ["worker", KIND.worker, "manager"]);
    b.call("root", "@registry", "addNode", ["human2", KIND.human, "root"]);

    b.reverts("NotAuthorized", "stranger", "@registry", "rotateRoot", ["stranger"]);
    b.reverts("ZeroAddress", "root", "@registry", "rotateRoot", ["zero"]);
    // Only a fresh key or a peer human seated under the root can take the top.
    b.reverts("InvalidRoot", "root", "@registry", "rotateRoot", ["manager"]);
    b.reverts("InvalidRoot", "root", "@registry", "rotateRoot", ["worker"]);

    // Promoting the partner: the old root's node goes, its reports follow.
    b.call("root", "@registry", "rotateRoot", ["human2"], {
      events: ["NodeReparented", "NodeReparented", "NodeRemoved", "RootRotated"],
    });
    b.expect({
      tree: ["human2", "manager", "worker"],
      nodes: {
        root: null,
        human2: { parent: null, kind: "human_root", active: true },
        manager: { parent: "human2" },
      },
    });
    b.reverts("NotAuthorized", "root", "@registry", "addNode", ["stranger", KIND.worker, "human2"]);
    b.call("human2", "@registry", "addNode", ["worker2", KIND.worker, "manager"]);

    // Session issuance: an issuer still set to the old root follows the rotation.
    b.reverts("NotAuthorized", "stranger", "@sessions", "rotateRoot", ["stranger"]);
    b.reverts("NotAuthorized", "stranger", "@sessions", "setGovernor", ["stranger"]);
    b.reverts("ZeroAddress", "root", "@sessions", "rotateRoot", ["zero"]);
    b.call("root", "@sessions", "rotateRoot", ["human2"], {
      events: ["RootRotated", "IssuerUpdated"],
    });
    b.sessionReverts("NotAuthorized", { from: "root" });
    const id = b.session({ from: "human2" });
    b.expect({ keys: [{ agent: "worker", key: "key", valid: true }] });

    // A bound governor can replace the issuer and revoke without the root.
    b.reverts("ZeroAddress", "human2", "@sessions", "setGovernor", ["zero"]);
    b.call("human2", "@sessions", "setGovernor", ["stranger"], { events: ["GovernorUpdated"] });
    b.reverts("NotAuthorized", "human2", "@sessions", "setGovernor", ["human2"]);
    b.reverts("NotAuthorized", "human2", "@sessions", "rotateRoot", ["root"]);
    b.call("stranger", "@sessions", "setIssuer", ["issuer"], { events: ["IssuerUpdated"] });
    b.call("stranger", "@sessions", "revoke", [BigInt(id)], { events: ["SessionRevoked"] });
    b.expect({ keys: [{ agent: "worker", key: "key", valid: false }] });
  }),

  governed("a compromised root is rotated by a High-tier proposal", (b) => {
    b.pass({ to: "@registry", fn: "addNode", args: ["manager", KIND.manager, "root"] });
    // A HumanRoot seat is never low tier: the router would take it as a final approver.
    b.pass({ to: "@registry", fn: "addNode", args: ["human2", KIND.human, "root"] }, HIGH);
    b.pass({ to: "@registry", fn: "addNode", args: ["worker", KIND.worker, "manager"] });
    b.pass({ to: "@gov", fn: "admitHuman", args: ["human2", 2n] }, HIGH);
    const sessionId = b.session();

    // No key and no low-tier vote reaches the root or the issuer.
    b.reverts("RootAuthorityNotHighTier", "root", "@gov", "propose", [
      LOW,
      "@registry",
      { call: { to: "@registry", fn: "rotateRoot", args: ["stranger"] } },
    ]);
    b.reverts("RootAuthorityNotHighTier", "root", "@gov", "propose", [
      LOW,
      "@sessions",
      { call: { to: "@sessions", fn: "setIssuer", args: ["stranger"] } },
    ]);
    b.reverts("NotGovernance", "root", "@gov", "rotateRoot", ["stranger", ROOTED]);
    b.reverts("NotAuthorized", "root", "@registry", "rotateRoot", ["stranger"]);
    b.reverts("NotAuthorized", "root", "@sessions", "rotateRoot", ["stranger"]);

    // One proposal moves every root and the seat together.
    b.pass({ to: "@gov", fn: "rotateRoot", args: ["human2", ROOTED] }, HIGH, ["root", "human2"]);
    b.expect({
      tree: ["human2", "manager", "worker"],
      nodes: {
        root: null,
        human2: { parent: null },
        manager: { parent: "human2" },
        worker: { parent: "manager" },
      },
      seats: {
        human2: { power: 2n, role: "human" },
        root: { power: 0n, role: "none" },
      },
      governance: { humanSeatCount: 1n },
    });

    // The retired key is a stranger everywhere; the new root holds what it held.
    b.reverts("NotHumanRoot", "root", "@gov", "setQuorumYes", [3n]);
    b.reverts("NotHumanSeat", "root", "@gov", "veto", [1n]);
    b.sessionReverts("NotAuthorized", { from: "root" });
    b.call("human2", "@gov", "setQuorumYes", [2n]);

    // Governance acts on issuance without any root signature.
    // The retired root is no longer seated, so the new root proposes. Revoking a
    // session is not allow-listed, so both steps are High tier.
    b.pass({ to: "@sessions", fn: "setIssuer", args: ["issuer"] }, HIGH, ["human2"], "human2");
    b.pass(
      { to: "@sessions", fn: "revoke", args: [BigInt(sessionId)] },
      HIGH,
      ["human2"],
      "human2",
    );
    b.expect({ keys: [{ agent: "worker", key: "key", valid: false }] });
    b.session({ from: "issuer", key: "key2" });
    b.expect({ keys: [{ agent: "worker", key: "key2", valid: true }] });
  }),

  governed(
    "an unseated org's root rotates itself",
    (b) => {
      b.call("root", "@gov", "setVotingPower", ["manager", 1n, SEAT.agent]);
      // A root is a human: an agent seat cannot take it.
      b.reverts("RootIsAgentSeat", "root", "@gov", "rotateRoot", ["manager", []]);
      b.reverts("ZeroAddress", "root", "@gov", "rotateRoot", ["zero", []]);
      b.call("root", "@gov", "rotateRoot", ["human2", ROOTED], {
        events: [
          "RootRotated",
          "NodeAdded",
          "NodeRemoved",
          "RootRotated",
          "RootRotated",
          "IssuerUpdated",
        ],
      });
      b.expect({
        tree: ["human2"],
        nodes: { root: null, human2: { parent: null, kind: "human_root" } },
        governance: { humanSeatCount: 0n },
      });
      b.reverts("NotGovernance", "root", "@gov", "rotateRoot", ["root", []]);
      // A contract that cannot rotate reverts the whole rotation.
      b.reverts("EvmRevert", "human2", "@gov", "rotateRoot", ["stranger", ["@treasury"]]);
      b.expect({ nodes: { human2: { parent: null } } });
    },
    { rootPower: 0n },
  ),
];
