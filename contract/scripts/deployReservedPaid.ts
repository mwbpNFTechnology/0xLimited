import { ethers, network } from "hardhat";

// ─────────────────────────────────────────────────────────────────────────────
// Reserved PAID collection — same as deployReserved.ts, but buyers must pre-pay
// before they can mint (see ToluTagProductPaid / HybridToluTagNFTPaid).
// The physical items differ from one another, so each one gets its own token ID
// and its own media folder. Traits are NOT stored on-chain: each token's folder
// carries an attributes.json next to its media.
//
//   npm run deploy:reserved:paid:sepolia
//
// EDIT THESE before deploying.
// ─────────────────────────────────────────────────────────────────────────────
const SIGNATURE_VALID_TIME_RANGE = 300; // seconds a tag signature stays valid (uint16, max 65535)
const PRODUCT_NAME = ""; // ERC-721 collection name
const MAX_SUPPLY = 5000; // token IDs run 1…MAX_SUPPLY
const ROYALTIES = 500; // royalty basis points (500 = 5%)
const SECP256K1_OBJECT_ID = "0x00002222"; // bytes4 SE05x object ID for the tag key

// The collection's media root. Every token reads as <base><tokenId>/ — keep the
// trailing "/". Use the ipfs:// form, not a gateway URL: the CID is a hash of the
// whole folder tree, which is what stops a token's traits from changing silently.
const BASE_MEDIA_URI = "ipfs:///";

// ── Paid-sale configuration ──────────────────────────────────────────────────
// The buyer chooses ETH or USDC at purchase time. Set a price to "0" to switch
// that currency off (e.g. PRICE_USDC "0" = ETH-only).
//
// USDC_TOKEN: the USDC contract on the network you deploy to. USDC has 6 decimals.
//   Sepolia (Circle):  0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
//   Base mainnet:      0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
//   Ethereum mainnet:  0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
//   Leave ethers.ZeroAddress if you don't take USDC.
// PRICE_ETH:  price for ONE unit in ETH, as a string ("0" disables ETH).
// PRICE_USDC: price for ONE unit in USDC, as a string ("0" disables USDC).
// MAX_PER_WALLET: cap on how many units one wallet can buy; 0 = unlimited.
const USDC_TOKEN = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
const PRICE_ETH = "0.01";
const PRICE_USDC = "2";
const MAX_PER_WALLET = 0;

// Optional: assign ToluTags to their token IDs in the same run. Each entry reserves
// one token for one physical item. Leave empty to deploy only and register the tags
// later from the Manage page.
const TOLU_TAGS: Array<{ tagKey: string; uuid: string; tokenId: number }> = [
  // { tagKey: "0x…", uuid: "0x…", tokenId: 1 },
];
// ─────────────────────────────────────────────────────────────────────────────

const COLLECTION_TYPE = 1; // reserved — this script's whole point; don't change it
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const USDC_DECIMALS = 6;
const PRICE_NATIVE = ethers.parseEther(PRICE_ETH);
const PRICE_USDC_UNITS = ethers.parseUnits(PRICE_USDC, USDC_DECIMALS);

/**
 * Check what the contracts will check, before any gas is spent. Reserved token IDs
 * must be 1…MAX_SUPPLY and unique — HybridToluTagValidationLogic reverts
 * TokenIdExceedsMaxSupply / TokenIdAlreadyReserved / ReservedTokenIdRequired.
 */
function validateInputs() {
  if (!BASE_MEDIA_URI.endsWith("/")) {
    throw new Error('BASE_MEDIA_URI must end in "/" — the token id is appended to it as a folder.');
  }
  if (TOLU_TAGS.length > MAX_SUPPLY) {
    throw new Error(`${TOLU_TAGS.length} tags for a collection of ${MAX_SUPPLY}. Raise MAX_SUPPLY or drop tags.`);
  }

  const seen = new Set<number>();
  for (const { tagKey, uuid, tokenId } of TOLU_TAGS) {
    if (!ADDRESS.test(tagKey)) throw new Error(`Not a tag public key address: "${tagKey}"`);
    if (!ADDRESS.test(uuid)) throw new Error(`Not a UUID address: "${uuid}"`);
    if (!Number.isInteger(tokenId) || tokenId < 1 || tokenId > MAX_SUPPLY) {
      throw new Error(`Token ID ${tokenId} is out of range — reserved IDs run 1…${MAX_SUPPLY}.`);
    }
    if (seen.has(tokenId)) throw new Error(`Token ID ${tokenId} is assigned to two tags.`);
    seen.add(tokenId);
  }
}

/** Check the paid-sale settings the contract will enforce, before any gas is spent. */
function validateSale() {
  if (PRICE_NATIVE === 0n && PRICE_USDC_UNITS === 0n) {
    throw new Error("Both prices are 0 — set PRICE_ETH and/or PRICE_USDC so at least one currency is sellable.");
  }
  if (PRICE_USDC_UNITS > 0n && !ADDRESS.test(USDC_TOKEN)) {
    throw new Error(`PRICE_USDC is set but USDC_TOKEN is not a valid address for this network: "${USDC_TOKEN}"`);
  }
  if (MAX_PER_WALLET < 0 || !Number.isInteger(MAX_PER_WALLET)) {
    throw new Error(`MAX_PER_WALLET must be a non-negative integer (0 = unlimited): ${MAX_PER_WALLET}`);
  }
  if (MAX_PER_WALLET > MAX_SUPPLY) {
    throw new Error(`MAX_PER_WALLET (${MAX_PER_WALLET}) cannot exceed MAX_SUPPLY (${MAX_SUPPLY}). Use 0 for unlimited.`);
  }
}

