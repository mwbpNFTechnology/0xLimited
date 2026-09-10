/**
 * Regenerate the browser-side contract bundle used by the 0xLimited WordPress
 * plugin (wp-content/plugins/oxlimited-web3/assets/oxcontracts.js) — the ABIs and
 * creation bytecode the deploy wizard sends through the wallet.
 *
 *   npm run web:contracts
 *
 * Run it together with `npm run verify:inputs` whenever the Solidity changes:
 * the bundle decides what gets deployed and the inputs decide what gets verified,
 * so shipping one without the other leaves the site deploying one version of a
 * contract and publishing the sources of another.
 *
 * Override the destination with OXL_PLUGIN_DIR=/path/to/oxlimited-web3.
 */
import hre from "hardhat";
import fs from "fs";
import path from "path";

const DEFAULT_PLUGIN_DIR = "/Applications/MAMP/htdocs/wordpress/wp-content/plugins/oxlimited-web3";

// The keys oxweb3.js reads off window.OxContracts, and the artifact behind each.
const ENTRIES: Array<{ key: string; sourceName: string; contractName: string }> = [
  {
    key: "validationLogic",
    sourceName: "contracts/validation/HybridToluTagValidationLogic.sol",
    contractName: "HybridToluTagValidationLogic",
  },
  {
    key: "metadata",
    sourceName: "contracts/metadata/HybridToluTagMetadataRandom.sol",
    contractName: "HybridToluTagMetadataRandom",
  },
  {
    key: "metadataReserved",
    sourceName: "contracts/metadata/HybridToluTagMetadataReserved.sol",
    contractName: "HybridToluTagMetadataReserved",
  },
  {
    key: "standard",
    sourceName: "contracts/nft/ToluTagProduct.sol",
    contractName: "ToluTagProduct",
  },
  {
    key: "paid",
    sourceName: "contracts/nft/ToluTagProductPaid.sol",
    contractName: "ToluTagProductPaid",
  },
];

const HEADER = `/**
 * Compiled contract ABIs + creation bytecode for on-chain deploys.
 * Generated from the Hardhat artifacts. Regenerate when the contracts change.
 */

`;

async function main() {
  const outDir = process.env.OXL_PLUGIN_DIR || DEFAULT_PLUGIN_DIR;
  const outFile = path.join(outDir, "assets", "oxcontracts.js");
  if (!fs.existsSync(path.dirname(outFile))) {
    throw new Error(`Plugin assets directory not found: ${path.dirname(outFile)}\nSet OXL_PLUGIN_DIR to the oxlimited-web3 folder.`);
  }

  await hre.run("compile");

  const bundle: Record<string, { abi: unknown; bytecode: string }> = {};
  for (const { key, sourceName, contractName } of ENTRIES) {
    const artifact = await hre.artifacts.readArtifact(`${sourceName}:${contractName}`);
    if (!artifact.bytecode || artifact.bytecode === "0x") {
      throw new Error(`${contractName} has no creation bytecode — is it still abstract?`);
    }
    if (artifact.linkReferences && Object.keys(artifact.linkReferences).length > 0) {
      throw new Error(`${contractName} needs library linking, which the browser deploy path cannot do.`);
    }
    bundle[key] = { abi: artifact.abi, bytecode: artifact.bytecode };
    console.log(`${key.padEnd(16)} ${contractName} — ${artifact.abi.length} ABI entries, ${artifact.bytecode.length} bytecode chars`);
  }

  fs.writeFileSync(outFile, `${HEADER}window.OxContracts = ${JSON.stringify(bundle)};\n`);
  console.log(`\nWritten to ${outFile}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
