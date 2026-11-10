// Generate the SnakeAgentNFT deck (THYRK-style, hash-only design).
//
// Deck = 4,444 mintable tokens (Common 3,555 / Rare 622 /
// Epic 178 / Legendary 89). ALL 4,444 are in the deck —
// there is no redeem-only token (unlike AgentRune's Prime).
//
// Method (mirrors AgentRune / THYRK's documented design):
//   - Build the ordered multiset of (rarity, design) pairs
//     with EXACT per-design edition counts (BRIEF.md).
//   - Fisher-Yates shuffle with a deterministic keccak PRNG
//     seeded by the ASCII seed "SNAKEAGENTNFT".
//   - The shuffled list IS the deck: deck[i] is token ID i+1.
//   - deckHash = keccak256(deck encoding), per token in token-ID
//     order: 1 byte rarity code + 2 bytes design index (BE).
//     4,444 x 3 = 13,332 bytes.
//   - Rarity bitmap: 2 bits per token ID (1..4,444), 35 uint256
//     words. word (t-1)/128, offset ((t-1)%128)*2.
// Anyone can rebuild deck + deckHash + bitmap from the seed and
// this script and verify they match the on-chain commitment.
//
// Design indices (global, 0-10) — from BRIEF.md:
//   Common    (0): 0 Blue, 1 Green, 2 Yellow, 3 Pink, 4 Teal
//   Rare      (1): 5 Purple, 6 Orange
//   Epic      (2): 7 Golden, 8 Silver
//   Legendary (3): 9 Dragon, 10 Phoenix
// Per-design editions: Common 711 each (5 x 711 = 3,555);
// Rare 311 each (2 x 311 = 622); Epic 89 each (2 x 89 = 178);
// Legendary Dragon 45 + Phoenix 44 = 89.

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const SEED_ASCII = "SNAKEAGENTNFT";
const SEED = ethers.toUtf8Bytes(SEED_ASCII);

const RARITY = { COMMON: 0, RARE: 1, EPIC: 2, LEGENDARY: 3 };
const RARITY_NAMES = ["Common", "Rare", "Epic", "Legendary"];

// design: { name, file, rarity, editions }
const DESIGNS = [
  { name: "Blue", file: "hero-snake.png", rarity: RARITY.COMMON, editions: 711 },
  { name: "Green", file: "tier-common-green.webp", rarity: RARITY.COMMON, editions: 711 },
  { name: "Yellow", file: "tier-common-yellow.webp", rarity: RARITY.COMMON, editions: 711 },
  { name: "Pink", file: "tier-common-pink.webp", rarity: RARITY.COMMON, editions: 711 },
  { name: "Teal", file: "tier-common-teal.webp", rarity: RARITY.COMMON, editions: 711 },
  { name: "Purple", file: "tier-rare-purple.webp", rarity: RARITY.RARE, editions: 311 },
  { name: "Orange", file: "tier-rare-orange.webp", rarity: RARITY.RARE, editions: 311 },
  { name: "Golden", file: "tier-epic-golden.webp", rarity: RARITY.EPIC, editions: 89 },
  { name: "Silver", file: "tier-epic-silver.webp", rarity: RARITY.EPIC, editions: 89 },
  { name: "Dragon", file: "tier-legendary-dragon.webp", rarity: RARITY.LEGENDARY, editions: 45 },
  { name: "Phoenix", file: "tier-legendary-phoenix.webp", rarity: RARITY.LEGENDARY, editions: 44 },
];
const EXPECTED_COUNTS = { 0: 3555, 1: 622, 2: 178, 3: 89 };

// Deterministic PRNG: keccak256(seed || counter32) mod n.
let counter = 0;
function randBelow(n) {
  const h = ethers.keccak256(ethers.concat([SEED, ethers.toBeHex(counter, 32)]));
  counter++;
  return Number(BigInt(h) % BigInt(n));
}

