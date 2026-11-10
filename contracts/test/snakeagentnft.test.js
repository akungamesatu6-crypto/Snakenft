const { expect } = require("chai");
const { ethers } = require("hardhat");
const manifest = require("../../deck/manifest.json");

const BASE_URI = "https://snakeagentnft.vercel.app/metadata/";
const DECK_HASH = manifest.deckHash;
const BITMAP = manifest.rarityBitmap;
const RARITY_NAMES = ["Common", "Rare", "Epic", "Legendary"];
const CLAIM_AMOUNTS = ["10000", "25000", "50000", "100000"]; // by rarity 0..3

describe("SnakeAgentNFT (ZigZoo ladder + deck-draw + $SNAKE rarity claim)", function () {
  let owner, alice, bob, carol, dave, noId;
  let extraSigners;
  let registry, snake, nft, market;
  let aliceTokens = []; // tokenIds minted by alice (bulk 30)
  let bobTokenId = null; // a token bob minted, later sold to carol
  let mintedIds = []; // every tokenId minted so far (for the claim tests)

  async function mintBulk(wallet, qty, value) {
    const tx = await nft.connect(wallet)["mint(uint256)"](qty, { value });
    const rc = await tx.wait();
    const ids = [];
    for (const log of rc.logs) {
      try {
        const parsed = nft.interface.parseLog(log);
        if (parsed && parsed.name === "Minted") ids.push(Number(parsed.args.tokenId));
      } catch (e) { /* not our event */ }
    }
    mintedIds.push(...ids);
    return ids;
  }

  before(async function () {
    [owner, alice, bob, carol, dave, noId, ...extraSigners] = await ethers.getSigners();

    const Registry = await ethers.getContractFactory("MockAgentIdRegistry");
    registry = await Registry.deploy();
    await registry.mintBatch([alice.address, bob.address, carol.address, dave.address]);

    const Snake = await ethers.getContractFactory("SnakeToken");
    snake = await Snake.deploy(owner.address);

    const Nft = await ethers.getContractFactory("SnakeAgentNFT");
    nft = await Nft.deploy(
      owner.address,
      owner.address, // revenue = owner (BAW rule: BAW for everything)
      await registry.getAddress(),
      BASE_URI,
      DECK_HASH,
      BITMAP
    );

    // Wire-up (token deploys first, so the NFT address is set after).
    await snake.setNft(await nft.getAddress());
    await snake.setMinter(await nft.getAddress(), true);

    const Market = await ethers.getContractFactory("SnakeAgentMarketplace");
    market = await Market.deploy(await nft.getAddress());

    await nft.setMintActive(true);
  });

  it("deploy: name/symbol/supply/deckHash/bitmap match the manifest", async function () {
    expect(await nft.name()).to.equal("SnakeAgentNFT");
    expect(await nft.symbol()).to.equal("SNAKEAGENT");
    expect(await nft.MAX_SUPPLY()).to.equal(4444);
    expect(await nft.deckHash()).to.equal(DECK_HASH);
    expect(await nft.deckRemaining()).to.equal(4444);
    expect(await nft.commonsRemaining()).to.equal(3555);
    expect(await nft.raresRemaining()).to.equal(622);
    expect(await nft.epicsRemaining()).to.equal(178);
    expect(await nft.legendariesRemaining()).to.equal(89);
    expect(await snake.MAX_SUPPLY()).to.equal(ethers.parseEther("100000000"));
    expect(await snake.MAX_CLAIMABLE()).to.equal(ethers.parseEther("68900000"));
    expect(await snake.name()).to.equal("Snake");
    expect(await snake.symbol()).to.equal("SNAKE");
    expect(await snake.claimAmount(0)).to.equal(ethers.parseEther("10000"));
    expect(await snake.claimAmount(1)).to.equal(ethers.parseEther("25000"));
    expect(await snake.claimAmount(2)).to.equal(ethers.parseEther("50000"));
    expect(await snake.claimAmount(3)).to.equal(ethers.parseEther("100000"));
    await expect(snake.claimAmount(4)).to.be.revertedWithCustomError(snake, "InvalidRarity");
    expect(await snake.nft()).to.equal(await nft.getAddress());
    expect(await snake.minters(await nft.getAddress())).to.equal(true);
    // bitmap spot-check: rarityOf matches the manifest deck
    for (const t of [1, 2, 3, 4, 5, 50, 100, 500, 1000, 2222, 3333, 4444]) {
      const want = RARITY_NAMES.indexOf(manifest.tokens[t - 1].rarity);
      expect(await nft.rarityOf(t)).to.equal(want, `rarityOf(${t})`);
    }
    await expect(nft.rarityOf(0)).to.be.revertedWithCustomError(nft, "ExceedsMaxSupply");
    await expect(nft.rarityOf(4445)).to.be.revertedWithCustomError(nft, "ExceedsMaxSupply");
  });

  it("pricing: ladder + quoteBulk(30) = 0.0138 BNB, freeSlot 0", async function () {
    expect(await nft.priceForCount(0)).to.equal(ethers.parseEther("0.0002"));
    expect(await nft.priceForCount(9)).to.equal(ethers.parseEther("0.0002"));
    expect(await nft.priceForCount(10)).to.equal(ethers.parseEther("0.0004"));
    expect(await nft.priceForCount(19)).to.equal(ethers.parseEther("0.0004"));
    expect(await nft.priceForCount(20)).to.equal(ethers.parseEther("0.0008"));
    expect(await nft.priceForCount(29)).to.equal(ethers.parseEther("0.0008"));
    expect(await nft.priceFor(alice.address)).to.equal(0); // free mint unused
    expect(await nft.connect(alice).currentPrice()).to.equal(0);
    const [price, freeSlot] = await nft.quoteBulk(alice.address, 30);
    expect(price).to.equal(ethers.parseEther("0.0138"));
    expect(freeSlot).to.equal(0);
    const [p1, fs1] = await nft.quoteBulk(alice.address, 1);
    expect(p1).to.equal(0);
    expect(fs1).to.equal(0);
    const [p5, fs5] = await nft.quoteBulk(alice.address, 5);
    // 1 free + 4 x 0.0002 = 0.0008
    expect(p5).to.equal(ethers.parseEther("0.0008"));
    expect(fs5).to.equal(0);
  });

  it("mint rejects: inactive, no Agent ID, contract caller, bad quantity", async function () {
    await nft.setMintActive(false);
    await expect(nft.connect(alice)["mint(uint256)"](1)).to.be.revertedWithCustomError(nft, "MintInactive");
    await nft.setMintActive(true);
    await expect(nft.connect(noId)["mint(uint256)"](1)).to.be.revertedWithCustomError(nft, "NoAgentId");
    const Caller = await ethers.getContractFactory("MockGenericCaller");
    const caller = await Caller.deploy();
    await registry.mintTo(await caller.getAddress()); // give the CALLER an Agent ID
    const data = nft.interface.encodeFunctionData("mint(uint256)", [1]);
    await expect(
      caller.tryCallRevert(await nft.getAddress(), data, { value: ethers.parseEther("0.0002") })
    ).to.be.revertedWithCustomError(nft, "NoContracts");
    await expect(nft.connect(alice)["mint(uint256)"](0)).to.be.revertedWithCustomError(nft, "MaxPerWallet");
    await expect(nft.connect(alice)["mint(uint256)"](31)).to.be.revertedWithCustomError(nft, "MaxPerWallet");
    // only the owner can flip the mint switch
    await expect(nft.connect(alice).setMintActive(false))
      .to.be.revertedWithCustomError(nft, "OwnableUnauthorizedAccount");
  });

  it("free mint: first mint(1) costs 0; underpayment reverts after free is used", async function () {
    const tx = await nft.connect(bob)["mint(uint256)"](1, { value: 0 });
    const rc = await tx.wait();
    for (const log of rc.logs) {
      try {
        const parsed = nft.interface.parseLog(log);
        if (parsed && parsed.name === "Minted") bobTokenId = Number(parsed.args.tokenId);
      } catch (e) { /* not our event */ }
    }
    expect(bobTokenId).to.not.equal(null);
    mintedIds.push(bobTokenId);
    expect(await nft.freeUsed(bob.address)).to.equal(true);
    expect(await nft.freeMinted()).to.equal(1);
    expect(await nft.mintCount(bob.address)).to.equal(1);
    expect(await nft.priceFor(bob.address)).to.equal(ethers.parseEther("0.0002"));
    expect(await nft.connect(bob).currentPrice()).to.equal(ethers.parseEther("0.0002"));
    expect(await nft.deckRemaining()).to.equal(4443);
    const [pb, fsb] = await nft.quoteBulk(bob.address, 1);
    expect(pb).to.equal(ethers.parseEther("0.0002"));
    expect(fsb).to.equal(ethers.MaxUint256); // free already used
    await expect(nft.connect(bob)["mint(uint256)"](1, { value: 1 }))
      .to.be.revertedWithCustomError(nft, "IncorrectPayment");
  });

  it("bulk 30: fresh wallet pays exactly 0.0138, revenue forwarded, cap enforced, refund works", async function () {
    const revBefore = await ethers.provider.getBalance(owner.address);
    aliceTokens = await mintBulk(alice, 30, ethers.parseEther("0.0138"));
    expect(aliceTokens.length).to.equal(30);
    expect(new Set(aliceTokens).size).to.equal(30); // unique draws
    expect(await nft.mintCount(alice.address)).to.equal(30);
    expect(await nft.freeUsed(alice.address)).to.equal(true);
    const revAfter = await ethers.provider.getBalance(owner.address);
    expect(revAfter - revBefore).to.equal(ethers.parseEther("0.0138"));
    expect(await nft.deckRemaining()).to.equal(4444 - 1 - 30);
    expect(await nft.totalSupply()).to.equal(31);
    // 30-cap enforced
    await expect(nft.connect(alice)["mint(uint256)"](1, { value: ethers.parseEther("0.0002") }))
      .to.be.revertedWithCustomError(nft, "MaxPerWallet");
    await expect(nft.quoteBulk(alice.address, 1)).to.be.revertedWithCustomError(nft, "MaxPerWallet");
    // overpayment refunded in-tx (bob's 2nd mint: 0.001 sent, 0.0002 kept)
    const refundTx = nft.connect(bob)["mint(uint256)"](1, { value: ethers.parseEther("0.001") });
    await expect(refundTx).to.changeEtherBalance(bob, -ethers.parseEther("0.0002"));
    const refundRc = await (await refundTx).wait();
    for (const log of refundRc.logs) {
      try {
        const parsed = nft.interface.parseLog(log);
        if (parsed && parsed.name === "Minted") mintedIds.push(Number(parsed.args.tokenId));
      } catch (e) { /* not our event */ }
    }
  });

  it("$SNAKE claim: one per NFT, amount by rarity; guards hold", async function () {
    // Collect one token of each rarity, minting more if needed.
    const sample = {}; // rarity -> { owner, tokenId }
    async function scan(wallet, ids) {
      for (const id of ids) {
        const r = Number(await nft.rarityOf(id));
        if (sample[r] === undefined) sample[r] = { owner: wallet, tokenId: id };
      }
    }
    await scan(alice, aliceTokens);
    await scan(bob, [bobTokenId]);
    const wallets = [carol, dave, ...extraSigners];
    let wi = 0;
    while (Object.keys(sample).length < 4 && wi < wallets.length) {
      const w = wallets[wi++];
      await registry.mintTo(w.address);
      const ids = await mintBulk(w, 30, ethers.parseEther("0.0138"));
      await scan(w, ids);
    }
    expect(Object.keys(sample).length).to.equal(4, "need one token of each rarity");

    // Claim each rarity's token and check the exact amount.
    let totalClaimed = 0n;
    for (let r = 0; r < 4; r++) {
      const { owner: holder, tokenId } = sample[r];
      const want = ethers.parseEther(CLAIM_AMOUNTS[r]);
      expect(await snake.claimed(tokenId)).to.equal(false);
      const balBefore = await snake.balanceOf(holder.address);
      await snake.connect(holder)["claim(uint256)"](tokenId);
      expect(await snake.balanceOf(holder.address)).to.equal(balBefore + want);
      expect(await snake.claimed(tokenId)).to.equal(true);
      totalClaimed += want;
    }
    expect(await snake.totalClaimed()).to.equal(totalClaimed);

    // Double-claim reverts.
    await expect(snake.connect(sample[0].owner)["claim(uint256)"](sample[0].tokenId))
      .to.be.revertedWithCustomError(snake, "AlreadyClaimed");
    // Non-owner cannot claim someone else's (unclaimed) token.
    const otherUnclaimed = aliceTokens.find((id) => sample[0].tokenId !== id && !Object.values(sample).some((s) => s.tokenId === id));
    expect(otherUnclaimed).to.not.equal(undefined);
    await expect(snake.connect(bob)["claim(uint256)"](otherUnclaimed))
      .to.be.revertedWithCustomError(snake, "NotTokenOwner");
    // Unminted token cannot be claimed (ownerOf reverts).
    const mintedSet = new Set(mintedIds);
    let unminted = null;
    for (let id = 1; id <= 4444; id++) { if (!mintedSet.has(id)) { unminted = id; break; } }
    expect(unminted).to.not.equal(null);
    await expect(snake.connect(alice)["claim(uint256)"](unminted))
      .to.be.revertedWithCustomError(nft, "ERC721NonexistentToken");
    // Token without an NFT set cannot claim at all.
    const Snake2 = await ethers.getContractFactory("SnakeToken");
    const snake2 = await Snake2.deploy(owner.address);
    await expect(snake2.connect(alice)["claim(uint256)"](sample[0].tokenId))
      .to.be.revertedWithCustomError(snake2, "NftNotSet");
    // minter-gated mint(): owner is not a minter, NFT is.
    await expect(snake.connect(owner)["mint(address,uint256)"](alice.address, 1))
      .to.be.revertedWithCustomError(snake, "NotMinter");
    // cap: claiming can never exceed MAX_CLAIMABLE in total by construction
    // (68,900,000 < 100,000,000 cap); the cap itself is enforced by ERC20Capped.
    expect(await snake.MAX_CLAIMABLE()).to.be.lt(await snake.MAX_SUPPLY());
  });

  it("marketplace: list / buy (5% royalty) / cancel / updatePrice", async function () {
    expect(await nft.balanceOf(bob.address)).to.be.gte(1);
    await nft.connect(bob).setApprovalForAll(await market.getAddress(), true);
    await market.connect(bob).list(bobTokenId, ethers.parseEther("0.01"));
    expect(await market.getListedIds()).to.deep.equal([BigInt(bobTokenId)]);
    const [seller, price, active] = await market.getListing(bobTokenId);
    expect(seller).to.equal(bob.address);
    expect(price).to.equal(ethers.parseEther("0.01"));
    expect(active).to.equal(true);
    // buy: 5% royalty to owner, 95% to seller
    const revBefore = await ethers.provider.getBalance(owner.address);
    const bobBefore = await ethers.provider.getBalance(bob.address);
    await market.connect(carol).buy(bobTokenId, { value: ethers.parseEther("0.01") });
    expect(await nft.ownerOf(bobTokenId)).to.equal(carol.address);
    expect((await ethers.provider.getBalance(owner.address)) - revBefore).to.equal(ethers.parseEther("0.0005"));
    expect((await ethers.provider.getBalance(bob.address)) - bobBefore).to.equal(ethers.parseEther("0.0095"));
    expect(await market.getListedIds()).to.deep.equal([]);
    // cancel + updatePrice (carol must approve the marketplace first)
    await nft.connect(carol).setApprovalForAll(await market.getAddress(), true);
    await market.connect(carol).list(bobTokenId, ethers.parseEther("0.02"));
    await market.connect(carol).updatePrice(bobTokenId, ethers.parseEther("0.03"));
    expect((await market.getListing(bobTokenId))[1]).to.equal(ethers.parseEther("0.03"));
    await market.connect(carol).cancel(bobTokenId);
    expect(await nft.ownerOf(bobTokenId)).to.equal(carol.address);
    await expect(market.connect(carol).buy(bobTokenId, { value: ethers.parseEther("0.03") }))
      .to.be.revertedWith("not listed");
  });

  it("admin + views: royalty 5%, tokenURI format, withdraw safety valve, escape hatch", async function () {
    const [receiver, amount] = await nft.royaltyInfo(1, ethers.parseEther("1"));
    expect(receiver).to.equal(owner.address);
    expect(amount).to.equal(ethers.parseEther("0.05"));
    expect(await nft.supportsInterface("0x80ac58cd")).to.equal(true); // ERC721
    expect(await nft.supportsInterface("0x2a55205a")).to.equal(true); // ERC2981
    expect(await nft.tokenURI(bobTokenId)).to.equal(BASE_URI + bobTokenId + ".json");
    // force-send BNB (constructor selfdestruct works on Cancun) then withdraw
    const ForceCtor = await ethers.getContractFactory("MockForceSendCtor");
    await ForceCtor.deploy(await nft.getAddress(), { value: ethers.parseEther("0.5") });
    const revBefore = await ethers.provider.getBalance(owner.address);
    const tx = await nft.withdraw();
    const rc = await tx.wait();
    const gas = rc.gasUsed * rc.gasPrice;
    expect((await ethers.provider.getBalance(owner.address)) - revBefore + gas)
      .to.equal(ethers.parseEther("0.5"));
    await expect(nft.withdraw()).to.be.revertedWithCustomError(nft, "NoFunds");
    // agent-id check escape hatch
    await nft.setAgentIdCheckRequired(false);
    await nft.connect(noId)["mint(uint256)"](1, { value: 0 });
    await nft.setAgentIdCheckRequired(true);
    await expect(nft.connect(noId)["mint(uint256)"](1, { value: 0 })).to.be.revertedWithCustomError(nft, "NoAgentId");
  });
});
