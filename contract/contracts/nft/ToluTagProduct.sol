// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./HybridToluTagNFT.sol";

/**
 * @title ToluTagProduct
 * @notice Concrete, deployable NFT collection built on the abstract HybridToluTagNFT.
 * @dev HybridToluTagNFT is abstract; this thin subclass just forwards the constructor
 *      so the collection can actually be deployed. Add collection-specific overrides here
 *      if you need them later.
 */
contract ToluTagProduct is HybridToluTagNFT {
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
        HybridToluTagNFT(
            _validationLogic,
            _metadataContract,
            _productName,
            _maxSupply,
            _royalties,
            _baseMediaURI,
            _secp256k1ToluTagObjectID,
            _collectionType
        )
    {}
}
