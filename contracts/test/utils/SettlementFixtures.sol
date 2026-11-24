// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Skims 1% of every transfer, the way fee-on-transfer tokens do.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = value / 100;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @dev Approve/transferFrom protocol: pulls `amount` from the caller, the way a DEX router
///      or any pull-based contract settles.
contract PullingTarget {
    IERC20 public immutable token;
    uint256 public received;

    constructor(IERC20 token_) {
        token = token_;
    }

    function pull(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        received += amount;
    }

    /// Pulls `amount`, then hands `change` back to the caller.
    function pullWithChange(uint256 amount, uint256 change) external {
        token.transferFrom(msg.sender, address(this), amount);
        token.transfer(msg.sender, change);
        received += amount - change;
    }

    /// Tries to take more than the caller approved.
    function pullTwice(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        token.transferFrom(msg.sender, address(this), amount);
    }

    function boom() external pure {
        revert("boom");
    }
}

/// @dev A contract that does not account for tokens: it takes the call and nothing else.
contract IgnoringTarget {
    uint256 public pings;

    function ping() external {
        pings++;
    }
}
