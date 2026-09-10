// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../interfaces/IHybridToluTagValidationLogic.sol";
import "../errors/ToluTagErrors.sol";

/**
 * @title IHybridToluTagNFTInfo
 * @notice Interface to query collection info from the NFT contract
 */
interface IHybridToluTagNFTInfo {
    function collectionInfo() external view returns (
        string memory productName,
        address creatorAddress,
        uint96 currentRoyalties,
        uint256 maxSupply,
        uint256 totalMinted,
        string memory baseMediaURI,
        uint16 signatureValidTimeRange,
        bytes4 secp256k1ToluTagObjectID,
        uint8 collectionType
    );
}

/**
 * @title HybridToluTagValidationLogic
 * @notice Handles signature validation and approved key management for toluTags
 * @dev Supports both random (collectionType=0) and reserved (collectionType=1) minting
 *      All messages use unified format: "0xAddress_0xUUID_uint256"
 */
contract HybridToluTagValidationLogic is IHybridToluTagValidationLogic, Ownable {
    // Mapping toluTagPublicKey to uuid
    mapping(address => address) public toluTagPublicKeys;

    // Mapping toluTagPublicKey to reserved tokenID (0 = no reservation / random)
    mapping(address => uint256) public reservedTokenId;

    // Mapping tokenID to the ToluTag holding its reservation (address(0) = free).
    // Doubles as the duplicate-reservation guard and as the tokenID -> tag lookup
    // metadata needs to name a reserved token's tag before it is minted.
    mapping(uint256 => address) public reservedTokenTag;

    // Counter for approved keys
    uint256 public approvedToluTagKeysCount;

    // Signature valid time range
    uint16 public signatureValidTimeRange;

    // Address of the NFT contract
    address public nftContract;

    /// @notice Emitted once per key when a ToluTag is registered/approved.
    /// tokenId is 0 for random collections (assigned at mint), or the reserved token ID.
    event ToluTagRegistered(address indexed toluTagPublicKey, address uuid, uint256 tokenId);
    event SignatureValidTimeRangeUpdated(uint16 timeRange);

    /**
     * @notice Constructor
     * @param _signatureValidTimeRange Initial signature valid time range in seconds
     */
    constructor(uint16 _signatureValidTimeRange) {
        signatureValidTimeRange = _signatureValidTimeRange;
    }

    /**
     * @notice Set the NFT contract address (can be called by anyone, but only once)
     * @param _nftContract The address of the NFT contract
     */
    function setNftContract(address _nftContract) external override {
        if (_nftContract == address(0)) revert InvalidNFTContract();
        if (nftContract != address(0)) revert NFTContractAlreadySet();
        nftContract = _nftContract;
    }

    /**
     * @notice Set the signature valid time range (only callable by NFT contract)
     * @param _timeRange The new time range in seconds
     */
    function setSignatureValidTimeRange(uint16 _timeRange) external override {
        if (msg.sender != nftContract) revert OnlyNFTContract();
        signatureValidTimeRange = _timeRange;
        emit SignatureValidTimeRangeUpdated(_timeRange);
    }

    /**
     * @notice Batch set ToluTag public keys with their UUIDs and optional tokenIDs
     * @dev Format: "0xpublicKey_0xuuid_tokenID"
     *      collectionType 0 (random): tokenID must be 0
     *      collectionType 1 (reserved): tokenID must be > 0, unique, and <= maxSupply
     * @param _toluTagPublicKeys Array of strings in format "0xpublicKey_0xuuid_tokenID"
     */
    function batchSetToluTagPublicKeys(string[] calldata _toluTagPublicKeys) external override {
        if (nftContract == address(0)) revert NFTContractNotSet();
        if (msg.sender != nftContract) revert OnlyNFTContract();

        // Get collection info once
        (
            ,           // productName
            ,           // creatorAddress
            ,           // currentRoyalties
            uint256 maxSupply,
            ,           // totalMinted
            ,           // baseMediaURI
            ,           // signatureValidTimeRange
            ,           // secp256k1ToluTagObjectID
            uint8 collectionType
        ) = IHybridToluTagNFTInfo(nftContract).collectionInfo();

        for (uint256 i = 0; i < _toluTagPublicKeys.length; i++) {
            // Parse the string to extract address, uuid, and thirdParam (tokenID)
            (address toluTagPublicKey, address uuid, uint256 tokenID) = _parseMessage(_toluTagPublicKeys[i]);

            // Revert if this key is already approved
            if (toluTagPublicKeys[toluTagPublicKey] != address(0)) revert KeyAlreadyApproved();

            // Store the uuid for this address
            toluTagPublicKeys[toluTagPublicKey] = uuid;
            approvedToluTagKeysCount++;

            // Ensure we don't exceed max supply
            if (approvedToluTagKeysCount > maxSupply) revert ExceedsMaxSupply();

            // Validate and store based on collection type
            if (collectionType == 0) {
                // Random mint: tokenID must be 0
                if (tokenID != 0) revert RandomTokenIdMustBeZero();
            } else if (collectionType == 1) {
                // Reserved mint: tokenID must be valid and unique
                if (tokenID == 0) revert ReservedTokenIdRequired();
                if (tokenID > maxSupply) revert TokenIdExceedsMaxSupply();
                if (reservedTokenTag[tokenID] != address(0)) revert TokenIdAlreadyReserved();

                reservedTokenId[toluTagPublicKey] = tokenID;
                reservedTokenTag[tokenID] = toluTagPublicKey;
            }

            emit ToluTagRegistered(toluTagPublicKey, uuid, tokenID);
        }
    }

    /**
     * @notice Validates a toluTag signature
     * @dev Signed message format: "0xAddress_0xUUID_timestamp"
     */
    function validToluTag(
        bytes32 _r,
        bytes32 _s,
        address _toluTagPublicKey,
        string calldata _signedMessage
    ) external view override returns (ValidationResult memory) {
        // Recreate the Ethereum-Signed-Message hash
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n",
                Strings.toString(bytes(_signedMessage).length),
                _signedMessage
            )
        );

        // Attempt to recover with v = 27 or 28
        address recovered = ecrecover(messageHash, 27, _r, _s);
        if (recovered != _toluTagPublicKey) {
            recovered = ecrecover(messageHash, 28, _r, _s);
            if (recovered != _toluTagPublicKey) {
                return ValidationResult(_toluTagPublicKey, false, "Invalid sig: recovery failed", 0, address(0), VerificationSource.Sender);
            }
        }

        // Parse the signed message: 0xAddress_0xUUID_timestamp
        (address extractedAddrSender, address extractedUuid, uint256 extractedTs) = _parseMessage(_signedMessage);

        VerificationSource verificationSource = extractedAddrSender == _toluTagPublicKey
            ? VerificationSource.Tag
            : VerificationSource.Sender;

        // Ensure the public key is on-chain allowlist and UUID matches
        if (toluTagPublicKeys[_toluTagPublicKey] == address(0) || extractedUuid != toluTagPublicKeys[_toluTagPublicKey]) {
            return ValidationResult(_toluTagPublicKey, false, "Invalid key or uuid", 0, address(0), VerificationSource.Sender);
        }

        // Check timestamp freshness using stored signatureValidTimeRange
        (bool ok, string memory reason) = _validateTimestamp(extractedTs, signatureValidTimeRange);
        if (!ok) {
            return ValidationResult(_toluTagPublicKey, false, reason, extractedTs, extractedAddrSender, verificationSource);
        }

        // All checks passed
        return ValidationResult(_toluTagPublicKey, true, "", extractedTs, extractedAddrSender, verificationSource);
    }

    /**
     * @notice Check if a ToluTag public key is approved
     */
    function isKeyApproved(address _toluTagPublicKey) external view override returns (bool isApproved, address uuid) {
        uuid = toluTagPublicKeys[_toluTagPublicKey];
        isApproved = uuid != address(0);
    }

    /**
     * @notice Get the count of approved ToluTag keys
     */
    function getApprovedKeysCount() external view override returns (uint256) {
        return approvedToluTagKeysCount;
    }

    /**
     * @notice Whether a tokenID has been reserved for a ToluTag
     * @dev Kept as an explicit getter now that the reservation stores the tag
     *      itself — same signature the interface and the metadata contracts use.
     * @param tokenId The token ID to check
     * @return reserved True when some tag holds this token ID
     */
    function isTokenReserved(uint256 tokenId) external view override returns (bool reserved) {
        return reservedTokenTag[tokenId] != address(0);
    }

    /**
     * @notice Get the reserved tokenID for a given public key
     * @param _toluTagPublicKey The public key to check
     * @return The reserved tokenID (0 if none reserved)
     */
    function getReservedTokenId(address _toluTagPublicKey) external view override returns (uint256) {
        return reservedTokenId[_toluTagPublicKey];
    }

    /**
     * @notice Validate the timestamp
     */
    function _validateTimestamp(uint256 _timestamp, uint16 _signatureValidTimeRange)
        private
        view
        returns (bool, string memory)
    {
        if (_timestamp > block.timestamp) {
            return (false, "Invalid time: future");
        }
        if (block.timestamp - _timestamp > _signatureValidTimeRange) {
            return (false, "Invalid time: expired");
        }
        return (true, "");
    }

    /**
     * @notice Parse message in unified 3-part format: "0xAddress_0xAddress_uint256"
     * @dev Used for both signature validation (0xAddr_0xUUID_timestamp)
     *      and key registration (0xPubKey_0xUUID_tokenID)
     * @param signedMsg The message string to parse
     * @return addr The first address
     * @return uuid The second address (UUID)
     * @return thirdParam The uint256 value (timestamp or tokenID)
     */
    function _parseMessage(string calldata signedMsg)
        internal
        pure
        returns (address addr, address uuid, uint256 thirdParam)
    {
        bytes calldata msgBytes = bytes(signedMsg);
        uint256 msgLen = msgBytes.length;

        // Find underscores
        uint256 first = type(uint256).max;
        uint256 second = type(uint256).max;

        for (uint256 i = 0; i < msgLen; i++) {
            if (msgBytes[i] == 0x5F) { // underscore
                if (first == type(uint256).max) {
                    first = i;
                } else {
                    second = i;
                    break;
                }
            }
        }

        // Must have exactly 2 underscores (3 parts)
        if (first == type(uint256).max || second == type(uint256).max) revert InvalidMessageFormat();

        // Part 1: 0xAddress
        addr = _parseHexAddress(msgBytes, 0, first);

        // Part 2: 0xUUID
        uuid = _parseHexAddress(msgBytes, first + 1, second);

        // Part 3: uint256 (timestamp or tokenID)
        for (uint256 i = second + 1; i < msgLen; i++) {
            uint8 char = uint8(msgBytes[i]);
            if (char < 0x30 || char > 0x39) revert InvalidNumberChar();
            thirdParam = thirdParam * 10 + (char - 0x30);
        }
    }

    /**
     * @notice Parse hex address from bytes
     */
    function _parseHexAddress(bytes calldata msgBytes, uint256 startPos, uint256 endPos)
        internal
        pure
        returns (address)
    {
        uint256 len = endPos - startPos;
        if (!(len == 42 && msgBytes[startPos] == 0x30 && msgBytes[startPos + 1] == 0x78)) revert InvalidHexAddress();

        uint160 parsed = 0;
        for (uint256 i = startPos + 2; i < endPos; i++) {
            parsed <<= 4;
            uint8 char = uint8(msgBytes[i]);

            if (char >= 0x30 && char <= 0x39) {
                parsed |= uint160(char - 0x30);
            } else if (char >= 0x41 && char <= 0x46) {
                parsed |= uint160(char - 0x37);
            } else if (char >= 0x61 && char <= 0x66) {
                parsed |= uint160(char - 0x57);
            } else {
                revert InvalidHexChar();
            }
        }

        return address(parsed);
    }
}
