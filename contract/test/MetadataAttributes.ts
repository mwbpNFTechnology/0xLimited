import { expect } from "chai";
import { ethers } from "hardhat";

/**
 * HybridToluTagMetadataRandom: one set of custom traits shared by every token in the
 * drop, rendered on top of the eight default fields.
 */
describe("Custom attributes (random collection)", function () {
  const BASE_MEDIA_URI = "ipfs://bafybeigc5flxp5uzoyyqddmiysw65p6g6cxzdfo6noqokxiimc4fgeh3rm/";
  const OBJECT_ID = "0x00002222";

  const TRAITS = [
    { traitType: "Signed by", value: "Joe Hahn" },
    { traitType: "Tour", value: "2026" },
    { traitType: "Material", value: "Cotton" },
  ];

  /** collectionType 1 so reserved tokens render before anyone mints. */
  async function deployCollection(collectionType = 1) {
    const validation = await ethers.deployContract("HybridToluTagValidationLogic", [300]);
    const metadata = await ethers.deployContract("HybridToluTagMetadataRandom", [await validation.getAddress(), []]);
    const nft = await ethers.deployContract("ToluTagProduct", [
      await validation.getAddress(),
      await metadata.getAddress(),
      "Test Collection",
      3,
      500,
      BASE_MEDIA_URI,
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
    return JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString("utf8"));
  }

  it("takes traits in the constructor, so a deploy needs no follow-up transaction", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const validation = await ethers.deployContract("HybridToluTagValidationLogic", [300]);
    const metadata = await ethers.deployContract("HybridToluTagMetadataRandom", [
      await validation.getAddress(),
      TRAITS,
    ]);
    const nft = await ethers.deployContract("ToluTagProduct", [
      await validation.getAddress(), await metadata.getAddress(), "Test Collection",
      3, 500, BASE_MEDIA_URI, OBJECT_ID, 1,
    ]);
    await reserveToken(nft, tag.address, uuid.address, 1);

    expect(await metadata.collectionAttributesCount()).to.equal(3);
    expect((await readMetadata(nft, 1)).attributes).to.deep.equal(
      TRAITS.map((t) => ({ trait_type: t.traitType, value: t.value }))
    );
  });

  it("validates constructor traits the same way as the setter", async function () {
    const validation = await ethers.deployContract("HybridToluTagValidationLogic", [300]);
    const factory = await ethers.getContractFactory("HybridToluTagMetadataRandom");
    await expect(
      ethers.deployContract("HybridToluTagMetadataRandom", [
        await validation.getAddress(),
        [{ traitType: 'Signed "by"', value: "Joe" }],
      ])
    ).to.be.revertedWithCustomError(factory, "InvalidAttribute");

    const many = Array.from({ length: 33 }, (_, i) => ({ traitType: `t${i}`, value: "v" }));
    await expect(
      ethers.deployContract("HybridToluTagMetadataRandom", [await validation.getAddress(), many])
    ).to.be.revertedWithCustomError(factory, "TooManyAttributes");
  });

  it("renders the defaults untouched when no traits are set", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const { nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 1);

    const meta = await readMetadata(nft, 1);
    expect(Object.keys(meta)).to.deep.equal([
      "contractOwner", "productName", "tokenID", "toluTagPublicKey",
      "minted", "paired", "pairedUpdatedAt", "tokenMediaURL",
    ]);
    expect(meta.attributes).to.equal(undefined);
  });

  it("adds the collection's traits on top of the defaults, in order", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const { metadata, nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 1);
    await metadata.setCollectionAttributes(TRAITS);

    const meta = await readMetadata(nft, 1);
    expect(meta.tokenMediaURL).to.equal(BASE_MEDIA_URI); // defaults still intact
    expect(meta.attributes).to.deep.equal(
      TRAITS.map((t) => ({ trait_type: t.traitType, value: t.value }))
    );
  });

  it("gives every token in the drop the same traits", async function () {
    const [, tag, uuid, tag2, uuid2] = await ethers.getSigners();
    const { metadata, nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 1);
    await reserveToken(nft, tag2.address, uuid2.address, 2);
    await metadata.setCollectionAttributes(TRAITS);

    expect((await readMetadata(nft, 1)).attributes).to.deep.equal((await readMetadata(nft, 2)).attributes);
  });

  it("replaces the whole list, and an empty list drops back to the defaults", async function () {
    const [, tag, uuid] = await ethers.getSigners();
    const { metadata, nft } = await deployCollection();
    await reserveToken(nft, tag.address, uuid.address, 1);

    await metadata.setCollectionAttributes(TRAITS);
    await metadata.setCollectionAttributes([{ traitType: "Edition", value: "Second" }]);
    expect(await metadata.collectionAttributesCount()).to.equal(1);
    expect((await readMetadata(nft, 1)).attributes).to.deep.equal([
      { trait_type: "Edition", value: "Second" },
    ]);

    await metadata.setCollectionAttributes([]);
    expect((await readMetadata(nft, 1)).attributes).to.equal(undefined);
  });

  describe("who may write, and what", function () {
    it("only the collection owner — not the metadata deployer's Ownable owner", async function () {
      const [, outsider] = await ethers.getSigners();
      const { metadata } = await deployCollection();

      await expect(
        metadata.connect(outsider).setCollectionAttributes(TRAITS)
      ).to.be.revertedWithCustomError(metadata, "NotCollectionOwner");
    });

    it("follows the collection when ownership is transferred", async function () {
      const [, next, tag, uuid] = await ethers.getSigners();
      const { metadata, nft } = await deployCollection();
      await reserveToken(nft, tag.address, uuid.address, 1);

      await nft.transferOwnership(next.address);
      await expect(metadata.setCollectionAttributes(TRAITS)).to.be.revertedWithCustomError(
        metadata,
        "NotCollectionOwner"
      );
      await metadata.connect(next).setCollectionAttributes(TRAITS);
      expect((await readMetadata(nft, 1)).attributes).to.have.length(3);
    });

    it("rejects text that would break the JSON document", async function () {
      const { metadata } = await deployCollection();
      const bad = [
        { traitType: 'Signed "by"', value: "Joe" },
        { traitType: "Note", value: "back\\slash" },
        { traitType: "Note", value: "line\nbreak" },
        { traitType: "", value: "empty type" },
        { traitType: "Long", value: "x".repeat(201) },
      ];
      for (const attr of bad) {
        await expect(metadata.setCollectionAttributes([attr])).to.be.revertedWithCustomError(
          metadata,
          "InvalidAttribute"
        );
      }
    });

    it("caps the list length", async function () {
      const { metadata } = await deployCollection();
      const many = Array.from({ length: 33 }, (_, i) => ({ traitType: `t${i}`, value: "v" }));
      await expect(metadata.setCollectionAttributes(many)).to.be.revertedWithCustomError(
        metadata,
        "TooManyAttributes"
      );
    });
  });

  it("still renders traits for a random collection once a token is minted", async function () {
    // collectionType 0: unminted tokens have no metadata at all, so the traits
    // only become visible after a mint — nothing to key per-token data to.
    const { metadata, nft } = await deployCollection(0);
    await metadata.setCollectionAttributes(TRAITS);
    // TokenDoesNotExist is raised by the metadata contract, which renders the document.
    await expect(nft.tokenURI(1)).to.be.revertedWithCustomError(metadata, "TokenDoesNotExist");
    expect(await metadata.collectionAttributesCount()).to.equal(3);
  });
});