function main() {
  // 1. Ordered multiset with exact per-design editions.
  const deck = [];
  DESIGNS.forEach((d, designIndex) => {
    for (let i = 0; i < d.editions; i++) {
      deck.push({ rarity: d.rarity, design: d.name, designIndex, file: d.file });
    }
  });
  console.log("deck size:", deck.length);
  if (deck.length !== 4444) throw new Error("deck size must be 4444");

  // 2. Fisher-Yates shuffle (deterministic).
  for (let i = deck.length - 1; i > 0; i--) {
    const j = randBelow(i + 1);
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }

  // 3. Encode + deckHash.
  const encoded = Buffer.alloc(deck.length * 3);
  deck.forEach((e, idx) => {
    encoded[idx * 3] = e.rarity;
    encoded.writeUInt16BE(e.designIndex, idx * 3 + 1);
  });
  const deckHash = ethers.keccak256(encoded);
  console.log("deckHash:", deckHash);

  // 4. Rarity bitmap (35 words).
  const WORDS = 35;
  const bitmap = new Array(WORDS).fill(0n);
  deck.forEach((e, idx) => {
    const t = idx + 1;
    const word = Math.floor((t - 1) / 128);
    const offset = BigInt(((t - 1) % 128) * 2);
    bitmap[word] |= BigInt(e.rarity) << offset;
  });
  const bitmapHex = bitmap.map((w) => "0x" + w.toString(16).padStart(64, "0"));

  // 5. Verify round-trip: bitmap decodes to the deck rarities.
  for (let t = 1; t <= deck.length; t++) {
    const word = Math.floor((t - 1) / 128);
    const offset = BigInt(((t - 1) % 128) * 2);
    const r = Number((bitmap[word] >> offset) & 0x3n);
    if (r !== deck[t - 1].rarity) throw new Error(`bitmap mismatch at token ${t}`);
  }
  // Verify rarity counts.
  const counts = [0, 0, 0, 0];
  deck.forEach((e) => counts[e.rarity]++);
  console.log("rarity counts:", counts.map((c, i) => `${RARITY_NAMES[i]} ${c}`).join(" / "));
  for (const [r, want] of Object.entries(EXPECTED_COUNTS)) {
    if (counts[Number(r)] !== want) throw new Error(`rarity ${RARITY_NAMES[r]} count ${counts[Number(r)]} != ${want}`);
  }
  // Verify per-design counts.
  const designCounts = new Array(DESIGNS.length).fill(0);
  deck.forEach((e) => designCounts[e.designIndex]++);
  DESIGNS.forEach((d, i) => {
    if (designCounts[i] !== d.editions) throw new Error(`design ${d.name} count ${designCounts[i]} != ${d.editions}`);
  });
  console.log("per-design counts:", DESIGNS.map((d, i) => `${d.name} ${designCounts[i]}`).join(" / "));
  // Verify deckHash recomputation.
  if (ethers.keccak256(encoded) !== deckHash) throw new Error("deckHash mismatch");

  // 6. Write outputs.
  const outDir = path.join(__dirname, "..", "..", "deck");
  fs.mkdirSync(outDir, { recursive: true });
  const manifest = {
    project: "SnakeAgentNFT",
    seedAscii: SEED_ASCII,
    seedHex: ethers.hexlify(SEED),
    deckSize: deck.length,
    totalSupply: 4444,
    deckHash,
    rarityBitmapWords: WORDS,
    rarityBitmap: bitmapHex,
    tiers: [0, 1, 2, 3].map((r) => ({
      rarity: RARITY_NAMES[r],
      count: counts[r],
      designs: DESIGNS.filter((d) => d.rarity === r).map((d) => ({
        name: d.name,
        designIndex: DESIGNS.indexOf(d),
        file: d.file,
        editions: d.editions,
      })),
    })),
    // tokenId (1-based) -> { rarity, design, designIndex }
    tokens: deck.map((e, idx) => ({
      tokenId: idx + 1,
      rarity: RARITY_NAMES[e.rarity],
      design: e.design,
      designIndex: e.designIndex,
      file: e.file,
    })),
  };
  fs.writeFileSync(path.join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2));
  fs.writeFileSync(path.join(outDir, "deckHash.txt"), deckHash + "\n");
  fs.writeFileSync(path.join(outDir, "bitmap.json"), JSON.stringify(bitmapHex, null, 2));
  console.log("wrote", path.join(outDir, "manifest.json"));
  console.log("bitmap words:", WORDS);
}

main();
