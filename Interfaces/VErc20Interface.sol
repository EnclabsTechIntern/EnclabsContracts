// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface VErc20Interface is IERC20Metadata {
    /**
     * @notice Underlying asset for this VToken
     */
    function underlying() external view returns (address);
}
