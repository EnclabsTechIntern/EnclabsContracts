// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.25;

/**
 * @title PoolRegistryInterface
 * @author Enclabs
 * @notice Interface implemented by `PoolRegistry`.
 */
interface PoolRegistryInterface {
    /**
     * @notice Struct for a Enclabs interest rate pool.
     */
    struct EnclabsPool {
        string name;
        address creator;
        address comptroller;
        uint256 blockPosted;
        uint256 timestampPosted;
    }

    /**
     * @notice Struct for a Enclabs interest rate pool metadata.
     */
    struct EnclabsPoolMetaData {
        string category;
        string logoURL;
        string description;
    }

    /// @notice Get all pools in PoolRegistry
    function getAllPools() external view returns (EnclabsPool[] memory);

    /// @notice Get a pool by comptroller address
    function getPoolByComptroller(address comptroller) external view returns (EnclabsPool memory);

    /// @notice Get the address of the VToken contract in the Pool where the underlying token is the provided asset
    function getVTokenForAsset(address comptroller, address asset) external view returns (address);

    /// @notice Get the addresss of the Pools supported that include a market for the provided asset
    function getPoolsSupportedByAsset(address asset) external view returns (address[] memory);

    /// @notice Get the metadata of a Pool by comptroller address
    function getEnclabsPoolMetadata(address comptroller) external view returns (EnclabsPoolMetaData memory);
}
