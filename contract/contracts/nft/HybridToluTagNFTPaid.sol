// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IHybridToluTagValidationLogic.sol";
import "../interfaces/IHybridToluTagMetadata.sol";
import "../errors/ToluTagErrors.sol";

/// @notice Interface for external access to pairing functionality
interface IHybridToluTagPaidBase {
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
 * @title HybridToluTagNFTPaid
 * @notice Paid-sale sibling of HybridToluTagNFT. It carries the full toluTag NFT
 *         behaviour (random / reserved minting, NFC-signature-gated transfers,
 *         product pairing) and adds a paywall in front of minting.
 * @dev This contract is a deliberate standalone copy of HybridToluTagNFT rather
 *      than a subclass of it. The two form disjoint Etherscan verification bundles
 *      (see scripts/genVerifyInputs.ts): verifying a free collection must not
 *      publish the paid sources on its Etherscan page, and vice versa, or the
 *      already-verified address can never be re-verified. Keep this file free of
 *      any import of HybridToluTagNFT.sol / ToluTagProduct.sol.
 *
 *      The sale is a two-step flow:
 *        1. purchase(quantity) — the buyer pays (native coin or an ERC-20) and
 *           earns an allowance of `quantity` mints.
 *        2. mint(...) — the usual NFC-signature-gated mint consumes one unit of
 *           that allowance. Minting is gated in {_mint}, the single mint path, so
 *           no wallet can mint without having paid.
 *
 *      Caps enforced at purchase time:
 *        - per-wallet cap (`maxPerWallet`, 0 = unlimited)
 *        - global cap: total units ever sold can never exceed `maxSupply`, so a
 *          buyer can never pay for a token that could not be minted.
 */
abstract contract HybridToluTagNFTPaid is ERC721, Ownable, IERC2981, ReentrancyGuard, IHybridToluTagPaidBase {
    using SafeERC20 for IERC20;

    /// @notice How a buyer pays for a purchase.
    enum PayWith { Native, USDC }

    event ProductPaired(uint256 indexed nftTokenId, address indexed owner, address toluTagPublicKey, bool isPaired, uint256 pairedAt);
    event MarketplaceApprovalUpdated(address indexed marketplace, bool approved);
    event CollectionInfoUpdated(uint96 royalties, string baseMediaURI, uint16 signatureValidTimeRange);

    event PaymentConfigUpdated(address usdcToken, uint256 priceNative, uint256 priceUsdc);
    event MaxPerWalletUpdated(uint256 maxPerWallet);
    event SaleStatusUpdated(bool active);
    event Purchased(address indexed buyer, uint256 quantity, PayWith method, uint256 amountPaid);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);

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

    // ── Paid-sale state ──

    /// @notice USDC token accepted for payment. Set at deploy (network-specific),
    ///         updatable via setPaymentConfig in case it was set wrong.
    address public usdcToken;

    /// @notice Price of one unit (one future mint) in native coin (wei). 0 disables native.
    uint256 public priceNative;

    /// @notice Price of one unit in USDC base units (USDC has 6 decimals). 0 disables USDC.
    uint256 public priceUsdc;

    /// @notice Max units a single wallet may ever purchase. 0 = no cap.
    uint256 public maxPerWallet;

    /// @notice Whether the sale is currently open. Starts closed.
    bool public saleActive;

    /// @notice Total units purchased across all wallets. Capped at maxSupply.
    uint256 public totalPaid;

    /// @notice Units a wallet has paid for.
    mapping(address => uint256) public paidQuantity;

