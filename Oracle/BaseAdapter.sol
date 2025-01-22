// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "../Utils/IERC20v8.sol";
import {Errors} from "../lib/Errors.sol";

/// @title BaseAdapter
/// @author Enclabs
/// @notice Abstract adapter with virtual bid/ask pricing.
abstract contract BaseAdapter {
    // @dev Addresses <= 0x00..00ffffffff are considered to have 18 decimals without dispatching a call.
    // This avoids collisions between ISO 4217 representations and (future) precompiles.
    uint256 internal constant ADDRESS_RESERVED_RANGE = 0xffffffff;

    /// @notice Determine the decimals of an asset.
    /// @param asset ERC20 token address or other asset.
    /// @dev Oracles can use ERC-7535, ISO 4217 or other conventions to represent non-ERC20 assets as addresses.
    /// Integrator Note: `_getDecimals` will return 18 if `asset` is:
    /// - any address <= 0x00000000000000000000000000000000ffffffff (4294967295)
    /// - an EOA or a to-be-deployed contract (which may implement `decimals()` after deployment).
    /// - a contract that does not implement `decimals()`.
    /// @return The decimals of the asset.
    function _getDecimals(address asset) internal view returns (uint8) {
        if (uint160(asset) <= ADDRESS_RESERVED_RANGE) return 18;
        (bool success, bytes memory data) = asset.staticcall(abi.encodeCall(IERC20.decimals, ()));
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

}