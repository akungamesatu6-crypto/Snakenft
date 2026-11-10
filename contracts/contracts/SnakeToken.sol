// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// $SNAKE — the SnakeAgentNFT utility token (BEP-20 / ERC-20)
// BNB Smart Chain Mainnet (Chain ID 56)
// ------------------------------------------------------------
// - Name "Snake", symbol "SNAKE", 18 decimals.
// - Max supply 100,000,000, enforced on-chain by ERC20Capped.
//   NOTHING may mint above the cap, from any source.
//   The reserve is NEVER pre-minted to anyone.
// - How $SNAKE is created (ZigZoo-style rarity claim):
//   Hold a SnakeAgentNFT and call claim(tokenId) ONCE per NFT.
//   The amount depends on that NFT's rarity (read on-chain
//   from the NFT contract's deck bitmap via rarityOf):
//     Common    (rarity 0): 10,000 $SNAKE
//     Rare      (rarity 1): 25,000 $SNAKE
//     Epic      (rarity 2): 50,000 $SNAKE
//     Legendary (rarity 3): 100,000 $SNAKE
//   Max total claimable across all 4,444 NFTs:
//     3,555 x 10,000 + 622 x 25,000 + 178 x 50,000
//     + 89 x 100,000 = 68,900,000 $SNAKE.
//   The remaining 31,100,000 up to the cap is RESERVE and
//   is never minted by this contract.
// - Claim rules:
//   * One claim per NFT, ever. claimed[tokenId] is set
//     before minting, so a double-claim always reverts.
//   * Only the NFT's current owner can claim for it
//     (checked against nft.ownerOf(tokenId)).
//   * Unminted / nonexistent tokens cannot be claimed
//     (ownerOf reverts for them).
// - Minting is restricted to authorized minters (the
//   SnakeAgentNFT contract, set after deploy via
//   setMinter). The owner manages the minter list; the
//   owner itself cannot mint.
// - The NFT contract address is set by the owner AFTER
//   the NFT deploys (setNft), because the token deploys
//   first. claim() reverts until it is set.
// - Owner = deployer wallet. Deploy this contract FIRST,
//   then SnakeAgentNFT with this contract's address (the
//   NFT does not need the token address), then call
//   setMinter(nft, true) and setNft(nft).
//
// This contract is SOURCE-VERIFIABLE on BscScan.
// It is NOT an independent audit — keep that
// disclosure on the site.
// ============================================================

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ISnakeAgentNFT is IERC721 {
    function rarityOf(uint256 tokenId) external view returns (uint8);
}

contract SnakeToken is ERC20, ERC20Burnable, ERC20Capped, Ownable {
    /// @notice Hard cap: 100,000,000 $SNAKE. Enforced by ERC20Capped
    /// on every mint. Max creatable from claims is 68,900,000;
    /// the rest is RESERVE and is never minted by this contract.
    uint256 public constant MAX_SUPPLY = 100_000_000 ether;

    /// @notice Max total claimable across all 4,444 NFTs.
    uint256 public constant MAX_CLAIMABLE = 68_900_000 ether;

    /// @notice One-time claim amounts per NFT rarity
    /// (rarity codes match SnakeAgentNFT.rarityOf:
    /// 0 Common, 1 Rare, 2 Epic, 3 Legendary).
    uint256 public constant CLAIM_COMMON = 10_000 ether;
    uint256 public constant CLAIM_RARE = 25_000 ether;
    uint256 public constant CLAIM_EPIC = 50_000 ether;
    uint256 public constant CLAIM_LEGENDARY = 100_000 ether;

    /// @notice Addresses allowed to mint (SnakeAgentNFT).
    /// Managed by the owner.
    mapping(address => bool) public minters;

    /// @notice The SnakeAgentNFT contract. Set by the owner
    /// after the NFT deploys. claim() reverts until set.
    address public nft;

    /// @notice tokenId => already claimed (one claim per NFT, ever).
    mapping(uint256 => bool) public claimed;

    /// @notice Total $SNAKE claimed so far (for the UI).
    uint256 public totalClaimed;

    event MinterSet(address indexed minter, bool allowed);
    event NftSet(address indexed nft);
    event Claimed(address indexed claimer, uint256 indexed tokenId, uint8 rarity, uint256 amount);

    error NotMinter();
    error NftNotSet();
    error AlreadyClaimed(uint256 tokenId);
    error NotTokenOwner();
    error InvalidAddress();
    error InvalidRarity(uint8 rarity);

    constructor(address initialOwner)
        ERC20("Snake", "SNAKE")
        ERC20Capped(MAX_SUPPLY)
        Ownable(initialOwner)
    {}

    /// @notice Cap enforcement: ERC20Capped checks totalSupply
    /// + value <= cap on every mint (via _update).
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Capped)
    {
        super._update(from, to, value);
    }

    /// @notice Authorize / revoke a minter (SnakeAgentNFT).
    /// Owner-only.
    function setMinter(address minter, bool allowed) external onlyOwner {
        minters[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    /// @notice Point this token at the SnakeAgentNFT contract.
    /// Owner-only. Called once after the NFT deploys.
    function setNft(address nft_) external onlyOwner {
        if (nft_ == address(0)) revert InvalidAddress();
        nft = nft_;
        emit NftSet(nft_);
    }

    /// @notice Claim amount for a rarity code (0 Common,
    /// 1 Rare, 2 Epic, 3 Legendary). Reverts on any other code.
    function claimAmount(uint8 rarity) public pure returns (uint256) {
        if (rarity == 0) return CLAIM_COMMON;
        if (rarity == 1) return CLAIM_RARE;
        if (rarity == 2) return CLAIM_EPIC;
        if (rarity == 3) return CLAIM_LEGENDARY;
        revert InvalidRarity(rarity);
    }

    /// @notice Mint $SNAKE to `to`. Only authorized minters
    /// (SnakeAgentNFT). The cap is enforced by ERC20Capped.
    function mint(address to, uint256 amount) external {
        if (!minters[msg.sender]) revert NotMinter();
        _mint(to, amount);
    }

    /// @notice Claim the one-time $SNAKE amount for the NFT
    /// `tokenId`. Only the NFT's current owner can call it,
    /// and each NFT can be claimed exactly once. The amount
    /// is set by the NFT's rarity, read on-chain from the
    /// NFT contract's deck bitmap.
    function claim(uint256 tokenId) external {
        if (nft == address(0)) revert NftNotSet();
        if (claimed[tokenId]) revert AlreadyClaimed(tokenId);
        ISnakeAgentNFT nftContract = ISnakeAgentNFT(nft);
        if (nftContract.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        uint8 rarity = nftContract.rarityOf(tokenId);
        uint256 amount = claimAmount(rarity);
        claimed[tokenId] = true;
        totalClaimed += amount;
        _mint(msg.sender, amount);
        emit Claimed(msg.sender, tokenId, rarity, amount);
    }
}
