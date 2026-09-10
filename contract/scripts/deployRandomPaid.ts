import { ethers, network } from "hardhat";

// ─────────────────────────────────────────────────────────────────────────────
// Random-mint PAID collection — same as deployRandom.ts, but buyers must pre-pay
// before they can mint (see ToluTagProductPaid / HybridToluTagNFTPaid).
// Every product in the drop is the same item, so the whole collection shares one
// set of custom traits. The token ID is drawn at mint, which is why traits live
// on the collection and not on a token.
//
//   npm run deploy:random:paid:sepolia
//
// EDIT THESE before deploying.
// ─────────────────────────────────────────────────────────────────────────────
const SIGNATURE_VALID_TIME_RANGE = 300; // seconds a tag signature stays valid (uint16, max 65535)
const PRODUCT_NAME = ""; // ERC-721 collection name
const MAX_SUPPLY = 25; // maximum number of tokens
const ROYALTIES = 500; // royalty basis points (500 = 5%)
const BASE_MEDIA_URI = "ipfs:///"; // media folder for the whole drop; served verbatim as tokenMediaURL
const SECP256K1_OBJECT_ID = "0x00002222"; // bytes4 SE05x object ID for the tag key

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
const PRICE_ETH = "0.001";
const PRICE_USDC = "2";
const MAX_PER_WALLET = 2;

// Custom traits rendered on top of the eight default fields, on every token.
// Leave the array empty to deploy with the defaults only — they can be set later
// with setCollectionAttributes() by whoever owns the collection at the time.
const ATTRIBUTES: Array<{ traitType: string; value: string }> = [
  { traitType: "Signed by", value: "Joe Hahn" },
  { traitType: "Tour", value: "2026" },
  { traitType: "Material", value: "Cotton" },
];
// ─────────────────────────────────────────────────────────────────────────────

const COLLECTION_TYPE = 0; // random mint — this script's whole point; don't change it
const MAX_ATTRIBUTES = 32; // mirrors HybridToluTagMetadataRandom.MAX_ATTRIBUTES
const MAX_ATTRIBUTE_CHARS = 200;
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const USDC_DECIMALS = 6;
const PRICE_NATIVE = ethers.parseEther(PRICE_ETH);
const PRICE_USDC_UNITS = ethers.parseUnits(PRICE_USDC, USDC_DECIMALS);

/**
 * Apply the contract's own rules before spending gas: the metadata JSON is built
 * by concatenation, so a quote, backslash or control character would corrupt the
 * document and the contract rejects it. Failing here gives a readable message
 * instead of a bare revert.
 */
function validateAttributes() {
  if (ATTRIBUTES.length > MAX_ATTRIBUTES) {
    throw new Error(`Too many attributes: ${ATTRIBUTES.length}, the contract allows ${MAX_ATTRIBUTES}.`);
  }
  for (const { traitType, value } of ATTRIBUTES) {
    for (const [field, text] of [["traitType", traitType], ["value", value]] as const) {
      if (text.length === 0 || text.length > MAX_ATTRIBUTE_CHARS) {
        throw new Error(`Attribute ${field} must be 1-${MAX_ATTRIBUTE_CHARS} characters: "${text}"`);
      }
      // eslint-disable-next-line no-control-regex
      if (/["\\]|[\x00-\x1F\x7F]/.test(text)) {
        throw new Error(`Attribute ${field} may not contain a quote, backslash or control character: "${text}"`);
      }
    }
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
  validateAttributes();
  validateSale();
  if (!BASE_MEDIA_URI.endsWith("/")) {
    throw new Error('BASE_MEDIA_URI must end in "/" — readers append the file name to it.');
  }

  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);

  console.log(`Network:  ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance:  ${ethers.formatEther(balance)} ETH\n`);

  if (balance === 0n) {
    throw new Error("Deployer has 0 ETH. Fund it with test ETH first.");
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
  console.log(`1/3  HybridToluTagValidationLogic -> ${validationAddr}`);

  // 2. Metadata (needs the validation logic address).
  // Traits go in here rather than in a follow-up transaction: the setter is gated on
  // the NFT's owner(), which does not exist yet at this point in the deploy.
  const metadata = await ethers.deployContract("HybridToluTagMetadataRandom", [validationAddr, ATTRIBUTES]);
  await metadata.waitForDeployment();
  const metadataAddr = await metadata.getAddress();
  console.log(`2/3  HybridToluTagMetadataRandom  -> ${metadataAddr}`);

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
  console.log(`3/3  ToluTagProductPaid           -> ${nftAddr}\n`);

  // Traits were written by the metadata deploy above — read them back to confirm.
  const stored = await metadata.collectionAttributes();
  if (stored.length > 0) {
    console.log(`Attributes (${stored.length}), set during the deploy:`);
    for (const attribute of stored) {
      console.log(`  ${attribute.traitType}: ${attribute.value}`);
    }
    console.log();
  } else {
    console.log("No attributes set — the collection renders the default fields only.\n");
  }

  console.log("Deployment complete. Save these addresses.");
  console.log("Random collection: tokens have no metadata until they are minted.");
  console.log("Paid collection: open the sale with setSaleActive(true) when you are ready to sell.\n");

  console.log("To verify on Etherscan, run (--contract keeps the upload to that\n" +
    "contract's own sources, so unrelated ones aren't published with it):");
  console.log(
    `  npx hardhat verify --network ${network.name} \\\n` +
      `    --contract contracts/validation/HybridToluTagValidationLogic.sol:HybridToluTagValidationLogic \\\n` +
      `    ${validationAddr} ${SIGNATURE_VALID_TIME_RANGE}`
  );
  console.log(
    `  npx hardhat verify --network ${network.name} \\\n` +
      `    --contract contracts/metadata/HybridToluTagMetadataRandom.sol:HybridToluTagMetadataRandom \\\n` +
      `    ${metadataAddr} ${validationAddr} \\\n` +
      `    # the attributes array is a constructor arg too — use --constructor-args for it`
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
