import { expect } from "chai";
import { ethers } from "hardhat";

/**
 * HybridToluTagMetadataReserved: defaults on-chain, per-token traits off-chain in
 * the token's own media folder.
 */
describe("Reserved metadata", function () {
  const BASE = "ipfs://bafybeifmrm2sxg2dlnkftzuzooncrn5bfnt6opaypp4ushuptbkbrffvrq/";
  const OBJECT_ID = "0x00002222";
  const MAX_SUPPLY = 5;

  async function deployCollection(collectionType = 1) {
    const validation = await ethers.deployContract("HybridToluTagValidationLogic", [300]);
    const metadata = await ethers.deployContract("HybridToluTagMetadataReserved", [await validation.getAddress()]);
    const nft = await ethers.deployContract("ToluTagProduct", [
      await validation.getAddress(),
      await metadata.getAddress(),
      "Joe Hahn Jersey",
      MAX_SUPPLY,
      500,
      BASE,
      OBJECT_ID,
      collectionType,
    ]);
    return { validation, metadata, nft };
  }

  async function reserveToken(nft: any, tagKey: string, uuid: string, tokenId: number) {
    await nft.batchSetToluTagPublicKeys([`${tagKey}_${uuid}_${tokenId}`]);
  }

  async function readMetadata(nft: any, tokenId: number) {
    const uri: string = await nft.tokenURI(tokenId);
    expect(uri.startsWith("data:application/json;base64,")).to.equal(true);
    return JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString("utf8"));
  }

  it("points each token at its own folder and attributes file", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const { nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 3);

    const meta = await readMetadata(nft, 3);
    expect(meta.tokenMediaURL).to.equal(`${BASE}3/`);
    expect(meta.attributesURL).to.equal(`${BASE}3/attributes.json`);
  });

  it("keeps the eight default fields on-chain, plus the pointer", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const { nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 1);

    expect(Object.keys(await readMetadata(nft, 1))).to.deep.equal([
      "contractOwner", "productName", "tokenID", "toluTagPublicKey",
      "minted", "paired", "pairedUpdatedAt", "tokenMediaURL", "attributesURL",
    ]);
  });

  it("gives different tokens different folders", async function () {
    const [, tagA, uuidA, tagB, uuidB] = await ethers.getSigners();
    const { nft } = await deployCollection();
    await reserveToken(nft, tagA.address, uuidA.address, 1);
    await reserveToken(nft, tagB.address, uuidB.address, 2);

    expect((await readMetadata(nft, 1)).tokenMediaURL).to.equal(`${BASE}1/`);
    expect((await readMetadata(nft, 2)).tokenMediaURL).to.equal(`${BASE}2/`);
  });

  it("resolves before the token is minted, and names the tag holding it", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const { nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 4);

    const meta = await readMetadata(nft, 4);
    expect(meta.minted).to.equal(false);
    expect(meta.paired).to.equal(false);
    expect(meta.attributesURL).to.equal(`${BASE}4/attributes.json`);
    // The tag is bound to the token at registration, so it is known pre-mint.
    expect(meta.toluTagPublicKey).to.equal(tag.address.toLowerCase());
  });

  it("keeps each reserved token pointing at its own tag", async function () {
    const [, tagA, uuidA, tagB, uuidB] = await ethers.getSigners();
    const { validation, nft } = await deployCollection();
    await reserveToken(nft, tagA.address, uuidA.address, 1);
    await reserveToken(nft, tagB.address, uuidB.address, 2);

    expect((await readMetadata(nft, 1)).toluTagPublicKey).to.equal(tagA.address.toLowerCase());
    expect((await readMetadata(nft, 2)).toluTagPublicKey).to.equal(tagB.address.toLowerCase());

    // The reverse lookup and the reservation agree in both directions.
    expect(await validation.reservedTokenTag(1)).to.equal(tagA.address);
    expect(await validation.getReservedTokenId(tagA.address)).to.equal(1n);
    expect(await validation.isTokenReserved(1)).to.equal(true);
    expect(await validation.isTokenReserved(3)).to.equal(false);
    expect(await validation.reservedTokenTag(3)).to.equal(ethers.ZeroAddress);
  });

  it("has no metadata for a token nobody reserved", async function () {
    const { metadata, nft } = await deployCollection();
    await expect(nft.tokenURI(2)).to.be.revertedWithCustomError(metadata, "TokenDoesNotExist");
  });

  it("exposes the folder and file directly for tooling", async function () {
    const { metadata } = await deployCollection();
    expect(await metadata.tokenFolder(7)).to.equal(`${BASE}7/`);
    expect(await metadata.attributesURL(7)).to.equal(`${BASE}7/attributes.json`);
    expect(await metadata.ATTRIBUTES_FILE()).to.equal("attributes.json");
  });

  it("refuses to serve a random collection", async function () {
    // Random collections have one folder for the whole drop, so per-token folders
    // would not exist. The metadata contract cannot be swapped, so this has to fail
    // at the first read rather than quietly serve wrong URLs forever.
    const { metadata, nft } = await deployCollection(0);
    await expect(nft.tokenURI(1)).to.be.revertedWithCustomError(metadata, "NotReservedCollection");
  });

  it("still carries no traits on-chain — they live in the folder", async function () {
    const { metadata } = await deployCollection();
    const fns = (await ethers.getContractFactory("HybridToluTagMetadataReserved")).interface.fragments
      .filter((f: any) => f.type === "function")
      .map((f: any) => f.name);
    expect(fns).to.not.include("setCollectionAttributes");
    expect((metadata as any).setCollectionAttributes).to.equal(undefined);
  });
});
