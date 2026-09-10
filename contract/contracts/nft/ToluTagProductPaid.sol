// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./HybridToluTagNFTPaid.sol";

/**
 * @title ToluTagProductPaid
 * @notice Concrete, deployable paid-sale NFT collection built on the abstract
 *         {HybridToluTagNFTPaid}.
 * @dev Like {ToluTagProduct} for the free variant, this thin subclass just forwards
 *      the constructor so the paid collection can actually be deployed. Add
 *      collection-specific overrides here if you need them later.
 */
contract ToluTagProductPaid is HybridToluTagNFTPaid {
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
        HybridToluTagNFTPaid(
            _validationLogic,
            _metadataContract,
            _productName,
            _maxSupply,
            _royalties,
            _baseMediaURI,
            _secp256k1ToluTagObjectID,
            _collectionType,
            _usdcToken,
            _priceNative,
            _priceUsdc,
            _maxPerWallet
        )
    {}
}
