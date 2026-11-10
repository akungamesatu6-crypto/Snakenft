// Generate SnakeAgentNFT metadata from the deck manifest.
// Output: metadata/<id>.json for tokens 1..4444.
// Matches SnakeAgentNFT.sol tokenURI: baseURI + tokenId + ".json".
// Image base: the repo assets path (raw.githubusercontent.com).
// NOTE: if the Vercel project domain is chosen later, change
// IMAGE_BASE below and regenerate — metadata image URLs are
// baked into these files.

const fs = require("fs");
const path = require("path");

const manifest = require("../../deck/manifest.json");
const outDir = path.join(__dirname, "..", "..", "metadata");
fs.mkdirSync(outDir, { recursive: true });

const IMAGE_BASE = "https://raw.githubusercontent.com/akungamesatu6-crypto/Snakenft/main/assets/";

// Per-design edition totals, from the manifest tiers.
const EDITION_TOTALS = {};
for (const tier of manifest.tiers) {
  for (const d of tier.designs) EDITION_TOTALS[d.name] = d.editions;
}

// Per-design serial: the token's position (1-based) among all
// tokens of the same design, in token-ID order.
const serialSeen = {};
function editionLabel(token) {
  const n = (serialSeen[token.design] = (serialSeen[token.design] || 0) + 1);
  return `${n} of ${EDITION_TOTALS[token.design]}`;
}

function metaFor(token) {
  const edition = editionLabel(token);
  return {
    name: `SnakeAgentNFT #${token.tokenId}`,
    description: `A cute ${token.design} snake on a tropical beach — ${token.rarity} tier, edition ${edition}. One of 4,444. Minted by agents, living the island life.`,
    image: IMAGE_BASE + token.file,
    attributes: [
      { trait_type: "Rarity", value: token.rarity },
      { trait_type: "Design", value: token.design },
      { trait_type: "Edition", value: edition },
    ],
  };
}

let written = 0;
for (const t of manifest.tokens) {
  const meta = metaFor(t);
  fs.writeFileSync(path.join(outDir, `${t.tokenId}.json`), JSON.stringify(meta));
  written++;
}

// Verify
const files = fs.readdirSync(outDir);
console.log("metadata files written:", written, "| files on disk:", files.length);
if (files.length !== 4444) throw new Error("expected 4444 metadata files");
const sample1 = JSON.parse(fs.readFileSync(path.join(outDir, "1.json"), "utf-8"));
console.log("sample #1:", JSON.stringify(sample1));
// Cross-check every token's tier/design/image against the manifest
const seen = {};
for (const t of manifest.tokens) {
  const m = JSON.parse(fs.readFileSync(path.join(outDir, `${t.tokenId}.json`), "utf-8"));
  if (m.name !== `SnakeAgentNFT #${t.tokenId}`) throw new Error(`name mismatch at token ${t.tokenId}`);
  if (m.attributes[0].value !== t.rarity || m.attributes[1].value !== t.design) {
    throw new Error(`tier/design mismatch at token ${t.tokenId}`);
  }
  if (m.image !== IMAGE_BASE + t.file) throw new Error(`image mismatch at token ${t.tokenId}`);
  const wantTotal = EDITION_TOTALS[t.design];
  const edition = m.attributes[2].value;
  const match = edition.match(/^(\d+) of (\d+)$/);
  if (!match || Number(match[2]) !== wantTotal) throw new Error(`edition mismatch at token ${t.tokenId}`);
  const key = `${t.design}:${match[1]}`;
  if (seen[key]) throw new Error(`duplicate edition serial at token ${t.tokenId}`);
  seen[key] = true;
}
console.log("all 4,444 metadata verified against manifest");
