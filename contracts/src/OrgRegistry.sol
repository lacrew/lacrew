// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {IOrgRegistry} from "./interfaces/IOrgRegistry.sol";

/// @title OrgRegistry
/// @notice Stores the organization tree for a single LaCrew org.
/// @dev Bootstrap: only `root` may mutate until `setGovernor` binds GovernanceModule.
///
///      Multi-human orgs are one tree, not a forest: the org keeps a single root node,
///      and additional humans are `HumanRoot` nodes parented to it. That is what makes
///      a second partner cheap — no new contract, no virtual org above the root, and
///      every existing walk (children, reparent, cycle check) already handles it. The
///      root node is unremovable here, so the tree always retains at least one human;
///      the seat side of the same guarantee lives in `GovernanceModule.removeHuman`.
///
///      Peer humans are peers in authority, not in the tree: the root node is where the
///      chart hangs from, while who may veto or vote is `GovernanceModule`'s seat
///      roster. Reading kind `HumanRoot` off this registry tells a UI who to draw as a
///      human; it does not by itself confer a vote.
contract OrgRegistry is IOrgRegistry {
    mapping(address => Node) private _nodes;
    mapping(address => address[]) private _children;

    address public root;
    /// @notice When non-zero, only this address may mutate the tree (GovernanceModule).
    address public governor;

    /// @notice Max direct children per node. Bounds `removeNode` (re-parents every
    ///         child) and `_removeFromParent` (linear sibling scan) under the block gas limit.
    uint256 public constant MAX_CHILDREN = 100;
    /// @notice Max tree depth below root. Bounds the ancestor walk in `addNode`/`reparent`.
    uint256 public constant MAX_DEPTH = 32;

    event NodeAdded(address indexed account, NodeKind kind, address indexed parent);
    event NodeRemoved(address indexed account, address indexed formerParent);
    event NodeReparented(address indexed account, address indexed oldParent, address indexed newParent);
    event NodeActiveUpdated(address indexed account, bool active);
    event RootRotated(address indexed oldRoot, address indexed newRoot);

    error NodeAlreadyExists(address account);
    error NodeNotFound(address account);
    error InvalidParent(address parent);
    error CannotMutateRoot(address account);
    error CyclicParent(address account, address newParent);
    error NotAuthorized(address caller);
    error GovernorAlreadySet();
    error ZeroAddress();
    error TooManyChildren(address parent);
    error MaxDepthExceeded(address account);
    error InvalidRoot(address account);

    constructor(address humanRoot) {
        if (humanRoot == address(0)) revert ZeroAddress();
        root = humanRoot;
        _nodes[humanRoot] = Node({
            account: humanRoot,
            kind: NodeKind.HumanRoot,
            parent: address(0),
            active: true
        });
    }

    /// @inheritdoc IOrgRegistry
    function getNode(address account) external view returns (Node memory node) {
        node = _nodes[account];
        if (node.account == address(0)) revert NodeNotFound(account);
    }

    /// @inheritdoc IOrgRegistry
    function getChildren(address parent) external view returns (address[] memory children) {
        return _children[parent];
    }

    /// @notice Bind constitutional authority. Callable once by root (or current governor).
    function setGovernor(address governor_) external {
        if (governor_ == address(0)) revert ZeroAddress();
        if (governor != address(0)) {
            if (msg.sender != governor) revert NotAuthorized(msg.sender);
        } else if (msg.sender != root) {
            revert NotAuthorized(msg.sender);
        }
        governor = governor_;
    }

    /// @notice Hand the root node to `newRoot`, the recovery path for a lost or
    ///         compromised root key. Governor-only once one is bound (GovernanceModule
    ///         reaches it through a High-tier `rotateRoot`); the root itself before that.
    /// @dev The old root's node is removed, not demoted: a key retired because it may be
    ///      compromised keeps no place in the tree, and with it no fallback authority in
    ///      `EscalationRouter.resolve`, which reads `root` live. Its direct reports move
    ///      under `newRoot` unchanged.
    ///
    ///      `newRoot` is either a fresh address or a peer human already seated under the
    ///      root (a `HumanRoot` child of it) — promoting a partner is the common case.
    ///      Any other existing node is refused: lifting an agent, or a human from deeper
    ///      in the tree, to the top would silently restructure what hangs below it.
    function rotateRoot(address newRoot) external {
        _authorize();
        if (newRoot == address(0)) revert ZeroAddress();
        address oldRoot = root;
        Node storage promoted = _nodes[newRoot];
        if (promoted.account != address(0)) {
            if (promoted.kind != NodeKind.HumanRoot || promoted.parent != oldRoot) {
                revert InvalidRoot(newRoot);
            }
            _removeFromParent(oldRoot, newRoot);
            promoted.parent = address(0);
            promoted.active = true;
            emit NodeReparented(newRoot, oldRoot, address(0));
        } else {
            _nodes[newRoot] = Node({
                account: newRoot,
                kind: NodeKind.HumanRoot,
                parent: address(0),
                active: true
            });
            emit NodeAdded(newRoot, NodeKind.HumanRoot, address(0));
        }

        address[] storage kids = _children[oldRoot];
        uint256 kidCount = kids.length;
        // The promoted peer may already have reports; the MAX_CHILDREN cap holds after the move too.
        if (_children[newRoot].length + kidCount > MAX_CHILDREN) revert TooManyChildren(newRoot);
        for (uint256 i = 0; i < kidCount; i++) {
            address child = kids[i];
            _nodes[child].parent = newRoot;
            _children[newRoot].push(child);
            emit NodeReparented(child, oldRoot, newRoot);
        }
        delete _children[oldRoot];
        delete _nodes[oldRoot];
        root = newRoot;
        emit NodeRemoved(oldRoot, address(0));
        emit RootRotated(oldRoot, newRoot);
    }

    /// @notice Add a child node under `parent`.
    /// @dev The zero address is how an empty slot reads, so it can never be a node:
    ///      one stored there would be invisible to `getNode` and `removeNode` while
    ///      still listed among its parent's children.
    function addNode(address account, NodeKind kind, address parent) external {
        _authorize();
        if (account == address(0)) revert ZeroAddress();
        if (_nodes[account].account != address(0)) revert NodeAlreadyExists(account);
        if (_nodes[parent].account == address(0)) revert InvalidParent(parent);

        if (_children[parent].length >= MAX_CHILDREN) revert TooManyChildren(parent);
        if (_depth(parent) >= MAX_DEPTH) revert MaxDepthExceeded(account);

        _nodes[account] = Node({account: account, kind: kind, parent: parent, active: true});
        _children[parent].push(account);
        emit NodeAdded(account, kind, parent);
    }

    /// @notice Soft-deactivate a node without removing it from the tree.
    function setActive(address account, bool active) external {
        _authorize();
        if (_nodes[account].account == address(0)) revert NodeNotFound(account);
        if (account == root) revert CannotMutateRoot(account);
        _nodes[account].active = active;
        emit NodeActiveUpdated(account, active);
    }

    /// @notice Fire/remove a node. Children are rewired to the removed node's parent.
    function removeNode(address account) external {
        _authorize();
        Node memory node = _nodes[account];
        if (node.account == address(0)) revert NodeNotFound(account);
        if (account == root) revert CannotMutateRoot(account);

        address parent = node.parent;
        address[] storage kids = _children[account];
        uint256 kidCount = kids.length;
        // The parent loses `account` but gains its children; keep the sibling list bounded.
        if (_children[parent].length - 1 + kidCount > MAX_CHILDREN) revert TooManyChildren(parent);
        for (uint256 i = 0; i < kidCount; i++) {
            address child = kids[i];
            _nodes[child].parent = parent;
            _children[parent].push(child);
        }
        delete _children[account];

        _removeFromParent(parent, account);
        delete _nodes[account];
        emit NodeRemoved(account, parent);
    }

    /// @notice Move `account` under `newParent`. Rejects cycles and root moves.
    function reparent(address account, address newParent) external {
        _authorize();
        Node storage node = _nodes[account];
        if (node.account == address(0)) revert NodeNotFound(account);
        if (account == root) revert CannotMutateRoot(account);
        if (_nodes[newParent].account == address(0)) revert InvalidParent(newParent);
        if (newParent == account) revert CyclicParent(account, newParent);
        if (_isAncestor(account, newParent)) revert CyclicParent(account, newParent);

        address oldParent = node.parent;
        if (oldParent == newParent) return;
        if (_children[newParent].length >= MAX_CHILDREN) revert TooManyChildren(newParent);

        _removeFromParent(oldParent, account);
        node.parent = newParent;
        _children[newParent].push(account);
        emit NodeReparented(account, oldParent, newParent);
    }

    /// @dev True if `maybeAncestor` is on the path from `node` up to root. The walk is
    ///      capped at MAX_DEPTH hops; a deeper chain reverts instead of burning gas.
    function _isAncestor(address maybeAncestor, address node) private view returns (bool) {
        address cursor = node;
        for (uint256 i = 0; cursor != address(0); i++) {
            if (cursor == maybeAncestor) return true;
            if (i > MAX_DEPTH) revert MaxDepthExceeded(node);
            cursor = _nodes[cursor].parent;
        }
        return false;
    }

    /// @dev Hops from `node` to root (root = 0), reverting past MAX_DEPTH.
    function _depth(address node) private view returns (uint256 d) {
        address cursor = _nodes[node].parent;
        while (cursor != address(0)) {
            if (++d > MAX_DEPTH) revert MaxDepthExceeded(node);
            cursor = _nodes[cursor].parent;
        }
    }

    function _removeFromParent(address parent, address child) private {
        address[] storage siblings = _children[parent];
        uint256 n = siblings.length;
        for (uint256 i = 0; i < n; i++) {
            if (siblings[i] == child) {
                siblings[i] = siblings[n - 1];
                siblings.pop();
                return;
            }
        }
    }

    function _authorize() private view {
        if (governor != address(0)) {
            if (msg.sender != governor) revert NotAuthorized(msg.sender);
        } else if (msg.sender != root) {
            revert NotAuthorized(msg.sender);
        }
    }
}
