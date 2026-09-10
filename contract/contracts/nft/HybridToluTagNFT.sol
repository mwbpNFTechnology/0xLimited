// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../interfaces/IHybridToluTagValidationLogic.sol";
import "../interfaces/IHybridToluTagMetadata.sol";
import "../errors/ToluTagErrors.sol";

/// @notice Interface for external access to pairing functionality
interface IHybridToluTagBase {
    function pairProduct(
        bytes32 r,
        bytes32 s,
        address toluTagPublicKey,
        string calldata _signedMessage
    ) external;

    function isPaired(uint256 tokenId)
        external
        view
        returns (bool paired, uint256 pairedUpdatedAt);

    function getProduct(uint256 tokenId)
        external
        view
        returns (
            address toluTagPublicKey,
            address owner,
            bool paired,
            uint256 pairedUpdatedAt
        );
}

/**
 * @title HybridToluTagNFT
 * @notice Main NFT contract for toluTag system with physical product pairing
 * @dev Supports both random (collectionType=0) and reserved (collectionType=1) minting
 *      Transfers require signature validation from the NFC chip
 */
abstract contract HybridToluTagNFT is ERC721, Ownable, IERC2981, ReentrancyGuard, IHybridToluTagBase {
    event ProductPaired(uint256 indexed nftTokenId, address indexed owner, address toluTagPublicKey, bool isPaired, uint256 pairedAt);
    event MarketplaceApprovalUpdated(address indexed marketplace, bool approved);
    event CollectionInfoUpdated(uint96 royalties, string baseMediaURI, uint16 signatureValidTimeRange);

    // Reference to the validation logic contract
    IHybridToluTagValidationLogic public immutable validationLogic;

    // Reference to the metadata contract — fixed at deployment, never replaceable
    IHybridToluTagMetadata public immutable metadataContract;

    // Collection information
    CollectionInfo public collectionInfo;

    // Mapping nftTokenID to Product
    mapping(uint256 => Product) public products;

    // Mapping toluTagPublicKey to nftTokenID
    mapping(address => uint256) public toluTagKeyToNFTTokenID;

    // Mapping of approved marketplaces
    mapping(address => bool) public approvedMarketplace;

    // For random token generation (only used when collectionType == 0)
    uint256 private _remainingTokens;
    mapping(uint256 => uint256) private _tokenMatrix;

    // Structs
    struct Product {
        address toluTagPublicKey;
        address owner;
        bool paired;
        uint256 pairedUpdatedAt;
    }

    struct CollectionInfo {
        string productName;
        address creatorAddress;
        uint96 currentRoyalties;
        uint256 maxSupply;
        uint256 totalMinted;
        string baseMediaURI;
        uint16 signatureValidTimeRange;
        bytes4 secp256k1Keys;
        uint8 collectionType; // 0 = random, 1 = reserved
    }


    /**
     * @notice Constructor
     * @param _validationLogic Address of the validation logic contract
     * @param _metadataContract Address of the metadata contract (required — it cannot be changed later)
     * @param _productName Name of the token
     * @param _maxSupply Maximum token supply
     * @param _royalties Royalty basis points
     * @param _baseMediaURI Base media URI
     * @param _secp256k1ToluTagObjectID Object ID for secp256k1 keys
     * @param _collectionType 0 = random mint, 1 = reserved mint
     */
    constructor(
        address _validationLogic,
        address _metadataContract,
        string memory _productName,
        uint256 _maxSupply,
        uint96 _royalties,
        string memory _baseMediaURI,
        bytes4 _secp256k1ToluTagObjectID,
        uint8 _collectionType
    )
        ERC721(_productName, "toluProduct")
    {
        if (_validationLogic == address(0)) revert InvalidValidationLogic();
        if (_metadataContract == address(0)) revert InvalidMetadataContract();
        if (_collectionType > 1) revert InvalidCollectionType();

        validationLogic = IHybridToluTagValidationLogic(_validationLogic);

        // Set this contract as the NFT contract in the validation logic
        validationLogic.setNftContract(address(this));

        // Bind the metadata contract for good. It is immutable, so it has to be
        // supplied here — a collection deployed without one could never render.
        metadataContract = IHybridToluTagMetadata(_metadataContract);
        // Also set this contract as the NFT contract in metadata
        metadataContract.setNftContract(address(this));

        // Read signatureValidTimeRange from validation logic contract
        uint16 timeRange = validationLogic.signatureValidTimeRange();

        collectionInfo = CollectionInfo(
            _productName,
            msg.sender,
            _royalties,
            _maxSupply,
            0,
            _baseMediaURI,
            timeRange,  // Use time range from validation logic
            _secp256k1ToluTagObjectID,
            _collectionType
        );

        _remainingTokens = _maxSupply;
    }

    /**
     * @notice Mint a new token
     * @dev collectionType 0: random tokenID assignment
     *      collectionType 1: reserved tokenID from key registration
     * @param _r The r component of the signature
     * @param _s The s component of the signature
     * @param _toluTagPublicKey The public key to mint with
     * @param _signedMessage The signed message in format "0xAddress_0xUUID_timestamp"
     */
    function mint(
        bytes32 _r,
        bytes32 _s,
        address _toluTagPublicKey,
        string calldata _signedMessage
    ) external nonReentrant {
        // Check if we haven't exceeded max supply
        uint256 approvedKeysCount = validationLogic.getApprovedKeysCount();
        if (collectionInfo.totalMinted >= collectionInfo.maxSupply) revert MaxSupplyReached();
        if (collectionInfo.totalMinted >= approvedKeysCount) revert AllApprovedKeysUsed();

        // Validate signature
        IHybridToluTagValidationLogic.ValidationResult memory result = validationLogic.validToluTag(
            _r,
            _s,
            _toluTagPublicKey,
            _signedMessage
        );

        require(result.isValid, result.reason);

        // Check if key already used (in our own mapping)
        if (toluTagKeyToNFTTokenID[_toluTagPublicKey] != 0) revert KeyAlreadyUsed();

        // Ensure msg.sender matches extracted address
        if (msg.sender != result.signatureAddress) revert SenderMismatch();

        // Determine tokenID based on collection type
        uint256 nftTokenId;

        if (collectionInfo.collectionType == 0) {
            // Random mint
            nftTokenId = _getRandomTokenId();
            if (_exists(nftTokenId)) revert TokenAlreadyMinted();
        } else {
            // Reserved mint
            nftTokenId = validationLogic.getReservedTokenId(_toluTagPublicKey);
            if (nftTokenId == 0) revert NoReservedToken();
            if (_exists(nftTokenId)) revert TokenAlreadyMinted();
        }

        // Record product and mint
        products[nftTokenId] = Product(
            _toluTagPublicKey,
            msg.sender,
            true,
            block.timestamp
        );

        // Update our own mapping
        toluTagKeyToNFTTokenID[_toluTagPublicKey] = nftTokenId;

        _mint(msg.sender, nftTokenId);
        collectionInfo.totalMinted++;

        emit ProductPaired(
            nftTokenId,
            msg.sender,
            _toluTagPublicKey,
            true,
            block.timestamp
        );
    }

    /**
     * @notice Expose the validation logic's validToluTag via the NFT contract
     * @param r The r component of the signature
     * @param s The s component of the signature
     * @param toluTagPublicKey The public key to validate against
     * @param signedMessage The signed message containing timestamp, address, and UUID
     * @return result The ValidationResult struct from the logic
     */
    function validToluTag(
        bytes32 r,
        bytes32 s,
        address toluTagPublicKey,
        string calldata signedMessage
    )
        external
        view
        returns (IHybridToluTagValidationLogic.ValidationResult memory result)
    {
        return validationLogic.validToluTag(r, s, toluTagPublicKey, signedMessage);
    }

    /**
     * @notice Transfer token with signature validation
     * @dev Requires a valid signature from the NFC chip to transfer
     * @param to The address to transfer to
     * @param tokenId The token ID to transfer
     * @param r The r component of the signature
     * @param s The s component of the signature
     * @param toluTagPublicKey The public key of the NFC chip
     * @param signedMessage The signed message from the NFC chip
     */
    function transferWithSignature(
        address to,
        uint256 tokenId,
        bytes32 r,
        bytes32 s,
        address toluTagPublicKey,
        string calldata signedMessage
    ) external nonReentrant {
        // Verify ownership
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        // Verify the NFC chip matches the token
        if (products[tokenId].toluTagPublicKey != toluTagPublicKey) revert WrongNFCChip();

        // Validate signature (this already checks timestamp freshness)
        IHybridToluTagValidationLogic.ValidationResult memory result = validationLogic.validToluTag(
            r,
            s,
            toluTagPublicKey,
            signedMessage
        );
        require(result.isValid, result.reason);

        // Execute the transfer directly
        _transfer(msg.sender, to, tokenId);
    }

    /**
     * @notice Pair a physical product with its NFT
     */
    function pairProduct(
        bytes32 _r,
        bytes32 _s,
        address _toluTagPublicKey,
        string calldata _signedMessage
    ) public nonReentrant override {
        // Validate signature
        IHybridToluTagValidationLogic.ValidationResult memory result = validationLogic.validToluTag(
            _r,
            _s,
            _toluTagPublicKey,
            _signedMessage
        );
        require(result.isValid, result.reason);

        // Get the NFT token ID from our mapping
        uint256 nftTokenId = toluTagKeyToNFTTokenID[_toluTagPublicKey];
        if (nftTokenId == 0) revert InvalidToluTagKey();

        // Load product
        address tokenOwner = ownerOf(nftTokenId);
        Product storage prod = products[nftTokenId];

        // Ownership & paired state check
        if (tokenOwner != msg.sender) revert NotTokenOwner();
        if (prod.paired) revert AlreadyPaired();

        // Verify it matches the stored key
        if (prod.toluTagPublicKey != _toluTagPublicKey) revert KeyMismatch();

        // Mark paired
        prod.paired = true;
        prod.pairedUpdatedAt = block.timestamp;

        emit ProductPaired(
            nftTokenId,
            msg.sender,
            _toluTagPublicKey,
            true,
            block.timestamp
        );
    }


    /**
     * @notice Batch approve ToluTag public keys on the validation logic
     * @dev Only the NFT contract owner can call this.
     *      Internally, validationLogic will enforce that msg.sender == this contract.
     * @param toluTagPublicKeys Array of strings in format "0xpublicKey_0xuuid_tokenID"
     *        tokenID = 0 for random mint collections, tokenID > 0 for reserved collections
     */
    function batchSetToluTagPublicKeys(string[] calldata toluTagPublicKeys) external onlyOwner {
        validationLogic.batchSetToluTagPublicKeys(toluTagPublicKeys);
    }

    /** TODO: Seperate to different funcs
     * @notice Update collection information
     */
    function updateCollectionInfo(
        uint96 _royalties,
        string memory _baseMediaURI,
        uint16 _signatureValidTimeRange
    ) public onlyOwner {
        collectionInfo.currentRoyalties = _royalties;
        collectionInfo.baseMediaURI = _baseMediaURI;

        if (collectionInfo.signatureValidTimeRange != _signatureValidTimeRange) {
            // Also update the time range in validation logic contract
            validationLogic.setSignatureValidTimeRange(_signatureValidTimeRange);
            collectionInfo.signatureValidTimeRange = _signatureValidTimeRange;
        }
        emit CollectionInfoUpdated(_royalties, _baseMediaURI, collectionInfo.signatureValidTimeRange);
    }

    /**
     * @notice Set approved marketplace
     */
    function setApprovedMarketplace(address _marketplaceAddress, bool _approved) external onlyOwner virtual {
        approvedMarketplace[_marketplaceAddress] = _approved;
        emit MarketplaceApprovalUpdated(_marketplaceAddress, _approved);
    }

    /**
     * @notice Get token URI
     * @dev Delegates to metadata contract for both minted and reserved-but-unminted tokens
     *      For collectionType 0 (random): only minted tokens have metadata
     *      For collectionType 1 (reserved): reserved-but-unminted tokens also have metadata
     */
    function tokenURI(uint256 _nftTokenId) public view override returns (string memory) {
        // Delegate to metadata contract - it handles minted vs reserved vs nonexistent
        return metadataContract.tokenURI(_nftTokenId);
    }

    /**
     * @notice Check if token is paired
     */
    function isPaired(uint256 _nftTokenId) external view virtual override returns (bool paired, uint256 pairedUpdatedAt) {
        Product memory product = products[_nftTokenId];
        return (product.paired, product.pairedUpdatedAt);
    }

    /**
     * @notice Get product details
     */
    function getProduct(uint256 _nftTokenId) external view virtual override returns (
        address toluTagPublicKey,
        address owner,
        bool paired,
        uint256 pairedUpdatedAt
    ) {
        Product memory product = products[_nftTokenId];
        return (product.toluTagPublicKey, product.owner, product.paired, product.pairedUpdatedAt);
    }

    /**
     * @notice Royalty info
     */
    function royaltyInfo(uint256 _nftTokenId, uint256 _salePrice)
        external
        view
        virtual
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        royaltyAmount = (_salePrice * collectionInfo.currentRoyalties) / 10000;
        receiver = owner();
    }

    /**
     * @notice Disable approve functionality - only owner can transfer
     * @dev This function will always revert, preventing any approvals
     */
    function approve(address, uint256) public pure override {
        revert ApprovalsDisabled();
    }

    /**
     * @notice Disable setApprovalForAll
     */
    function setApprovalForAll(address, bool) public pure override {
        revert SetApprovalForAllDisabled();
    }

    /**
     * @notice Standard transferFrom is disabled
     * @dev Use transferWithSignature instead
     */
    function transferFrom(address, address, uint256) public pure override {
        revert UseTransferWithSignature();
    }

    /**
     * @notice Standard safeTransferFrom is disabled
     * @dev Use safeTransferWithSignature instead
     */
    function safeTransferFrom(address, address, uint256) public pure override {
        revert UseSafeTransferWithSignature();
    }

    /**
     * @notice Standard safeTransferFrom with data is disabled
     * @dev Use safeTransferWithSignature instead
     */
    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert UseSafeTransferWithSignature();
    }

    /**
     * @notice Override transfer to only allow specific transfer methods
     * @dev Only allows transfers through transferWithSignature or to contract owner
     * E3 - "Transfer not allowed: token must be paired or transfer to contract owner"
     */
    function _transfer(
        address _from,
        address _to,
        uint256 _nftTokenId
    ) internal virtual override {
        Product memory product = products[_nftTokenId];

        // Always allow transfer to contract owner (for recovery)
        // For paired tokens, this is the only allowed direct transfer
        // For unpaired tokens, they can only go to owner anyway
        if (!(product.paired || _to == owner())) revert TransferNotAllowed();

        super._transfer(_from, _to, _nftTokenId);
    }

    /**
     * @notice After token transfer hook
     */
    function _afterTokenTransfer(
        address _from,
        address _to,
        uint256 _firstTokenId,
        uint256 _batchSize
    ) internal virtual override {
        super._afterTokenTransfer(_from, _to, _firstTokenId, _batchSize);

        // Only update when it's a transfer (not minting)
        if (_from != address(0)) {
            for (uint256 i = 0; i < _batchSize; i++) {
                uint256 tokenId = _firstTokenId + i;

                if (_exists(tokenId)) {
                    products[tokenId].paired = false;
                    products[tokenId].owner = _to;
                    products[tokenId].pairedUpdatedAt = block.timestamp;
                }

                emit ProductPaired(
                    tokenId,
                    _to,
                    products[tokenId].toluTagPublicKey,
                    false,
                    block.timestamp
                );
            }
        }
    }

    /**
     * @notice Pick random token ID (only used for collectionType == 0)
     */
    function _getRandomTokenId() internal returns (uint256) {
        if (_remainingTokens == 0) revert NoTokensLeft();

        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    msg.sender,
                    _remainingTokens
                )
            )
        ) % _remainingTokens;

        uint256 tokenId = _tokenMatrix[rand] != 0
            ? _tokenMatrix[rand]
            : rand;

        uint256 last = _tokenMatrix[_remainingTokens - 1] != 0
            ? _tokenMatrix[_remainingTokens - 1]
            : (_remainingTokens - 1);

        _tokenMatrix[rand] = last;
        _remainingTokens--;

        return tokenId + 1;
    }

    /**
     * @notice Support interface
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }
}
