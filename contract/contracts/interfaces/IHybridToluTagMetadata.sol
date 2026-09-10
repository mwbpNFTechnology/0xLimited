// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IHybridToluTagMetadata
 * @notice Interface for metadata generation
 */
interface IHybridToluTagMetadata {
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function setNftContract(address _nftContract) external;
}