async function main() {
  validateInputs();
  validateSale();

  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);

  console.log(`Network:  ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance:  ${ethers.formatEther(balance)} ETH\n`);

  if (balance === 0n) {
    throw new Error("Deployer has 0 ETH. Fund it with test ETH first.");
  }
  if (!BASE_MEDIA_URI.startsWith("ipfs://")) {
    console.log("! BASE_MEDIA_URI is not an ipfs:// URI. Traits served over a gateway URL are\n" +
      "  only as trustworthy as the server behind it — an ipfs:// CID cannot change silently.\n");
  }

  console.log("Paid sale:");
  console.log(`  ETH price/unit:  ${PRICE_NATIVE === 0n ? "disabled" : `${PRICE_ETH} ETH (${PRICE_NATIVE} wei)`}`);
  console.log(`  USDC price/unit: ${PRICE_USDC_UNITS === 0n ? "disabled" : `${PRICE_USDC} USDC (${PRICE_USDC_UNITS} base units)`}`);
  console.log(`  USDC token:      ${PRICE_USDC_UNITS === 0n ? "n/a" : USDC_TOKEN}`);
  console.log(`  Max per wallet:  ${MAX_PER_WALLET === 0 ? "unlimited" : MAX_PER_WALLET}`);
  console.log(`  Sale starts CLOSED — open it later with setSaleActive(true).\n`);

  // 1. Validation logic (must exist before the NFT constructor runs).
  const validation = await ethers.deployContract("HybridToluTagValidationLogic", [SIGNATURE_VALID_TIME_RANGE]);
  await validation.waitForDeployment();
  const validationAddr = await validation.getAddress();
  console.log(`1/3  HybridToluTagValidationLogic  -> ${validationAddr}`);

  // 2. Metadata (needs the validation logic address).
  const metadata = await ethers.deployContract("HybridToluTagMetadataReserved", [validationAddr]);
  await metadata.waitForDeployment();
  const metadataAddr = await metadata.getAddress();
  console.log(`2/3  HybridToluTagMetadataReserved -> ${metadataAddr}`);

  // 3. NFT (deployed last — its constructor binds the other two to itself).
  const nftArgs = [
    validationAddr,
    metadataAddr,
    PRODUCT_NAME,
    MAX_SUPPLY,
    ROYALTIES,
    BASE_MEDIA_URI,
    SECP256K1_OBJECT_ID,
    COLLECTION_TYPE,
    USDC_TOKEN,
    PRICE_NATIVE,
    PRICE_USDC_UNITS,
    MAX_PER_WALLET,
  ] as const;
  const nft = await ethers.deployContract("ToluTagProductPaid", [...nftArgs]);
  await nft.waitForDeployment();
  const nftAddr = await nft.getAddress();
  console.log(`3/3  ToluTagProductPaid            -> ${nftAddr}\n`);

  // 4. Reserve token IDs for the tags, if any were listed. Goes through the NFT,
  //    which is the only caller the validation logic accepts.
  if (TOLU_TAGS.length > 0) {
    const phrases = TOLU_TAGS.map((t) => `${t.tagKey}_${t.uuid}_${t.tokenId}`);
    const tx = await nft.batchSetToluTagPublicKeys(phrases);
    await tx.wait();
    console.log(`Reserved ${phrases.length} token${phrases.length === 1 ? "" : "s"}:`);
    for (const t of TOLU_TAGS) {
      console.log(`  #${t.tokenId}  ${t.tagKey}`);
    }
    console.log();
  } else {
    console.log("No ToluTags registered yet — assign them from Manage before minting.\n");
  }

  console.log("Deployment complete. Save these addresses.");
  console.log("Paid collection: open the sale with setSaleActive(true) when you are ready to sell.\n");

  // What has to exist on IPFS for the metadata to resolve.
  console.log(`Upload one folder per token under ${BASE_MEDIA_URI}`);
  console.log(`  ${BASE_MEDIA_URI}1/${await metadata.ATTRIBUTES_FILE()}   (its media beside it)`);
  console.log(`  ${BASE_MEDIA_URI}2/${await metadata.ATTRIBUTES_FILE()}`);
  console.log(`  …up to ${MAX_SUPPLY}`);
  console.log('Each file: {"attributes":[{"trait_type":"Colour","value":"Red"}]}\n');

  console.log("To verify on Etherscan, run (--contract keeps the upload to that\n" +
    "contract's own sources, so unrelated ones aren't published with it):");
  console.log(
    `  npx hardhat verify --network ${network.name} \\\n` +
      `    --contract contracts/validation/HybridToluTagValidationLogic.sol:HybridToluTagValidationLogic \\\n` +
      `    ${validationAddr} ${SIGNATURE_VALID_TIME_RANGE}`
  );
  console.log(
    `  npx hardhat verify --network ${network.name} \\\n` +
      `    --contract contracts/metadata/HybridToluTagMetadataReserved.sol:HybridToluTagMetadataReserved \\\n` +
      `    ${metadataAddr} ${validationAddr}`
  );
  console.log(
    `  npx hardhat verify --network ${network.name} \\\n` +
      `    --contract contracts/nft/ToluTagProductPaid.sol:ToluTagProductPaid \\\n` +
      `    ${nftAddr} \\\n` +
      `    ${validationAddr} ${metadataAddr} "${PRODUCT_NAME}" ${MAX_SUPPLY} ${ROYALTIES} \\\n` +
      `    "${BASE_MEDIA_URI}" ${SECP256K1_OBJECT_ID} ${COLLECTION_TYPE} \\\n` +
      `    ${USDC_TOKEN} ${PRICE_NATIVE} ${PRICE_USDC_UNITS} ${MAX_PER_WALLET}`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
