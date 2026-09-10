import { ethers, network } from "hardhat";

// ─────────────────────────────────────────────────────────────────────────────
// Collection parameters — EDIT THESE before deploying.
// npm run deploy:sepolia
// ─────────────────────────────────────────────────────────────────────────────
const SIGNATURE_VALID_TIME_RANGE = 300; // seconds a tag signature stays valid (uint16, max 65535)
const PRODUCT_NAME = ""; // ERC-721 collection name
const MAX_SUPPLY = 1; // maximum number of tokens
const ROYALTIES = 500; // royalty basis points (500 = 5%)
const BASE_MEDIA_URI = "ipfs:///"; // token media base URL
const SECP256K1_OBJECT_ID = "0x00002222"; // bytes4 SE05x object ID for the tag key
const COLLECTION_TYPE = 0; // 0 = random mint, 1 = reserved mint
// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  const [deployer] = await ethers.getSigners();
  const balance = await ethers.provider.getBalance(deployer.address);

  console.log(`Network:  ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Balance:  ${ethers.formatEther(balance)} ETH\n`);

  if (balance === 0n) {
    throw new Error("Deployer has 0 ETH. Fund it with Sepolia test ETH first.");
  }

  // 1. Validation logic (must exist before the NFT constructor runs).
  const validation = await ethers.deployContract("HybridToluTagValidationLogic", [
    SIGNATURE_VALID_TIME_RANGE,
  ]);
  await validation.waitForDeployment();
  const validationAddr = await validation.getAddress();
  console.log(`1/3  HybridToluTagValidationLogic -> ${validationAddr}`);

  // 2. Metadata (needs the validation logic address).
  const metadata = await ethers.deployContract("HybridToluTagMetadataRandom", [validationAddr, []]);
  await metadata.waitForDeployment();
  const metadataAddr = await metadata.getAddress();
  console.log(`2/3  HybridToluTagMetadataRandom  -> ${metadataAddr}`);

  // 3. NFT (deployed last — its constructor calls setNftContract() on the other two).
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

  console.log("Deployment complete. Save these addresses.\n");
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
      `    ${metadataAddr} ${validationAddr}`
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
