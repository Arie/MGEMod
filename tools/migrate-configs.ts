#!/usr/bin/env bun
/**
 * Migration script for MGE arena config files.
 *
 * Two modes:
 *
 * 1. Per-file migration (default):
 *    bun run tools/migrate-configs.ts [configDir]
 *    Converts per-map .cfg files in-place from old key names / boolean
 *    gamemode flags to the new self-documenting format.
 *    Default configDir: addons/sourcemod/configs/mge
 *
 * 2. Split monolithic mgemod_spawns.cfg into per-map files:
 *    bun run tools/migrate-configs.ts --split <spawnsFile> [outputDir]
 *    Reads the original MGEMod all-in-one spawns file where maps are
 *    top-level keys, splits each map into its own <mapname>.cfg, and
 *    migrates every arena to the new format.
 *    Default outputDir: addons/sourcemod/configs/mge
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "fs";
import { basename, join, resolve } from "path";

// ---------------------------------------------------------------------------
// Valve KeyValues parser / serializer
// ---------------------------------------------------------------------------

type KVSection = { keys: [string, string | KVSection][] };

function parseKV(src: string): KVSection {
  let pos = 0;

  function skipWhitespaceAndComments() {
    while (pos < src.length) {
      const ch = src[pos];
      if (ch === " " || ch === "\t" || ch === "\r" || ch === "\n") {
        pos++;
      } else if (src[pos] === "/" && src[pos + 1] === "/") {
        while (pos < src.length && src[pos] !== "\n") pos++;
      } else {
        break;
      }
    }
  }

  function readQuotedString(): string {
    if (src[pos] !== '"') throw new Error(`Expected '"' at pos ${pos}, got '${src[pos]}'`);
    pos++; // skip opening quote
    let result = "";
    while (pos < src.length && src[pos] !== '"') {
      if (src[pos] === "\\" && pos + 1 < src.length) {
        pos++;
        result += src[pos];
      } else {
        result += src[pos];
      }
      pos++;
    }
    if (src[pos] !== '"') throw new Error(`Unterminated string at pos ${pos}`);
    pos++; // skip closing quote
    return result;
  }

  function readUnquotedString(): string {
    let result = "";
    while (pos < src.length && src[pos] !== " " && src[pos] !== "\t" &&
           src[pos] !== "\r" && src[pos] !== "\n" && src[pos] !== "{" && src[pos] !== "}") {
      result += src[pos];
      pos++;
    }
    return result;
  }

  function readToken(): string {
    skipWhitespaceAndComments();
    if (pos >= src.length) throw new Error("Unexpected end of input");
    return src[pos] === '"' ? readQuotedString() : readUnquotedString();
  }

  function readSection(): KVSection {
    const section: KVSection = { keys: [] };
    while (true) {
      skipWhitespaceAndComments();
      if (pos >= src.length || src[pos] === "}") break;

      const key = readToken();
      skipWhitespaceAndComments();

      if (pos < src.length && src[pos] === "{") {
        pos++; // skip {
        const sub = readSection();
        skipWhitespaceAndComments();
        if (src[pos] === "}") pos++; // skip }
        section.keys.push([key, sub]);
      } else {
        const value = readToken();
        section.keys.push([key, value]);
      }
    }
    return section;
  }

  const root = readSection();
  return root;
}

function serializeKV(section: KVSection, indent: number = 0): string {
  const pad = "    ".repeat(indent);
  const lines: string[] = [];

  for (const [key, value] of section.keys) {
    if (typeof value === "string") {
      const paddedKey = `"${key}"`;
      const paddedVal = `"${value}"`;
      lines.push(`${pad}${paddedKey.padEnd(24)}${paddedVal}`);
    } else {
      if (indent === 2) lines.push(""); // blank line before spawns/entities inside arenas
      lines.push(`${pad}"${key}"`);
      lines.push(`${pad}{`);
      lines.push(serializeKV(value, indent + 1));
      lines.push(`${pad}}`);
    }
  }

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Key renaming map
// ---------------------------------------------------------------------------

const KEY_MAP: Record<string, string> = {
  fraglimit: "frag_limit",
  caplimit: "cap_limit",
  hpratio: "hp_multiplier",
  cdtime: "countdown_seconds",
  infammo: "infinite_ammo",
  showhp: "show_hp",
  mindist: "min_spawn_distance",
  earlyleave: "early_leave_threshold",
  vishoop: "visible_hoops",
  boostvectors: "knockback_boost",
  allowkoth: "allow_koth_switch",
  kothteamspawn: "koth_team_spawns",
  classchange: "allow_class_change",
  respawntime: "respawn_delay",
  minrating: "min_elo",
  maxrating: "max_elo",
  timer: "koth_round_time",
  classes: "allowed_classes",
  airshotheight: "airshot_min_height",
};

const GAMEMODE_BOOLEANS = [
  "ultiduo", "bball", "koth", "mge", "ammomod", "midair", "endif", "turris",
];

const DEAD_KEYS = new Set([
  "cap", "cap_trigger",
  ...GAMEMODE_BOOLEANS,
  "4player", "allowchange",
]);

// ---------------------------------------------------------------------------
// Migration logic per arena
// ---------------------------------------------------------------------------

interface SpawnEntry {
  index: number;
  coords: string;
}

function isNumericKey(key: string): boolean {
  return /^\d+$/.test(key);
}

function detectGamemode(arenaKeys: [string, string | KVSection][]): string {
  const flags = new Map<string, string>();
  for (const [k, v] of arenaKeys) {
    if (typeof v === "string") flags.set(k.toLowerCase(), v);
  }

  for (const mode of GAMEMODE_BOOLEANS) {
    if (flags.get(mode) === "1") return mode;
  }
  return "mge";
}

function computeTeamSize(arenaKeys: [string, string | KVSection][]): string {
  const flags = new Map<string, string>();
  for (const [k, v] of arenaKeys) {
    if (typeof v === "string") flags.set(k.toLowerCase(), v);
  }

  const fourPlayer = flags.get("4player") === "1";
  const allowChange = flags.get("allowchange") === "1";

  if (!fourPlayer && !allowChange) return "1v1";
  if (!fourPlayer && allowChange) return "1v1 2v2";
  if (fourPlayer && !allowChange) return "2v2";
  return "2v2 1v1"; // fourPlayer && allowChange
}

function migrateArena(
  arenaName: string,
  arenaKeys: [string, string | KVSection][],
): KVSection {
  const gamemode = detectGamemode(arenaKeys);
  const teamSize = computeTeamSize(arenaKeys);

  // Collect numbered spawns and settings separately
  const spawns: SpawnEntry[] = [];
  const settings: [string, string][] = [];

  for (const [key, value] of arenaKeys) {
    if (typeof value !== "string") continue;
    const lower = key.toLowerCase();

    if (isNumericKey(key)) {
      spawns.push({ index: parseInt(key, 10), coords: value });
    } else if (DEAD_KEYS.has(lower)) {
      // skip dead keys
    } else if (KEY_MAP[lower]) {
      settings.push([KEY_MAP[lower], value]);
    } else {
      settings.push([key, value]);
    }
  }

  spawns.sort((a, b) => a.index - b.index);
  const N = spawns.length;

  // Extract entities from spawn tails
  let playerSpawns: SpawnEntry[];
  const entities: [string, string][] = [];

  if (gamemode === "bball" && N >= 6) {
    // Last 5 are entities: intel_start, intel_red, intel_blu, hoop_red, hoop_blu
    playerSpawns = spawns.slice(0, N - 5);
    entities.push(["intel_start", spawns[N - 5].coords]);
    entities.push(["intel_red", spawns[N - 4].coords]);
    entities.push(["intel_blu", spawns[N - 3].coords]);
    entities.push(["hoop_red", spawns[N - 2].coords]);
    entities.push(["hoop_blu", spawns[N - 1].coords]);
  } else if (gamemode === "koth" || gamemode === "ultiduo") {
    // Last spawn is capture_point
    playerSpawns = spawns.slice(0, N - 1);
    entities.push(["capture_point", spawns[N - 1].coords]);
  } else {
    playerSpawns = spawns;
  }

  // Determine whether to use red/blu or flat format
  const supports2v2 = teamSize.includes("2v2");

  // Build the new arena section
  const result: KVSection = { keys: [] };

  // Gamemode and team_size always first
  result.keys.push(["gamemode", gamemode]);
  result.keys.push(["team_size", teamSize]);

  // Settings
  for (const [k, v] of settings) {
    result.keys.push([k, v]);
  }

  // Spawns subsection
  if (supports2v2 && playerSpawns.length >= 2) {
    const mid = Math.floor(playerSpawns.length / 2);
    const redSpawns = playerSpawns.slice(0, mid);
    const bluSpawns = playerSpawns.slice(mid);

    const redSection: KVSection = { keys: [] };
    redSpawns.forEach((s, i) => redSection.keys.push([String(i + 1), s.coords]));

    const bluSection: KVSection = { keys: [] };
    bluSpawns.forEach((s, i) => bluSection.keys.push([String(i + 1), s.coords]));

    const spawnsSection: KVSection = { keys: [] };
    spawnsSection.keys.push(["red", redSection]);
    spawnsSection.keys.push(["blu", bluSection]);

    result.keys.push(["spawns", spawnsSection]);
  } else {
    const spawnsSection: KVSection = { keys: [] };
    playerSpawns.forEach((s, i) => spawnsSection.keys.push([String(i + 1), s.coords]));
    result.keys.push(["spawns", spawnsSection]);
  }

  // Entities subsection
  if (entities.length > 0) {
    const entSection: KVSection = { keys: [] };
    for (const [k, v] of entities) {
      entSection.keys.push([k, v]);
    }
    result.keys.push(["entities", entSection]);
  }

  // Emit warnings for ultiduo arenas
  if (gamemode === "ultiduo") {
    console.warn(
      `  [WARN] "${arenaName}": ultiduo arena migrated with plain red/blu spawns. ` +
      `Manual class-spawn fixup (soldier/medic subsections) required.`
    );
  }

  return result;
}

// ---------------------------------------------------------------------------
// File processing
// ---------------------------------------------------------------------------

function migrateFile(filePath: string): { arenaCount: number } {
  let src = readFileSync(filePath, "utf-8");
  // Strip BOM if present
  if (src.charCodeAt(0) === 0xfeff) src = src.slice(1);
  let parsed: KVSection;
  try {
    parsed = parseKV(src);
  } catch (e) {
    console.error(`  [ERROR] Failed to parse ${filePath}: ${e}`);
    return { arenaCount: 0 };
  }

  // The root has an unquoted `SpawnConfigs` key wrapping all arenas.
  // After parsing, it becomes the sole entry in the root section.
  let rootSection: KVSection;

  const firstEntry = parsed.keys[0];
  if (
    firstEntry &&
    typeof firstEntry[1] !== "string" &&
    parsed.keys.length === 1 &&
    /^SpawnConfig/i.test(firstEntry[0])
  ) {
    rootSection = firstEntry[1] as KVSection;
  } else {
    rootSection = parsed;
  }

  const newRoot: KVSection = { keys: [] };
  let arenaCount = 0;

  for (const [arenaName, arenaValue] of rootSection.keys) {
    if (typeof arenaValue === "string") continue; // skip non-section entries
    const arena = arenaValue as KVSection;

    // Check if this arena is already migrated (has "gamemode" key)
    const hasGamemode = arena.keys.some(([k]) => k.toLowerCase() === "gamemode");
    if (hasGamemode) {
      // Already in new format, pass through
      newRoot.keys.push([arenaName, arena]);
      arenaCount++;
      continue;
    }

    const migrated = migrateArena(arenaName, arena.keys);
    newRoot.keys.push([arenaName, migrated]);
    arenaCount++;
  }

  // Write output
  const output = `SpawnConfigs\n{\n${serializeKV(newRoot, 1)}\n}\n`;
  writeFileSync(filePath, output, "utf-8");

  return { arenaCount };
}

// ---------------------------------------------------------------------------
// Split monolithic mgemod_spawns.cfg into per-map files
// ---------------------------------------------------------------------------

function splitMonolithicFile(
  spawnsFile: string,
  outputDir: string,
): { mapCount: number; arenaCount: number } {
  let src = readFileSync(spawnsFile, "utf-8");
  if (src.charCodeAt(0) === 0xfeff) src = src.slice(1);

  let parsed: KVSection;
  try {
    parsed = parseKV(src);
  } catch (e) {
    console.error(`Failed to parse ${spawnsFile}: ${e}`);
    process.exit(1);
  }

  // Unwrap the SpawnConfigs root key
  let rootSection: KVSection;
  const firstEntry = parsed.keys[0];
  if (
    firstEntry &&
    typeof firstEntry[1] !== "string" &&
    parsed.keys.length === 1 &&
    /^SpawnConfig/i.test(firstEntry[0])
  ) {
    rootSection = firstEntry[1] as KVSection;
  } else {
    rootSection = parsed;
  }

  if (!existsSync(outputDir)) {
    mkdirSync(outputDir, { recursive: true });
  }

  // Deduplicate map names: the file can have the same map key twice
  // (e.g. mge_rework_v1 appears at two different points). Merge arenas.
  const mapArenas = new Map<string, [string, KVSection][]>();

  for (const [mapName, mapValue] of rootSection.keys) {
    if (typeof mapValue === "string") continue;
    const mapSection = mapValue as KVSection;

    if (!mapArenas.has(mapName)) {
      mapArenas.set(mapName, []);
    }
    const arenas = mapArenas.get(mapName)!;

    for (const [arenaName, arenaValue] of mapSection.keys) {
      if (typeof arenaValue === "string") continue;
      arenas.push([arenaName, arenaValue as KVSection]);
    }
  }

  let mapCount = 0;
  let arenaCount = 0;

  for (const [mapName, arenas] of mapArenas) {
    const newRoot: KVSection = { keys: [] };

    for (const [arenaName, arena] of arenas) {
      const hasGamemode = arena.keys.some(([k]) => k.toLowerCase() === "gamemode");
      if (hasGamemode) {
        newRoot.keys.push([arenaName, arena]);
      } else {
        const migrated = migrateArena(arenaName, arena.keys);
        newRoot.keys.push([arenaName, migrated]);
      }
      arenaCount++;
    }

    const outPath = join(outputDir, `${mapName}.cfg`);
    const output = `SpawnConfigs\n{\n${serializeKV(newRoot, 1)}\n}\n`;
    writeFileSync(outPath, output, "utf-8");
    console.log(`  ${outPath} (${arenas.length} arenas)`);
    mapCount++;
  }

  return { mapCount, arenaCount };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

function main() {
  const args = process.argv.slice(2);

  if (args[0] === "--split") {
    const spawnsFile = resolve(args[1] ?? "tools/mgemod_spawns.cfg");
    const outputDir = resolve(args[2] ?? "addons/sourcemod/configs/mge");

    console.log(`Splitting ${spawnsFile} into per-map configs in ${outputDir}\n`);
    const { mapCount, arenaCount } = splitMonolithicFile(spawnsFile, outputDir);
    console.log(`\nDone. Created ${mapCount} map files with ${arenaCount} total arenas.`);
    return;
  }

  const configDir = resolve(args[0] ?? "addons/sourcemod/configs/mge");
  console.log(`Migrating configs in: ${configDir}`);

  let files: string[];
  try {
    files = readdirSync(configDir)
      .filter((f) => f.endsWith(".cfg"))
      .map((f) => join(configDir, f));
  } catch (e) {
    console.error(`Failed to read directory ${configDir}: ${e}`);
    process.exit(1);
  }

  let totalFiles = 0;
  let totalArenas = 0;

  for (const file of files) {
    console.log(`Processing: ${file}`);
    const { arenaCount } = migrateFile(file);
    totalFiles++;
    totalArenas += arenaCount;
  }

  console.log(`\nDone. Migrated ${totalArenas} arenas across ${totalFiles} files.`);
}

main();
