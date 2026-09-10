// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IHybridToluTagValidationLogic
 * @notice Interface for the Hybrid ToluTag validation logic contract
 * @dev Supports both random and reserved tokenID minting via collectionType
 */
interface IHybridToluTagValidationLogic {
    /// @notice Did the signature come from the tag's own publicKey,(0xtagPublicKeyAddress_0xtagUID_timestamp)
    /// @notice or from a separate "sender" key,(0xwalletCryptoPublicKeyAddress_0xtagUID_timestamp)

    enum VerificationSource { Sender, Tag }

    struct ValidationResult {
        address toluTagPublicKey;
        bool    isValid;
        string  reason;
        uint256 signatureTimestamp;
        address signatureAddress;
        VerificationSource verificationSource;
    }

    /**
     * @notice Validates a toluTag signature
     * @param r The r component of the signature
     * @param s The s component of the signature
     * @param toluTagPublicKey The public key to validate against
     * @param signedMessage The signed message in format "0xAddress_0xUUID_timestamp"
     * @return result The validation result struct
     */
    function validToluTag(
        bytes32 r,
        bytes32 s,
        address toluTagPublicKey,
        string calldata signedMessage
    ) external view returns (ValidationResult memory result);

    /**
     * @notice Batch set ToluTag public keys with their UUIDs and optional tokenIDs
     * @param toluTagPublicKeys Array of strings in format "0xpublicKey_0xuuid_tokenID"
     *        tokenID = 0 for random mint collections (collectionType 0)
     *        tokenID > 0 for reserved mint collections (collectionType 1)
     */
    function batchSetToluTagPublicKeys(string[] calldata toluTagPublicKeys) external;

    /**
     * @notice Check if a ToluTag public key is approved
     * @param toluTagPublicKey The public key to check
     * @return isApproved Whether the key is approved
     * @return uuid The UUID associated with the key
     */
    function isKeyApproved(address toluTagPublicKey)
        external
        view
        returns (bool isApproved, address uuid);

    /**
     * @notice Get the count of approved ToluTag keys
     * @return count The number of approved keys
     */
    function getApprovedKeysCount() external view returns (uint256 count);

    /**
     * @notice Get the reserved tokenID for a given public key
     * @param toluTagPublicKey The public key to check
     * @return tokenId The reserved tokenID (0 if none reserved / random mint)
     */
    function getReservedTokenId(address toluTagPublicKey) external view returns (uint256 tokenId);

    /**
     * @notice Check if a tokenID is already reserved
     * @param tokenId The tokenID to check
     * @return reserved Whether the tokenID is reserved
     */
    function isTokenReserved(uint256 tokenId) external view returns (bool reserved);

    /**
     * @notice The ToluTag holding a token ID's reservation
     * @param tokenId The reserved token ID
     * @return toluTagPublicKey The tag it is reserved for, or address(0) if free
     */
    function reservedTokenTag(uint256 tokenId) external view returns (address toluTagPublicKey);

    /**
     * @notice Get the signature valid time range
     * @return The time range in seconds
     */
    function signatureValidTimeRange() external view returns (uint16);

    /**
     * @notice Set the signature valid time range (only callable by NFT contract)
     * @param _timeRange The new time range in seconds
     */
    function setSignatureValidTimeRange(uint16 _timeRange) external;

    /**
     * @notice Set the NFT contract address (only callable once)
     * @param _nftContract The address of the NFT contract
     */
    function setNftContract(address _nftContract) external;

    /**
     * @notice Get the NFT contract address
     * @return The address of the NFT contract
     */
    function nftContract() external view returns (address);
}
