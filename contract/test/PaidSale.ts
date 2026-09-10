import { expect } from "chai";
import { ethers } from "hardhat";

/** A paid collection is configured at deploy but does not sell until the owner says so. */
describe("Paid collection sale", function () {
  const BASE = "ipfs://bafyexample/";
  const OBJECT_ID = "0x00002222";
  const PRICE_NATIVE = ethers.parseEther("0.01"); // per unit, in wei
  const PRICE_USDC = 2_000_000n; // per unit, 2 USDC (6 decimals)

  // Payment currency the buyer chooses at purchase time (mirrors the PayWith enum).
  const NATIVE = 0;
  const USDC = 1;

  async function deployPaid(maxPerWallet: bigint) {
    const validation = await ethers.deployContract("HybridToluTagValidationLogic", [300]);
    const metadata = await ethers.deployContract("HybridToluTagMetadataRandom", [await validation.getAddress(), []]);
    const usdc = await ethers.deployContract("MockUSDC");
    const nft = await ethers.deployContract("ToluTagProductPaid", [
      await validation.getAddress(), await metadata.getAddress(), "Paid Drop",
      10, 500, BASE, OBJECT_ID, 0,
      await usdc.getAddress(), PRICE_NATIVE, PRICE_USDC, maxPerWallet,
    ]);
    return { nft, usdc };
  }

  it("deploys with the sale closed, and refuses purchases until it is opened", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft } = await deployPaid(0n);

    expect(await nft.saleActive()).to.equal(false);
    await expect(nft.connect(buyer).purchase(1, NATIVE, { value: PRICE_NATIVE }))
      .to.be.revertedWithCustomError(nft, "SaleNotActive");

    await nft.setSaleActive(true);
    await nft.connect(buyer).purchase(1, NATIVE, { value: PRICE_NATIVE });
    expect(await nft.paidQuantity(buyer.address)).to.equal(1n);
  });

  it("lets the buyer pay in USDC after approving it", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft, usdc } = await deployPaid(0n);
    await nft.setSaleActive(true);

    await usdc.mint(buyer.address, PRICE_USDC * 3n);
    await usdc.connect(buyer).approve(await nft.getAddress(), PRICE_USDC * 2n);

    // USDC payment sends no native coin.
    await nft.connect(buyer).purchase(2, USDC, { value: 0 });

    expect(await nft.paidQuantity(buyer.address)).to.equal(2n);
    expect(await usdc.balanceOf(await nft.getAddress())).to.equal(PRICE_USDC * 2n);
  });

  it("rejects native coin sent alongside a USDC purchase", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft, usdc } = await deployPaid(0n);
    await nft.setSaleActive(true);
    await usdc.mint(buyer.address, PRICE_USDC);
    await usdc.connect(buyer).approve(await nft.getAddress(), PRICE_USDC);

    await expect(nft.connect(buyer).purchase(1, USDC, { value: PRICE_NATIVE }))
      .to.be.revertedWithCustomError(nft, "UnexpectedNativeCoin");
  });

  it("rejects the wrong native amount", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft } = await deployPaid(0n);
    await nft.setSaleActive(true);

    await expect(nft.connect(buyer).purchase(1, NATIVE, { value: PRICE_NATIVE - 1n }))
      .to.be.revertedWithCustomError(nft, "IncorrectNativeAmount");
  });

  it("refuses a currency whose price is 0", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft } = await deployPaid(0n);
    await nft.setSaleActive(true);

    // Turn USDC off (price 0) but keep native on.
    await nft.setPaymentConfig(ethers.ZeroAddress, PRICE_NATIVE, 0);
    await expect(nft.connect(buyer).purchase(1, USDC, { value: 0 }))
      .to.be.revertedWithCustomError(nft, "PriceNotSet");
  });

  it("takes the per-wallet cap at deploy and enforces it", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft } = await deployPaid(2n);
    await nft.setSaleActive(true);

    expect(await nft.maxPerWallet()).to.equal(2n);
    await nft.connect(buyer).purchase(2, NATIVE, { value: PRICE_NATIVE * 2n });
    await expect(nft.connect(buyer).purchase(1, NATIVE, { value: PRICE_NATIVE }))
      .to.be.revertedWithCustomError(nft, "ExceedsMaxPerWallet");
  });

  it("treats 0 as no cap", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft } = await deployPaid(0n);
    await nft.setSaleActive(true);
    await nft.connect(buyer).purchase(7, NATIVE, { value: PRICE_NATIVE * 7n });
    expect(await nft.paidQuantity(buyer.address)).to.equal(7n);
  });

  it("never sells more than maxSupply", async function () {
    const [, buyer] = await ethers.getSigners();
    const { nft } = await deployPaid(0n); // maxSupply 10
    await nft.setSaleActive(true);
    await nft.connect(buyer).purchase(10, NATIVE, { value: PRICE_NATIVE * 10n });
    await expect(nft.connect(buyer).purchase(1, NATIVE, { value: PRICE_NATIVE }))
      .to.be.revertedWithCustomError(nft, "ExceedsMaxSupply");
  });

  it("rejects a per-wallet cap above the total supply", async function () {
    const validation = await ethers.deployContract("HybridToluTagValidationLogic", [300]);
    const metadata = await ethers.deployContract("HybridToluTagMetadataRandom", [await validation.getAddress(), []]);
    const usdc = await ethers.deployContract("MockUSDC");
    const factory = await ethers.getContractFactory("ToluTagProductPaid");

    // maxSupply is 10 here; a cap of 11 must be refused at deploy.
    await expect(ethers.deployContract("ToluTagProductPaid", [
      await validation.getAddress(), await metadata.getAddress(), "Paid Drop",
      10, 500, BASE, OBJECT_ID, 0,
      await usdc.getAddress(), PRICE_NATIVE, PRICE_USDC, 11,
    ])).to.be.revertedWithCustomError(factory, "MaxPerWalletExceedsSupply");
  });

  it("refuses to raise the cap above the total supply after deploy", async function () {
    const { nft } = await deployPaid(2n); // maxSupply 10
    await expect(nft.setMaxPerWallet(11)).to.be.revertedWithCustomError(nft, "MaxPerWalletExceedsSupply");
    await nft.setMaxPerWallet(10); // exactly the supply is allowed
    expect(await nft.maxPerWallet()).to.equal(10n);
  });

  it("only the owner can open the sale", async function () {
    const [, outsider] = await ethers.getSigners();
    const { nft } = await deployPaid(0n);
    await expect(nft.connect(outsider).setSaleActive(true)).to.be.reverted;
    expect(await nft.saleActive()).to.equal(false);
  });
});