    /// @notice Units a wallet has already minted (consumed from its allowance).
    mapping(address => uint256) public mintedQuantity;

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
     * @param _usdcToken USDC contract on the target network (address(0) if USDC not used)
     * @param _priceNative Price of one unit in native coin (wei); 0 disables native payment
     * @param _priceUsdc Price of one unit in USDC base units (6 decimals); 0 disables USDC
     * @param _maxPerWallet Per-wallet purchase cap; 0 for unlimited
     */
    constructor(
        address _validationLogic,
        address _metadataContract,
        string memory _productName,
        uint256 _maxSupply,
        uint96 _royalties,
        string memory _baseMediaURI,
        bytes4 _secp256k1ToluTagObjectID,
        uint8 _collectionType,
        address _usdcToken,
        uint256 _priceNative,
        uint256 _priceUsdc,
        uint256 _maxPerWallet
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

        // Paid-sale config. The sale starts closed; the owner opens it explicitly.
        // A per-wallet cap above the total supply is meaningless (0 = unlimited).
        if (_maxPerWallet != 0 && _maxPerWallet > _maxSupply) revert MaxPerWalletExceedsSupply();
        saleActive = false;
        usdcToken = _usdcToken;
        priceNative = _priceNative;
        priceUsdc = _priceUsdc;
        maxPerWallet = _maxPerWallet;

        emit PaymentConfigUpdated(_usdcToken, _priceNative, _priceUsdc);
        emit MaxPerWalletUpdated(_maxPerWallet);
    }

    // ─────────────────────────────  Paid sale  ──────────────────────────────

    /**
     * @notice Pay for `quantity` future mints, choosing the currency.
     * @dev Native (method = PayWith.Native): send exactly quote() as msg.value.
     *      USDC   (method = PayWith.USDC):   approve this contract for quote() on
     *      the USDC token first; the contract pulls it via transferFrom, and no
     *      native coin may be sent. A currency whose price is 0 is not accepted.
     * @param quantity Number of units to buy.
     * @param method Native or USDC.
     */
    function purchase(uint256 quantity, PayWith method) external payable nonReentrant {
        if (!saleActive) revert SaleNotActive();
        if (quantity == 0) revert InvalidQuantity();

        // (4) Never let the collection sell more units than it can ever mint.
        if (totalPaid + quantity > collectionInfo.maxSupply) revert ExceedsMaxSupply();

        // (3) Per-wallet cap (0 = unlimited).
        uint256 newWalletTotal = paidQuantity[msg.sender] + quantity;
        if (maxPerWallet != 0 && newWalletTotal > maxPerWallet) revert ExceedsMaxPerWallet();

        // (1) Collect payment in the chosen currency. A 0 unit price means that
        //     currency is switched off, so quote() reverts PriceNotSet.
        uint256 cost = quote(quantity, method);
        if (method == PayWith.Native) {
            if (msg.value != cost) revert IncorrectNativeAmount();
        } else {
            if (msg.value != 0) revert UnexpectedNativeCoin();
            if (usdcToken == address(0)) revert InvalidToken();
            IERC20(usdcToken).safeTransferFrom(msg.sender, address(this), cost);
        }

        paidQuantity[msg.sender] = newWalletTotal;
        totalPaid += quantity;

        emit Purchased(msg.sender, quantity, method, cost);
    }

    /**
     * @notice Total cost of `quantity` units in the given currency.
     * @dev Reverts PriceNotSet if that currency is disabled (its unit price is 0).
     *      Frontends use this to know the msg.value (Native) or approve amount (USDC).
     */
    function quote(uint256 quantity, PayWith method) public view returns (uint256) {
        uint256 unitPrice = method == PayWith.Native ? priceNative : priceUsdc;
        if (unitPrice == 0) revert PriceNotSet();
        return unitPrice * quantity;
    }

    /**
     * @notice Remaining mints a buyer has paid for but not yet minted.
     */
    function remainingAllowance(address buyer) public view returns (uint256) {
        return paidQuantity[buyer] - mintedQuantity[buyer];
    }

    /**
     * @notice Whether `buyer` currently has a paid allowance left to mint.
     */
    function canMint(address buyer) external view returns (bool) {
        return remainingAllowance(buyer) > 0;
    }

