// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

/// @title IOrgRegistry
/// @notice Org tree: human roots, manager agents, worker agents, and reporting edges.
/// @dev Structural changes must flow through GovernanceModule (not implemented yet).
interface IOrgRegistry {
    enum NodeKind {
        HumanRoot,
        ManagerAgent,
        WorkerAgent
    }

    struct Node {
        address account;
        NodeKind kind;
        address parent;
        bool active;
    }

    /// @notice The org's single root node. It can be neither deactivated nor removed;
    ///         governance can hand it to a new key (`OrgRegistry.rotateRoot`).
    function root() external view returns (address);

    /// @notice Returns node metadata for `account`.
    function getNode(address account) external view returns (Node memory node);

    /// @notice Incarnation counter of `account`. It increases each time the address is
    ///         added to the tree, so state recorded against an earlier incarnation
    ///         (intents, session keys, allowances) can be told apart from the current one.
    ///         Stays at its last value while the node is removed.
    function generationOf(address account) external view returns (uint64);

    /// @notice Returns direct reports of `parent`.
    function getChildren(address parent) external view returns (address[] memory children);
}
