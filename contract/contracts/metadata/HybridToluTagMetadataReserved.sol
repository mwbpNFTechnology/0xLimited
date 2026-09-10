// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IHybridToluTagMetadata.sol";
import "../errors/ToluTagErrors.sol";

/**
 * @title IHybridToluTagNFTReserved
 * @notice Interface to interact with the NFT contract
 */
interface IHybridToluTagNFTReserved {
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
 * @title IHybridToluTagValidationLogicReserved
 * @notice Interface to query reserved token info from validation logic
 */
interface IHybridToluTagValidationLogicReserved {
    function isTokenReserved(uint256 tokenId) external view returns (bool);
    function reservedTokenTag(uint256 tokenId) external view returns (address);
    function nftContract() external view returns (address);
}

/**
 * @title HybridToluTagMetadataReserved
 * @notice Metadata for a reserved collection, where the physical items differ from
 *         one another. The default fields stay on-chain exactly as in the random
 *         variant; each token's own traits live beside its media, in a per-token
 *         folder on IPFS.
 * @dev Every token gets its own folder under the collection's media URI:
 *
 *          <baseMediaURI><tokenId>/                  -> tokenMediaURL
 *          <baseMediaURI><tokenId>/attributes.json   -> attributesURL
 *
 *      Storing an ipfs:// CID as the base is what makes the off-chain half
 *      trustworthy: the CID is a content hash of the whole folder tree, so the
 *      traits cannot change without changing the URI held on-chain — which only
 *      the collection owner can do, in public, via updateCollectionInfo().
 *
 *      Traits are not stored here: with a folder per token, writing them on-chain
 *      would be a string store per trait per item, and the folder has to exist
 *      anyway for the media.
 */
contract HybridToluTagMetadataReserved is IHybridToluTagMetadata, Ownable {
    /// @notice File holding a token's traits, inside its own media folder.
    string public constant ATTRIBUTES_FILE = "attributes.json";

    // Reference to the NFT contract
    IHybridToluTagNFTReserved public nftContract;

    // Reference to the validation logic contract
    IHybridToluTagValidationLogicReserved public validationLogic;

    /**
     * @notice Constructor
     * @param _validationLogic Address of the validation logic contract
     */
    constructor(address _validationLogic) {
        if (_validationLogic == address(0)) revert InvalidValidationLogic();
        validationLogic = IHybridToluTagValidationLogicReserved(_validationLogic);
    }

    /**
     * @notice Set the NFT contract address (can be called by anyone, but only once)
     * @param _nftContract Address of the NFT contract
     */
    function setNftContract(address _nftContract) external override {
        if (_nftContract == address(0)) revert InvalidNFTContract();
        if (address(nftContract) != address(0)) revert NFTContractAlreadySet();
        nftContract = IHybridToluTagNFTReserved(_nftContract);
    }

    //************************************* Token folders *************************************//

    /**
     * @notice The media folder for one token: <baseMediaURI><tokenId>/
     * @param tokenId The token to address.
     */
    function tokenFolder(uint256 tokenId) public view returns (string memory) {
        if (address(nftContract) == address(0)) revert NFTContractNotSet();
        (, , , , , string memory baseMediaURI, , , ) = nftContract.collectionInfo();
        return _tokenFolder(baseMediaURI, tokenId);
    }

    /**
     * @notice Where a token's traits live: <baseMediaURI><tokenId>/attributes.json
     * @param tokenId The token to address.
     */
    function attributesURL(uint256 tokenId) external view returns (string memory) {
        return string(abi.encodePacked(tokenFolder(tokenId), ATTRIBUTES_FILE));
    }

    //**************************************** Metadata ****************************************//

    /**
    * @notice Generate token URI with on-chain metadata
    * @dev Minted tokens and reserved-but-unminted tokens both render; the token id
    *      is known at registration, so a token's folder resolves before any mint.
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

        // A random collection has one folder for the whole drop, so its tokens would
        // be pointed at folders that do not exist. Fail loudly rather than serve them:
        // this contract cannot be swapped out once the NFT is deployed.
        if (collectionType != 1) revert NotReservedCollection();

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
            json = _buildJSONPart2(json, paired, pairedUpdatedAt, baseMediaURI, tokenId);

            string memory base64Json = Base64.encode(bytes(json));
            return string(abi.encodePacked("data:application/json;base64,", base64Json));
        } else {
            // Reserved but not yet minted - metadata still resolves, "minted": false.
            // The tag is bound to the token at registration, so it can be named here
            // even though nothing has been minted against it yet.
            address reservedTag = validationLogic.reservedTokenTag(tokenId);
            if (reservedTag == address(0)) revert TokenDoesNotExist();

            string memory json = _buildJSONPart1(tokenId, productName, creatorAddress, reservedTag, false);
            json = _buildJSONPart2Unminted(json, baseMediaURI, tokenId);

            string memory base64Json = Base64.encode(bytes(json));
            return string(abi.encodePacked("data:application/json;base64,", base64Json));
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
    * @dev Each token has its own media folder, and its traits sit inside it.
    */
    function _buildJSONPart2(
        string memory existingJson,
        bool paired,
        uint256 pairedUpdatedAt,
        string memory baseMediaURI,
        uint256 tokenId
    ) internal pure returns (string memory) {
        string memory folder = _tokenFolder(baseMediaURI, tokenId);
        return string(
            abi.encodePacked(
                existingJson,
                '"paired":', paired ? 'true' : 'false', ',',
                '"pairedUpdatedAt":"', Strings.toString(pairedUpdatedAt), '",',
                '"tokenMediaURL":"', folder, '",',
                '"attributesURL":"', folder, ATTRIBUTES_FILE, '"',
                '}'
            )
        );
    }

    /**
    * @notice Build the second part of JSON metadata for UNMINTED reserved tokens
    */
    function _buildJSONPart2Unminted(
        string memory existingJson,
        string memory baseMediaURI,
        uint256 tokenId
    ) internal pure returns (string memory) {
        string memory folder = _tokenFolder(baseMediaURI, tokenId);
        return string(
            abi.encodePacked(
                existingJson,
                '"paired":false,',
                '"pairedUpdatedAt":"0",',
                '"tokenMediaURL":"', folder, '",',
                '"attributesURL":"', folder, ATTRIBUTES_FILE, '"',
                '}'
            )
        );
    }

    /**
     * @notice <baseMediaURI><tokenId>/ — the collection's media URI must end in "/".
     */
    function _tokenFolder(string memory baseMediaURI, uint256 tokenId) internal pure returns (string memory) {
        return string(abi.encodePacked(baseMediaURI, Strings.toString(tokenId), "/"));
    }
}