    /**
     * @notice Update the USDC token and both unit prices in one call.
     * @dev Set a price to 0 to switch that currency off. The USDC address is here
     *      too so a wrong network address supplied at deploy can be corrected.
     * @param _usdcToken USDC contract on this network (address(0) if USDC unused).
     * @param _priceNative Price of one unit in wei; 0 disables native.
     * @param _priceUsdc Price of one unit in USDC base units (6 decimals); 0 disables USDC.
     */
    function setPaymentConfig(
        address _usdcToken,
        uint256 _priceNative,
        uint256 _priceUsdc
    ) external onlyOwner {
        usdcToken = _usdcToken;
        priceNative = _priceNative;
        priceUsdc = _priceUsdc;
        emit PaymentConfigUpdated(_usdcToken, _priceNative, _priceUsdc);
    }

    /**
     * @notice Set the per-wallet purchase cap (0 = unlimited).
     * @dev The cap may not exceed the collection's total supply.
     */
    function setMaxPerWallet(uint256 _maxPerWallet) external onlyOwner {
        if (_maxPerWallet != 0 && _maxPerWallet > collectionInfo.maxSupply) revert MaxPerWalletExceedsSupply();
        maxPerWallet = _maxPerWallet;
        emit MaxPerWalletUpdated(_maxPerWallet);
    }

    /**
     * @notice Open or close the sale.
     */
    function setSaleActive(bool _active) external onlyOwner {
        saleActive = _active;
        emit SaleStatusUpdated(_active);
    }

    /**
     * @notice Withdraw collected native coin to `to`.
     */
    function withdrawNative(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();

        (bool ok, ) = payable(to).call{value: balance}("");
        if (!ok) revert NativeTransferFailed();

        emit Withdrawn(to, address(0), balance);
    }

    /**
     * @notice Withdraw the full balance of an ERC-20 held by the contract to `to`.
     */
    function withdrawToken(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0)) revert InvalidToken();
        if (to == address(0)) revert InvalidRecipient();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToWithdraw();

        IERC20(token).safeTransfer(to, balance);

        emit Withdrawn(to, token, balance);
    }

    // ─────────────────────────────  Minting  ────────────────────────────────

    /**
     * @notice Mint a new token
     * @dev collectionType 0: random tokenID assignment
     *      collectionType 1: reserved tokenID from key registration
     *      Requires the caller to hold a paid allowance (see {purchase}).
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
     * @notice Gate every mint behind a paid allowance.
     * @dev {mint} is the only path that calls this, and it does so only after
     *      verifying that msg.sender is the NFC signer, so `to` is always the
     *      paying wallet. This is the single enforcement point for
     *      "(2) only wallets that paid can mint".
     */
    function _mint(address to, uint256 tokenId) internal virtual override {
        if (mintedQuantity[to] >= paidQuantity[to]) revert NoPaidAllowance();
        mintedQuantity[to] += 1;
        super._mint(to, tokenId);
    }

    /**
     * @notice Expose the validation logic's validToluTag via the NFT contract
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
     */
    function batchSetToluTagPublicKeys(string[] calldata toluTagPublicKeys) external onlyOwner {
        validationLogic.batchSetToluTagPublicKeys(toluTagPublicKeys);
    }

    /**
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
     */
    function transferFrom(address, address, uint256) public pure override {
        revert UseTransferWithSignature();
    }

    /**
     * @notice Standard safeTransferFrom is disabled
     */
    function safeTransferFrom(address, address, uint256) public pure override {
        revert UseSafeTransferWithSignature();
    }

    /**
     * @notice Standard safeTransferFrom with data is disabled
     */
    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert UseSafeTransferWithSignature();
    }

    /**
     * @notice Override transfer to only allow specific transfer methods
     */
    function _transfer(
        address _from,
        address _to,
        uint256 _nftTokenId
    ) internal virtual override {
        Product memory product = products[_nftTokenId];

        // Always allow transfer to contract owner (for recovery)
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
