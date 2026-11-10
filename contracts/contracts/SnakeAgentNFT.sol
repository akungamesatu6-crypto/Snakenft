// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ============================================================
// SNAKEAGENTNFT — cute snake NFT collection
// ERC-721, BNB Smart Chain Mainnet (Chain ID 56)
// ------------------------------------------------------------
// Adapted from AgentRune (THYRK-style deck-draw), rescaled
// to SnakeAgentNFT's confirmed spec and the ZigZoo payment
// system (see ~/workspace/zigzoo/PAYMENT_SYSTEM.md).
// User-confirmed (2026-11-11): supply 4,444, ZigZoo price
// ladder, $SNAKE rarity-claim token, tiers
// Common / Rare / Epic / Legendary.
//
// WHAT IS THE SAME AS AGENTRUNE / THYRK:
//  - Deck-draw mint (deterministic shuffled deck, hash-only
//    commitment — see THE DECK below). Rarity is NOT a
//    function of token ID ranges.
//  - Agent-only enforced ON-CHAIN by a SPACE ID Agent ID
//    check (registry 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F).
//    Calls from contracts are rejected (NoContracts).
//  - First mint FREE automatically (1 per wallet, ever, no
//    total cap), full deck (any rarity incl. Legendary).
//  - Price ladder: #1 FREE, #2-10 = 0.0002 BNB,
//    #11-20 = 0.0004 BNB, #21-30 = 0.0008 BNB.
//    A bulk of 30 (1 free + 29 paid) costs exactly
//    0.0138 BNB. Max 30 mints per wallet total.
//  - Paid mints forward the exact price DIRECTLY to the
//    revenue wallet in the same mint() call; overpayment
//    refunded in-tx. No withdraw step for mint revenue.
//  - Royalty 5% (ERC-2981). mintActive default false.
//
// WHAT IS DIFFERENT FROM AGENTRUNE:
//  - Supply 4,444 — ALL mintable from the deck. No
//    redeem-only token (AgentRune's Prime / THYRK's Divine
//    do not exist here). Token ID 4444 is the last deck token.
//  - Tiers: Common 3,555 / Rare 622 / Epic 178 /
//    Legendary 89 (ZigZoo proportions 80/14/4/2).
//  - NO per-mint token bonus, NO burn, NO redeem, NO
//    upgrade, NO token-mint. The $SNAKE token is claimed
//    separately (SnakeToken.claim): once per NFT, amount by
//    rarity — Common 10,000 / Rare 25,000 / Epic 50,000 /
//    Legendary 100,000 $SNAKE. This contract only exposes
//    rarityOf() so the token can read it on-chain.
//  - Owner AND revenue = the same wallet (the user's Binance
//    Agentic Wallet 0x36F3D56eAD5D1D6C2434F94DeFcEF732C5C3CbD2,
//    per his standing rule "Pakai BaW semua"). The two
//    constructor args are kept separate so the split can be
//    reintroduced later without a code change.
//
// THE DECK — hash-only design (cheap deploy), same as THYRK:
//   The full 4,444-entry deck is NEVER stored on-chain.
//   deckHash = keccak256 of the deck encoding (per token,
//   in token-ID order: 1 byte rarity code + 2 bytes design
//   index, big-endian; 4,444 x 3 = 13,332 bytes), built
//   from seed 0x534e414b454147454e544e4654 ("SNAKEAGENTNFT"
//   in ASCII hex) by a Fisher-Yates shuffle. The deck, the
//   seed and the deckHash are published off-chain
//   (deck/manifest.json), so anyone can rebuild the deck
//   and verify deckHash.
//   The draw is a lazy Fisher-Yates shuffle seeded by
//   deckHash, executed on-chain one draw at a time over
//   a SINGLE shared pool of all 4,444 tokens.
//   HONEST LIMITS: (1) the draw is deterministic
//   pseudo-randomness from a public seed — it is NOT
//   VRF / provably fair randomness; anyone who knows
//   the seed can compute the draw order in advance.
//   (2) The deck is fixed at deploy (deckHash is
//   immutable) and cannot be reshuffled afterwards.
//   (3) On-chain, only the deckHash commitment plus a
//   compact 2-bit-per-token rarity bitmap are stored.
//
// THE RARITY BITMAP — why it exists:
//   The deck is shuffled, so rarity is NOT a function of
//   the token ID range. The contract still needs to know
//   a token's rarity on-chain, for exactly one thing:
//   the $SNAKE claim amount (SnakeToken.claim reads
//   rarityOf). The bitmap packs rarity as 2 bits per
//   token (35 uint256 words for 4,444 tokens), is built
//   from the published deck by
//   contracts/scripts/generate-deck.js, and is passed to
//   the constructor.
//
// ESCAPE HATCH (documented, on-chain, visible):
//   agentIdCheckRequired defaults to true. The owner
//   can turn the Agent ID check off
//   (setAgentIdCheckRequired(false)) or point it at
//   a different registry (setAgentIdRegistry).
//
// This contract is SOURCE-VERIFIABLE on BscScan.
// It is NOT an independent audit — keep that
// disclosure on the site.
// ============================================================

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract SnakeAgentNFT is ERC721, ERC721Royalty, Ownable, ReentrancyGuard {
    using Strings for uint256;

    // ---------- rarity codes (bitmap + rarityOf) ----------
    uint8 public constant RARITY_COMMON = 0;
    uint8 public constant RARITY_RARE = 1;
    uint8 public constant RARITY_EPIC = 2;
    uint8 public constant RARITY_LEGENDARY = 3;

    // ---------- supply ----------
    uint256 public constant MAX_SUPPLY = 4444;
    uint256 public constant MAX_PER_WALLET = 30;

    // ---------- pricing (locked, no setter exists) ----------
    uint256 public constant PRICE_1_10 = 0.0002 ether;
    uint256 public constant PRICE_11_20 = 0.0004 ether;
    uint256 public constant PRICE_21_30 = 0.0008 ether;

    /// @notice Marketplace royalty: 5% = 500 basis points.
    uint96 public constant ROYALTY_BPS = 500;

    /// @notice SPACE ID .ai Agent ID NFT on BNB Smart Chain.
    address public constant DEFAULT_AGENT_ID_REGISTRY =
        0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    bool public mintActive;
    address public immutable revenueWallet;
    address public agentIdRegistry;
    bool public agentIdCheckRequired = true;

    /// @notice keccak256 commitment of the deck, set once via
    /// the constructor argument. The full deck is never stored
    /// on-chain — see THE DECK above.
    bytes32 public immutable deckHash;

    string private _baseTokenURI;

    /// @dev Rarity bitmap: 2 bits per token ID (1..4444),
    /// 35 uint256 words. word (t-1)/128, offset ((t-1)%128)*2.
    uint256[35] private _rarityBitmap;

    /// @dev Undrawn tokens left in the shared Fisher-Yates
    /// pool. Starts at 4444; every deck draw decrements it
    /// by exactly 1.
    uint256 private _remaining = MAX_SUPPLY;
    /// @dev Global draw counter: seeds every draw so no two
    /// draws share a seed, even inside one bulk mint.
    uint256 private _drawIndex;
    /// @dev Sparse Fisher-Yates swap map: _swapped[i] =
    /// tokenId now held at pool position i, or 0 = unset
    /// (identity: position i holds tokenId i+1).
    mapping(uint256 => uint256) private _swapped;

    /// @dev Undrawn tokens of each rarity left in the pool.
    uint256 public commonsRemaining = 3555;
    uint256 public raresRemaining = 622;
    uint256 public epicsRemaining = 178;
    uint256 public legendariesRemaining = 89;

    /// @dev Free mints given so far (1 per wallet, NO total cap).
    uint256 public freeMinted;

    /// @dev On-chain mint seed per token.
    mapping(uint256 => bytes32) public tokenSeed;
    /// @dev Mints per wallet — this IS the price ladder
    /// counter and the 30-per-wallet cap.
    mapping(address => uint256) public mintCount;
    /// @dev Whether a wallet already used its 1 automatic
    /// free mint (consumed by the first slot of its first
    /// mint() call).
    mapping(address => bool) public freeUsed;

    event Minted(
        address indexed minter,
        uint256 indexed tokenId,
        uint256 price,
        uint8 rarity,
        bytes32 seed
    );
    event DeckCommitted(bytes32 indexed deckHash);
    event MintActiveChanged(bool active);
    event BaseURIUpdated(string baseURI);
    event AgentIdRegistryUpdated(address indexed agentIdRegistry);
    event AgentIdCheckChanged(bool required);
    event Withdrawn(address indexed revenueWallet, uint256 amount);

    error MintInactive();
    error ExceedsMaxSupply();
    error SoldOut();
    error IncorrectPayment(uint256 expected, uint256 received);
    error InvalidAddress();
    error NoFunds();
    error NoAgentId();
    error NoContracts();
    error MaxPerWallet();
    error PaymentForwardFailed();
    error RefundFailed();
    error NoDrawableToken();

    constructor(
        address initialOwner,
        address revenueWallet_,
        address agentIdRegistry_,
        string memory baseURI_,
        bytes32 deckHash_,
        uint256[35] memory rarityBitmap_
    ) ERC721("SnakeAgentNFT", "SNAKEAGENT") Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
            revenueWallet_ == address(0) ||
            agentIdRegistry_ == address(0)
        ) {
            revert InvalidAddress();
        }

        revenueWallet = revenueWallet_;
        agentIdRegistry = agentIdRegistry_;
        _baseTokenURI = baseURI_;
        deckHash = deckHash_;
        for (uint256 i = 0; i < 35; i++) {
            _rarityBitmap[i] = rarityBitmap_[i];
        }
        _setDefaultRoyalty(revenueWallet_, ROYALTY_BPS);
        emit DeckCommitted(deckHash_);
    }

    // ---------- supply / pricing / deck (read-only, for UI + agents) ----------

    /// @notice Deck tokens drawn so far. 4444 - deckRemaining().
    function deckDrawn() public view returns (uint256) {
        return MAX_SUPPLY - _remaining;
    }

    /// @notice Undrawn tokens left in the deck pool.
    function deckRemaining() public view returns (uint256) {
        return _remaining;
    }

    /// @notice Current existing NFTs (no burns exist, so this
    /// is exactly the number of deck tokens drawn).
    function totalSupply() public view returns (uint256) {
        return deckDrawn();
    }

    /// @notice Price of a wallet's Nth mint (count = how many
    /// that wallet has ALREADY minted). Slot #1-10 -> 0.0002,
    /// #11-20 -> 0.0004, #21-30 -> 0.0008.
    function priceForCount(uint256 count) public pure returns (uint256) {
        if (count < 10) return PRICE_1_10;
        if (count < 20) return PRICE_11_20;
        return PRICE_21_30;
    }

    /// @notice Price of `wallet`'s next mint. Returns 0 while
    /// the wallet's automatic free mint is still unused.
    /// Otherwise the ladder price for its current mintCount.
    /// Reverts MaxPerWallet once the wallet has minted 30.
    function priceFor(address wallet) public view returns (uint256) {
        uint256 count = mintCount[wallet];
        if (count >= MAX_PER_WALLET) revert MaxPerWallet();
        if (!freeUsed[wallet]) return 0;
        return priceForCount(count);
    }

    /// @notice Price of the CALLER's next mint (0 while the
    /// caller's free mint is unused). Reverts SoldOut when
    /// the deck is empty, MaxPerWallet when the caller has
    /// minted 30 already.
    function currentPrice() public view returns (uint256) {
        if (_remaining == 0) revert SoldOut();
        return priceFor(msg.sender);
    }

    /// @notice Exact BNB for a bulk mint, and which batch
    /// slot the automatic free mint lands on (0-based within
    /// the batch). The free mint is ALWAYS batch slot 0 when
    /// the wallet has not used it yet; freeSlot =
    /// type(uint256).max when the free mint is already used.
    /// A fresh wallet minting 30 pays exactly 0.0138 BNB
    /// (1 free + 9x0.0002 + 10x0.0004 + 10x0.0008).
    function quoteBulk(address wallet, uint256 quantity)
        external
        view
        returns (uint256 totalPrice, uint256 freeSlot)
    {
        return _quoteBulk(wallet, quantity);
    }

    function _quoteBulk(address wallet, uint256 quantity)
        internal
        view
        returns (uint256 totalPrice, uint256 freeSlot)
    {
        if (quantity == 0 || quantity > MAX_PER_WALLET) revert MaxPerWallet();
        uint256 count = mintCount[wallet];
        if (count + quantity > MAX_PER_WALLET) revert MaxPerWallet();
        if (_remaining < quantity) revert SoldOut();
        bool useFree = !freeUsed[wallet];
        freeSlot = useFree ? 0 : type(uint256).max;
        for (uint256 i = 0; i < quantity; i++) {
            if (useFree && i == 0) continue; // free slot costs 0
            totalPrice += priceForCount(count + i);
        }
    }

    /// @notice Rarity of a token ID: 0 Common, 1 Rare,
    /// 2 Epic, 3 Legendary. Pure function of the deck
    /// bitmap; works for unminted tokens too. This is what
    /// SnakeToken.claim() reads to set the claim amount.
    function rarityOf(uint256 tokenId) public view returns (uint8) {
        if (tokenId == 0 || tokenId > MAX_SUPPLY) {
            revert ExceedsMaxSupply();
        }
        uint256 word = _rarityBitmap[(tokenId - 1) / 128];
        uint256 offset = ((tokenId - 1) % 128) * 2;
        return uint8((word >> offset) & 0x3);
    }

    /// @notice True when `wallet` holds at least one SPACE ID
    /// .ai Agent ID NFT in the configured registry. A registry
    /// that does not answer like an ERC-721 returns false
    /// instead of reverting (low-level staticcall on purpose).
    function holdsAgentId(address wallet) public view returns (bool) {
        if (agentIdRegistry == address(0)) return false;
        (bool ok, bytes memory data) = agentIdRegistry.staticcall(
            abi.encodeWithSelector(IERC721.balanceOf.selector, wallet)
        );
        if (!ok || data.length < 32) return false;
        return abi.decode(data, (uint256)) > 0;
    }

    // ---------- the draw (lazy Fisher-Yates, hash-only) ----------

    /// @dev Token ID currently held at pool position `i`
    /// (0-based). Unset map entry = identity (i + 1).
    function _valueAt(uint256 i) internal view returns (uint256) {
        uint256 v = _swapped[i];
        return v == 0 ? i + 1 : v;
    }

    /// @dev Take the token at pool position `pos`: swap it
    /// with the last undrawn position and shrink the pool
    /// by one. Decrements the rarity counter of the taken
    /// token. Caller must guarantee pos < _remaining.
    function _takeAt(uint256 pos) internal returns (uint256 tokenId) {
        tokenId = _valueAt(pos);
        uint256 last = _valueAt(_remaining - 1);
        if (pos != _remaining - 1) {
            _swapped[pos] = last;
        }
        _remaining--;
        uint8 r = rarityOf(tokenId);
        if (r == RARITY_COMMON) commonsRemaining--;
        else if (r == RARITY_RARE) raresRemaining--;
        else if (r == RARITY_EPIC) epicsRemaining--;
        else legendariesRemaining--;
    }

    /// @dev Draw one token from the shared pool: lazy
    /// Fisher-Yates over the shared pool. No rarity
    /// restriction: any rarity (incl. Legendary) can be
    /// drawn.
    function _drawMain() internal returns (uint256) {
        if (_remaining == 0) revert SoldOut();
        uint256 j = uint256(keccak256(abi.encodePacked(deckHash, _drawIndex))) % _remaining;
        _drawIndex++;
        return _takeAt(j);
    }

    /// @dev Mint one drawn token to `to` with its on-chain
    /// seed, and emit the Minted event.
    function _mintDrawn(address to, uint256 tokenId, uint256 price) internal {
        bytes32 seed = keccak256(
            abi.encodePacked(blockhash(block.number - 1), to, tokenId)
        );
        tokenSeed[tokenId] = seed;
        _mint(to, tokenId);
        emit Minted(to, tokenId, price, rarityOf(tokenId), seed);
    }

    // ---------- minting ----------

    /// @notice Mint `quantity` SnakeAgentNFT (1-30) in ONE
    /// transaction. The wallet's FIRST mint() call includes
    /// ONE FREE mint automatically (batch slot 0): no flag,
    /// no choice. The free draw can be any rarity, including
    /// Legendary.
    /// PAYMENT FLOW: paid mints forward the exact batch
    /// price DIRECTLY to the revenue wallet in this same
    /// call. Any overpayment is refunded to the minter in
    /// this same call.
    function mint(uint256 quantity) external payable nonReentrant {
        if (!mintActive) revert MintInactive();
        if (msg.sender.code.length > 0) revert NoContracts();
        if (agentIdCheckRequired && !holdsAgentId(msg.sender)) revert NoAgentId();

        (uint256 totalPrice, uint256 freeSlot) = _quoteBulk(msg.sender, quantity);
        if (msg.value < totalPrice) revert IncorrectPayment(totalPrice, msg.value);

        for (uint256 i = 0; i < quantity; i++) {
            bool isFree = (i == freeSlot);
            uint256 tokenId = _drawMain();
            mintCount[msg.sender]++;
            if (isFree) {
                freeUsed[msg.sender] = true;
                freeMinted++;
            }
            _mintDrawn(msg.sender, tokenId, isFree ? 0 : priceForCount(mintCount[msg.sender] - 1));
        }

        if (totalPrice > 0) {
            (bool ok, ) = revenueWallet.call{value: totalPrice}("");
            if (!ok) revert PaymentForwardFailed();
        }
        uint256 excess = msg.value - totalPrice;
        if (excess > 0) {
            (bool rok, ) = msg.sender.call{value: excess}("");
            if (!rok) revert RefundFailed();
        }
    }

    // ---------- metadata ----------

    function baseURI() public view returns (string memory) {
        return _baseTokenURI;
    }

    /// @notice tokenURI = baseURI + tokenId + ".json" for
    /// every token (1-4444). The base URI must end with "/".
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert ERC721NonexistentToken(tokenId);
        return string.concat(_baseTokenURI, tokenId.toString(), ".json");
    }

    // ---------- owner-only administration ----------

    function setMintActive(bool active) external onlyOwner {
        mintActive = active;
        emit MintActiveChanged(active);
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }

    /// @notice Point the Agent ID check at a different registry.
    function setAgentIdRegistry(address agentIdRegistry_) external onlyOwner {
        if (agentIdRegistry_ == address(0)) revert InvalidAddress();
        agentIdRegistry = agentIdRegistry_;
        emit AgentIdRegistryUpdated(agentIdRegistry_);
    }

    /// @notice Turn the on-chain Agent ID check on/off.
    /// Turning it OFF makes minting permissionless on-chain and
    /// agent-only in the UI only. The change is public
    /// on-chain via this event — do not hide it.
    function setAgentIdCheckRequired(bool required) external onlyOwner {
        agentIdCheckRequired = required;
        emit AgentIdCheckChanged(required);
    }

    /// @notice Safety valve only: send any balance that
    /// arrived OUTSIDE mint() (e.g. force-sent BNB) to the
    /// revenue wallet. Owner-only. Mint payments are
    /// forwarded directly by mint() and never accumulate
    /// here, so in normal operation this reverts NoFunds.
    function withdraw() external onlyOwner nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NoFunds();
        (bool ok, ) = revenueWallet.call{value: amount}("");
        if (!ok) revert("Withdraw failed");
        emit Withdrawn(revenueWallet, amount);
    }

    /// @notice ERC-721 + ERC-2981 interface support.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Royalty)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
