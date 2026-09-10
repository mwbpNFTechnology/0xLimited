/**
 * Regenerate the per-contract Etherscan verification inputs used by the
 * 0xLimited WordPress plugin (wp-content/plugins/oxlimited-web3/data-input-*.json).
 *
 *   npm run verify:inputs
 *
 * Why per-contract: Hardhat compiles every contract in one solc job, so the
 * project-wide Standard-JSON-Input contains all four NFT contracts. Verifying a
 * standard collection with that bundle publishes HybridToluTagNFTPaid.sol and
 * ToluTagProductPaid.sol on its Etherscan page — and Etherscan will not let you
 * replace the sources of an address that is already verified. Each contract
 * therefore gets an input holding only its own import closure.
 *
 * Each generated input is compiled here and its deployed bytecode compared with
 * the artifact from the full build. They must match, otherwise Etherscan would
 * reject the minimal input and the fix would silently regress.
 *
 * Override the destination with OXL_PLUGIN_DIR=/path/to/oxlimited-web3.
 */
import hre from "hardhat";
import fs from "fs";
import path from "path";

const DEFAULT_PLUGIN_DIR = "/Applications/MAMP/htdocs/wordpress/wp-content/plugins/oxlimited-web3";

const PAID_SOURCES = [
  "contracts/nft/HybridToluTagNFTPaid.sol",
  "contracts/nft/ToluTagProductPaid.sol",
];
const STANDARD_SOURCES = [
  "contracts/nft/HybridToluTagNFT.sol",
  "contracts/nft/ToluTagProduct.sol",
];

// sourceName, contractName, output file, and the sources that must NOT ride along.
const TARGETS: Array<{
  sourceName: string;
  contractName: string;
  outFile: string;
  forbidden: string[];
}> = [
  {
    sourceName: "contracts/validation/HybridToluTagValidationLogic.sol",
    contractName: "HybridToluTagValidationLogic",
    outFile: "data-input-validation.json",
    forbidden: [...PAID_SOURCES, ...STANDARD_SOURCES],
  },
  {
    sourceName: "contracts/metadata/HybridToluTagMetadataRandom.sol",
    contractName: "HybridToluTagMetadataRandom",
    outFile: "data-input-metadata.json",
    forbidden: [...PAID_SOURCES, ...STANDARD_SOURCES],
  },
  {
    sourceName: "contracts/metadata/HybridToluTagMetadataReserved.sol",
    contractName: "HybridToluTagMetadataReserved",
    outFile: "data-input-metadata-reserved.json",
    forbidden: [...PAID_SOURCES, ...STANDARD_SOURCES],
  },
  {
    sourceName: "contracts/nft/ToluTagProduct.sol",
    contractName: "ToluTagProduct",
    outFile: "data-input-standard.json",
    forbidden: PAID_SOURCES,
  },
  {
    sourceName: "contracts/nft/ToluTagProductPaid.sol",
    contractName: "ToluTagProductPaid",
    outFile: "data-input-paid.json",
    forbidden: STANDARD_SOURCES,
  },
];

async function main() {
  const outDir = process.env.OXL_PLUGIN_DIR || DEFAULT_PLUGIN_DIR;
  if (!fs.existsSync(outDir)) {
    throw new Error(`Plugin directory not found: ${outDir}\nSet OXL_PLUGIN_DIR to the oxlimited-web3 folder.`);
  }

  await hre.run("compile");

  const solcVersion = (hre.config.solidity as any).compilers[0].version as string;
  const solcBuild: any = await hre.run("compile:solidity:solc:get-build", { quiet: true, solcVersion });

  for (const { sourceName, contractName, outFile, forbidden } of TARGETS) {
    const input: any = await hre.run("verify:etherscan-get-minimal-input", { sourceName });
    const sources = Object.keys(input.sources);

    // Guard 1: the other branch's contracts must not ride along — that is the
    // whole point of these files.
    const strays = forbidden.filter((f) => sources.includes(f));
    if (strays.length > 0) {
      throw new Error(`${contractName}: unrelated sources in its input: ${strays.join(", ")}`);
    }

    // Guard 2: the input must reproduce the deployed bytecode, or Etherscan rejects it.
    const output: any = await hre.run("compile:solidity:solc:run", {
      input,
      quiet: true,
      solcVersion,
      solcPath: solcBuild.compilerPath,
      isSolcJs: solcBuild.isSolcJs,
    });
    const errors = (output.errors ?? []).filter((e: any) => e.severity === "error");
    if (errors.length > 0) {
      throw new Error(`${contractName}: minimal input failed to compile:\n${errors.map((e: any) => e.formattedMessage).join("\n")}`);
    }
    const minimal = output.contracts?.[sourceName]?.[contractName]?.evm?.deployedBytecode?.object;
    const artifact = JSON.parse(
      fs.readFileSync(path.join(__dirname, "..", "artifacts", sourceName, `${contractName}.json`), "utf8")
    );
    const full = String(artifact.deployedBytecode).replace(/^0x/, "");
    if (minimal !== full) {
      throw new Error(
        `${contractName}: minimal input does not reproduce the artifact bytecode — Etherscan would reject it. ` +
          `Do not ship this input.`
      );
    }

    fs.writeFileSync(path.join(outDir, outFile), JSON.stringify(input, null, 2) + "\n");
    console.log(`${outFile.padEnd(28)} ${contractName} — ${sources.length} sources, bytecode matches`);
  }

  const longVersion: string = solcBuild.longVersion ?? solcVersion;
  fs.writeFileSync(path.join(outDir, "data-solc-version.txt"), longVersion + "\n");
  console.log(`data-solc-version.txt        ${longVersion}`);
  console.log(`\nWritten to ${outDir}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
