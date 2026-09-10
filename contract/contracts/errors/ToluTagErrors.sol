// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * ToluTagErrors — shared custom errors for the ToluTag contracts.
 *
 * Custom errors compile to a 4-byte selector instead of embedding the full
 * revert string in bytecode, so they meaningfully shrink deployed size.
 * Declaring them file-level and importing costs nothing where unused — an
 * error only adds code at the `revert` site that uses it.
 */

// ── Shared (NFT / metadata / validation) ──
error InvalidValidationLogic();
error InvalidCollectionType();
error InvalidMetadataContract();
error InvalidNFTContract();
error NotCollectionOwner();
error InvalidAttribute();
error TooManyAttributes();
error NFTContractAlreadySet();
error NFTContractNotSet();
error OnlyNFTContract();
error TokenDoesNotExist();
error NotReservedCollection();

// ── NFT: mint / transfer / pair ──
error MaxSupplyReached();
error AllApprovedKeysUsed();
error KeyAlreadyUsed();
error SenderMismatch();
error TokenAlreadyMinted();
error NoReservedToken();
error NotTokenOwner();
error WrongNFCChip();
error InvalidToluTagKey();
error AlreadyPaired();
error KeyMismatch();
error ApprovalsDisabled();
error SetApprovalForAllDisabled();
error UseTransferWithSignature();
error UseSafeTransferWithSignature();
error TransferNotAllowed();
error NoTokensLeft();

// ── Validation logic: key registration / parsing ──
error KeyAlreadyApproved();
error ExceedsMaxSupply();
error RandomTokenIdMustBeZero();
error ReservedTokenIdRequired();
error TokenIdExceedsMaxSupply();
error TokenIdAlreadyReserved();
error InvalidMessageFormat();
error InvalidNumberChar();
error InvalidHexAddress();
error InvalidHexChar();

// ── Paid variant: sale / withdrawal ──
error SaleNotActive();
error InvalidQuantity();
error PriceNotSet();
error ExceedsMaxPerWallet();
error MaxPerWalletExceedsSupply();
error IncorrectNativeAmount();
error UnexpectedNativeCoin();
error InvalidRecipient();
error NothingToWithdraw();
error NativeTransferFailed();
error InvalidToken();
error NoPaidAllowance();
