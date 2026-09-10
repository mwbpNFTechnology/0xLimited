import { expect } from "chai";
import { ethers } from "hardhat";

/**
 * The metadata contract is fixed at deployment: it is supplied to the constructor,
 * stored immutably, and there is no way for the owner (or anyone) to swap it after.
 */
describe("Collection configuration", function () {
  const BASE_MEDIA_URI = "ipfs://bafybeigc5flxp5uzoyyqddmiysw65p6g6cxzdfo6noqokxiimc4fgeh3rm/";
  const OBJECT_ID = "0x00002222";
  const MAX_SUPPLY = 3;
  const RESERVED = 1; // collectionType 1 — reserved tokens have metadata before minting

  async function deployCollection(metadataOverride?: string) {
    const validation = await ethers.deployContract("HybridToluTagValidationLogic", [300]);
    const metadata = await ethers.deployContract("HybridToluTagMetadataRandom", [await validation.getAddress(), []]);
    const nft = await ethers.deployContract("ToluTagProduct", [
      await validation.getAddress(),
      metadataOverride ?? (await metadata.getAddress()),
      "Test Collection",
      MAX_SUPPLY,
      500,
      BASE_MEDIA_URI,
      OBJECT_ID,
      RESERVED,
    ]);
    return { validation, metadata, nft };
  }

  /** Reserve tokenId for a tag key so the token has metadata without being minted. */
  async function reserveToken(nft: any, tagKey: string, uuid: string, tokenId: number) {
    await nft.batchSetToluTagPublicKeys([`${tagKey}_${uuid}_${tokenId}`]);
  }

  async function readMetadata(nft: any, tokenId: number) {
    const uri: string = await nft.tokenURI(tokenId);
    expect(uri.startsWith("data:application/json;base64,")).to.equal(true);
    return JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString("utf8"));
  }

  it("binds the metadata contract given at deployment and renders with it", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const { metadata, nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 1);

    expect(await nft.metadataContract()).to.equal(await metadata.getAddress());
    expect(await metadata.nftContract()).to.equal(await nft.getAddress());
    expect((await readMetadata(nft, 1)).tokenMediaURL).to.equal(BASE_MEDIA_URI);
  });

  describe("the metadata contract cannot change after deployment", function () {
    it("exposes no way to set it — not for the owner, not for anyone", async function () {
      const { nft } = await deployCollection();
      const abi = (await ethers.getContractFactory("ToluTagProduct")).interface;

      const writable = abi.fragments.filter(
        (f: any) => f.type === "function" && f.stateMutability !== "view" && f.stateMutability !== "pure"
      );
      expect(writable.map((f: any) => f.name)).to.not.include("setMetadataContract");
      expect(abi.fragments.some((f: any) => f.type === "event" && f.name === "MetadataContractUpdated")).to.equal(false);
      expect((nft as any).setMetadataContract).to.equal(undefined);
    });

    it("is the same for the paid variant", async function () {
      const abi = (await ethers.getContractFactory("ToluTagProductPaid")).interface;
      expect(
        abi.fragments.filter((f: any) => f.type === "function").map((f: any) => f.name)
      ).to.not.include("setMetadataContract");
    });

    it("requires a metadata contract at deployment, since none can be added later", async function () {
      await expect(deployCollection(ethers.ZeroAddress)).to.be.revertedWithCustomError(
        await ethers.getContractFactory("ToluTagProduct"),
        "InvalidMetadataContract"
      );
    });
  });
});
