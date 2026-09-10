// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IHybridToluTagMetadata.sol";
import "../errors/ToluTagErrors.sol";

/**
 * @title IHybridToluTagNFT
 * @notice Interface to interact with the NFT contract
 */
interface IHybridToluTagNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function owner() external view returns (address);

    function products(uint256 tokenId) external view returns (
        address toluTagPublicKey,
        address owner,
        bool paired,
        uint256 pairedUpdatedAt
    );

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
 * @title IHybridToluTagValidationLogicMetadata
 * @notice Interface to query reserved token info from validation logic
 */
interface IHybridToluTagValidationLogicMetadata {
    function isTokenReserved(uint256 tokenId) external view returns (bool);
    function nftContract() external view returns (address);
}

/**
 * @title HybridToluTagMetadataRandom
 * @notice Builds the on-chain metadata document every ToluTag NFT serves from
 *         tokenURI(): the default fields plus the collection's custom traits,
 *         base64-encoded as a data URI. No IPFS JSON, no server.
 * @dev The whole drop shares one set of traits, which is what a random-mint
 *      collection needs — every product in it is the same item, and the token id
 *      is only decided at mint. Supports showing metadata for both minted and
 *      reserved-but-unminted tokens.
 */
contract HybridToluTagMetadataRandom is IHybridToluTagMetadata, Ownable {
    /// @notice One custom trait, rendered into the "attributes" array.
    struct Attribute {
        string traitType;
        string value;
    }

    /// @notice Longest a trait type or value may be, so one entry cannot make tokenURI unreadable.
    uint256 internal constant MAX_ATTRIBUTE_CHARS = 200;

    /// @notice Upper bound on the trait list, so tokenURI() stays cheap to read.
    uint256 public constant MAX_ATTRIBUTES = 32;

    /// @notice Traits added to every token in the collection.
    Attribute[] private _collectionAttributes;

    event CollectionAttributesUpdated(uint256 count);
    // Reference to the NFT contract
    IHybridToluTagNFT public nftContract;

    // Reference to the validation logic contract
    IHybridToluTagValidationLogicMetadata public validationLogic;

    /**
     * @notice Constructor
     * @dev Traits are accepted here so a collection can be deployed with them in one
     *      go. They cannot be written afterwards in the same breath: the setter is
     *      gated on the NFT's owner(), and this contract does not know its NFT until
     *      the NFT's own constructor binds it — which happens after this one runs.
     *      Deploying is itself proof of ownership, so no gate is needed at this point.
     * @param _validationLogic Address of the validation logic contract
     * @param attributes Traits shared by every token; pass an empty array for none.
     */
    constructor(address _validationLogic, Attribute[] memory attributes) {
        if (_validationLogic == address(0)) revert InvalidValidationLogic();
        validationLogic = IHybridToluTagValidationLogicMetadata(_validationLogic);
        _writeAttributes(attributes);
    }

    /**
     * @notice Set the NFT contract address (can be called by anyone, but only once)
     * @param _nftContract Address of the NFT contract
     */
    function setNftContract(address _nftContract) external override {
        if (_nftContract == address(0)) revert InvalidNFTContract();
        if (address(nftContract) != address(0)) revert NFTContractAlreadySet();
        nftContract = IHybridToluTagNFT(_nftContract);
    }

    //************************************* Custom traits *************************************//

    /**
     * @notice Replace the collection's custom traits (collection owner only)
     * @dev Replaces the whole list rather than patching entries, so one call always
     *      leaves a known state. Pass an empty array to drop back to the defaults.
     * @param attributes The traits every token should carry.
     */
    function setCollectionAttributes(Attribute[] calldata attributes) external onlyCollectionOwner {
        _writeAttributes(attributes);
    }

    /**
     * @notice Replace the stored trait list. Shared by the constructor and the setter,
     *         so both validate and cap the list the same way.
     */
    function _writeAttributes(Attribute[] memory attributes) internal {
        if (attributes.length > MAX_ATTRIBUTES) revert TooManyAttributes();

        delete _collectionAttributes;
        for (uint256 i = 0; i < attributes.length; i++) {
            _requireSafeText(attributes[i].traitType);
            _requireSafeText(attributes[i].value);
            _collectionAttributes.push(attributes[i]);
        }

        emit CollectionAttributesUpdated(attributes.length);
    }

    /**
     * @notice The collection's custom traits, in render order.
     */
    function collectionAttributes() external view returns (Attribute[] memory) {
        return _collectionAttributes;
    }

    /**
     * @notice How many custom traits are set.
     */
    function collectionAttributesCount() external view returns (uint256) {
        return _collectionAttributes.length;
    }

    //**************************************** Metadata ****************************************//

    /**
    * @notice Generate token URI with on-chain metadata
    * @dev For collectionType 0 (random): only minted tokens return metadata
    *      For collectionType 1 (reserved): both minted and reserved-but-unminted tokens return metadata
    * @param tokenId The token ID to generate metadata for
    * @return The complete token URI as a data URI
    */
    function tokenURI(uint256 tokenId) external view override returns (string memory) {
        if (address(nftContract) == address(0)) revert NFTContractNotSet();

        // Get collection info
        (
            string memory productName,
            address creatorAddress,
            ,  // currentRoyalties
            ,  // maxSupply
            ,  // totalMinted
            string memory baseMediaURI,
            ,  // signatureValidTimeRange
            ,  // secp256k1ToluTagObjectID
            uint8 collectionType
        ) = nftContract.collectionInfo();

        // Check if token is minted
        bool isMinted = _isTokenMinted(tokenId);

        if (isMinted) {
            // Token is minted - return full metadata with "minted": true
            (
                address toluTagPublicKey,
                ,
                bool paired,
                uint256 pairedUpdatedAt
            ) = nftContract.products(tokenId);

            string memory json = _buildJSONPart1(tokenId, productName, creatorAddress, toluTagPublicKey, true);
            json = _buildJSONPart2(json, paired, pairedUpdatedAt, baseMediaURI);
            json = _appendAttributes(json);

            string memory base64Json = Base64.encode(bytes(json));
            return string(abi.encodePacked("data:application/json;base64,", base64Json));
        } else if (collectionType == 1) {
            // Reserved collection - check if token is reserved but not yet minted
            if (!validationLogic.isTokenReserved(tokenId)) revert TokenDoesNotExist();

            // Build partial metadata with "minted": false
            string memory json = _buildJSONPart1(tokenId, productName, creatorAddress, address(0), false);
            json = _buildJSONPart2Unminted(json, baseMediaURI);
            json = _appendAttributes(json);

            string memory base64Json = Base64.encode(bytes(json));
            return string(abi.encodePacked("data:application/json;base64,", base64Json));
        } else {
            // Random collection and not minted - no metadata available
            revert TokenDoesNotExist();
        }
    }

    /**
     * @notice Check if a token is minted using try/catch on ownerOf
     * @param tokenId The token ID to check
     * @return True if the token is minted
     */
    function _isTokenMinted(uint256 tokenId) internal view returns (bool) {
        try nftContract.ownerOf(tokenId) returns (address tokenOwner) {
            return tokenOwner != address(0);
        } catch {
            return false;
        }
    }

    /**
     * @notice Build the first part of JSON metadata
     */
    function _buildJSONPart1(
        uint256 tokenId,
        string memory productName,
        address creatorAddress,
        address toluTagPublicKey,
        bool minted
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{',
                '"contractOwner":"', Strings.toHexString(uint160(creatorAddress), 20), '",',
                '"productName":"', productName, '",',
                '"tokenID":"', Strings.toString(tokenId), '",',
                '"toluTagPublicKey":"', Strings.toHexString(uint160(toluTagPublicKey), 20), '",',
                '"minted":', minted ? 'true' : 'false', ','
            )
        );
    }

    /**
    * @notice Build the second part of JSON metadata for MINTED tokens
    * @dev tokenMediaURL is the collection's media location as stored — every token
    *      in the drop is the same product, so no token id is appended.
    */
    function _buildJSONPart2(
        string memory existingJson,
        bool paired,
        uint256 pairedUpdatedAt,
        string memory baseMediaURI
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                existingJson,
                '"paired":', paired ? 'true' : 'false', ',',
                '"pairedUpdatedAt":"', Strings.toString(pairedUpdatedAt), '",',
                '"tokenMediaURL":"', baseMediaURI, '"'
            )
        );
    }

    /**
    * @notice Build the second part of JSON metadata for UNMINTED reserved tokens
    */
    function _buildJSONPart2Unminted(
        string memory existingJson,
        string memory baseMediaURI
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                existingJson,
                '"paired":false,',
                '"pairedUpdatedAt":"0",',
                '"tokenMediaURL":"', baseMediaURI, '"'
            )
        );
    }

    /**
     * @notice The collection's traits as "attributes" array entries, or "" if none.
     */
    function _attributesJSON() internal view returns (string memory) {
        uint256 count = _collectionAttributes.length;
        if (count == 0) return "";

        bytes memory out;
        for (uint256 i = 0; i < count; i++) {
            out = abi.encodePacked(out, i == 0 ? "" : ",", _attributeJSON(_collectionAttributes[i]));
        }
        return string(out);
    }

    /**
     * @notice Close the JSON document, with an "attributes" array if there is one.
     * @dev The Part2 builders deliberately leave the object open so this can decide.
     */
    function _appendAttributes(string memory json) internal view returns (string memory) {
        string memory attributes = _attributesJSON();
        if (bytes(attributes).length == 0) {
            return string(abi.encodePacked(json, "}"));
        }
        return string(abi.encodePacked(json, ',"attributes":[', attributes, "]}"));
    }

    /**
     * @notice Render one trait as an "attributes" entry.
     */
    function _attributeJSON(Attribute memory attribute) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"trait_type":"', attribute.traitType, '","value":"', attribute.value, '"}'
            )
        );
    }

    /**
     * @notice Reject trait text that would break the JSON document.
     * @dev The document is assembled by concatenation, so an unescaped quote or
     *      backslash — or any control character — corrupts every token's metadata,
     *      not just this trait. Cheaper to refuse it at write time than to escape.
     */
    function _requireSafeText(string memory text) internal pure {
        bytes memory raw = bytes(text);
        if (raw.length == 0 || raw.length > MAX_ATTRIBUTE_CHARS) revert InvalidAttribute();
        for (uint256 i = 0; i < raw.length; i++) {
            bytes1 c = raw[i];
            if (c == '"' || c == "\\" || uint8(c) < 0x20 || uint8(c) == 0x7F) revert InvalidAttribute();
        }
    }

    /**
     * @notice Restrict a write to whoever owns the collection right now.
     * @dev Deliberately the NFT's owner rather than this contract's Ownable owner,
     *      so transferring the collection carries the metadata rights with it.
     */
    modifier onlyCollectionOwner() {
        if (address(nftContract) == address(0)) revert NFTContractNotSet();
        if (msg.sender != nftContract.owner()) revert NotCollectionOwner();
        _;
    }

    //**************************************** Metadata ****************************************//
}
