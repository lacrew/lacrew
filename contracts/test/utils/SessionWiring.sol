// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EscalationRouter} from "../../src/EscalationRouter.sol";
import {SessionRegistry} from "../../src/SessionRegistry.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";

/// Routers refuse a caller that is not the agent until a SessionRegistry is wired, so
/// tests that drive `propose` as the test contract wire a real registry and issue the
/// test contract a session for each agent it proposes for.
abstract contract SessionWiring is Test {
    /// @dev Deploys a SessionRegistry owned by `root`, wires it into `router` (the caller
    ///      must be the router's governor or bootstrap deployer) and issues an unlimited,
    ///      all-scope session to `address(this)` for each of `agents`.
    function _wireSessions(
        EscalationRouter router,
        OrgRegistry orgRegistry,
        address root,
        address[] memory agents
    ) internal returns (SessionRegistry sessions) {
        sessions = new SessionRegistry(root, address(orgRegistry));
        router.setSessionRegistry(address(sessions));
        vm.prank(root);
        sessions.setEscalationRouter(address(router));
        _issueTestSessions(sessions, root, agents);
    }

    /// @dev Issuing again for an agent (e.g. after re-adding it) replaces the earlier session.
    function _issueTestSessions(SessionRegistry sessions, address root, address[] memory agents) internal {
        _issueSessionsTo(sessions, root, address(this), agents);
    }

    /// @dev Same, for a `key` other than the test contract (e.g. a fuzz handler that proposes).
    function _issueSessionsTo(SessionRegistry sessions, address root, address key, address[] memory agents)
        internal
    {
        uint256 scopes = sessions.SCOPE_ALL();
        for (uint256 i = 0; i < agents.length; i++) {
            vm.prank(root);
            sessions.issue(agents[i], key, type(uint64).max, scopes, type(uint256).max, address(0));
        }
    }
}
