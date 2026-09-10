import { ethers, network } from "hardhat";

// ─────────────────────────────────────────────────────────────────────────────
// Random-mint collection — every product in the drop is the same item, so the
// whole collection shares one set of custom traits. The token ID is drawn at
// mint, which is why traits live on the collection and not on a token.
//
//   npm run deploy:random:sepolia
//
// EDIT THESE before deploying.
// ─────────────────────────────────────────────────────────────────────────────
const SIGNATURE_VALID_TIME_RANGE = 300; // seconds a tag signature stays valid (uint16, max 65535)
const PRODUCT_NAME = ""; // ERC-721 collection name
const MAX_SUPPLY = 1; // maximum number of tokens
const ROYALTIES = 500; // royalty basis points (500 = 5%)
const BASE_MEDIA_URI = "ipfs:///"; // media folder for the whole drop; served verbatim as tokenMediaURL
const SECP256K1_OBJECT_ID = "0x00002222"; // bytes4 SE05x object ID for the tag key

// Custom traits rendered on top of the eight default fields, on every token.
// Leave the array empty to deploy with the defaults only — they can be set later
// with setCollectionAttributes() by whoever owns the collection at the time.
const ATTRIBUTES: Array<{ traitType: string; value: string }> = [
  { traitType: "att1", value: "1" }
];
// ─────────────────────────────────────────────────────────────────────────────

const COLLECTION_TYPE = 0; // random mint — this script's whole point; don't change it
const MAX_ATTRIBUTES = 32; // mirrors HybridToluTagMetadataRandom.MAX_ATTRIBUTES
const MAX_ATTRIBUTE_CHARS = 200;

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

async function main() {
  validateAttributes();
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
  ] as const;
  const nft = await ethers.deployContract("ToluTagProduct", [...nftArgs]);
  await nft.waitForDeployment();
  const nftAddr = await nft.getAddress();
  console.log(`3/3  ToluTagProduct               -> ${nftAddr}\n`);

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
  console.log("Random collection: tokens have no metadata until they are minted.\n");

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
      `    --contract contracts/nft/ToluTagProduct.sol:ToluTagProduct \\\n` +
      `    ${nftAddr} \\\n` +
      `    ${validationAddr} ${metadataAddr} "${PRODUCT_NAME}" ${MAX_SUPPLY} ${ROYALTIES} \\\n` +
      `    "${BASE_MEDIA_URI}" ${SECP256K1_OBJECT_ID} ${COLLECTION_TYPE}`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
