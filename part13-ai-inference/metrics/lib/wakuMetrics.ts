// Server-side js-waku collector for the part13 inference marketplace.
//
// Browsers can't join the logos.dev waku network (the fleet exposes raw TCP
// only, no websockets), so the waku light node runs HERE, inside the Next.js
// server process, over @libp2p/tcp. It subscribes to the global discovery
// topic, verifies each capability card (Ed25519 signature + fingerprint
// binding, same canon as the C++ modules), and keeps an in-memory picture of
// the network that /api/metrics serves to the dashboard.
import { createLightNode, createDecoder, type LightNode } from "@waku/sdk";
import { createRoutingInfo } from "@waku/utils";
import { tcp } from "@libp2p/tcp";
import nacl from "tweetnacl";
import { createHash } from "crypto";

const CONTENT_TOPIC = "/inference/1/discovery/json";
// logos.dev preset (see docs/delivery-guide.md): cluster 2, 8 auto-shards.
const NETWORK = { clusterId: 2, numShardsInCluster: 8 } as const;
// Our own provider node first (it definitely relays the discovery shard),
// then the logos.dev fleet.
const BOOTSTRAP = [
  "/ip4/140.238.98.4/tcp/60010/p2p/16Uiu2HAmNTTQeMLjTQwPg2cYc8xPaUnu5hjSfNy8CKFtDLyNe9uq",
  "/dns4/delivery-01.do-ams3.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAmTUbnxLGT9JvV6mu9oPyDjqHK4Phs1VDJNUgESgNSkuby",
  "/dns4/delivery-01.ac-cn-hongkong-c.logos.dev.status.im/tcp/30303/p2p/16Uiu2HAm8YokiNun9BkeA1ZRmhLbtNUvcwRr64F69tYj9fkGyuEP",
];

const LIVE_WINDOW_MS = 90_000;   // ~3 missed announces (providers announce every ~30s, jittered)
const FORGET_MS = 15 * 60_000;   // drop from the table entirely after 15 min silent

export interface ProviderCard {
  id: string;
  models: string[];
  load: number;
  cap: number;
  price: string;
  version: number;
  verified: boolean;
  firstSeenMs: number;
  lastSeenMs: number;
  cardsHeard: number;
}

interface HistoryPoint { t: number; active: number; }

interface State {
  node: LightNode | null;
  starting: Promise<void> | null;
  error: string | null;
  providers: Map<string, ProviderCard>;
  cardTimestamps: number[];        // for cards/min
  history: HistoryPoint[];         // active-provider sparkline, 10s samples
  startedAt: number;
  lastCardAt: number;
}

// Survive Next.js dev-server HMR: one collector per process, ever.
const g = globalThis as typeof globalThis & { __inferenceMetrics?: State };
const state: State = (g.__inferenceMetrics ??= {
  node: null,
  starting: null,
  error: null,
  providers: new Map(),
  cardTimestamps: [],
  history: [],
  startedAt: Date.now(),
  lastCardAt: 0,
});

function fingerprintOf(signPk: Buffer): string {
  // Must match InferenceIdentity::fingerprintOf: first 20 bytes of
  // SHA256(ed25519 public key), hex.
  return createHash("sha256").update(signPk).digest().subarray(0, 20).toString("hex");
}

// Same canonical bytes the C++ provider signs (v3 card / v2 announce).
function canonFor(o: Record<string, unknown>): string | null {
  const v = Number(o.v ?? 0);
  if (v >= 3) {
    const models = Array.isArray(o.models) ? (o.models as string[]) : [];
    return [
      "inference/v1/announce3", o.id, o.signPk, o.boxPk, models.join(","),
      String(o.load ?? 0), String(o.cap ?? 0),
      JSON.stringify(o.price ?? {}), String(o.ts ?? 0),
    ].join("|");
  }
  if (v === 2) {
    return [
      "inference/v1/announce", o.id, o.signPk, o.boxPk, o.model,
      String(o.load ?? 0), String(o.ts ?? 0),
    ].join("|");
  }
  return null;
}

function handleCard(payloadUtf8: string): void {
  let o: Record<string, unknown>;
  try { o = JSON.parse(payloadUtf8); } catch { return; }
  if (o.type !== "announce" || typeof o.id !== "string") return;

  const signPk = Buffer.from(String(o.signPk ?? ""), "base64");
  const sig = Buffer.from(String(o.sig ?? ""), "base64");
  let verified = false;
  const canon = canonFor(o);
  if (canon && signPk.length === 32 && sig.length === 64) {
    verified = fingerprintOf(signPk) === o.id &&
      nacl.sign.detached.verify(Buffer.from(canon, "utf8"), sig, signPk);
  }

  const now = Date.now();
  const models = Array.isArray(o.models) && o.models.length > 0
    ? (o.models as string[])
    : (typeof o.model === "string" && o.model ? [o.model] : []);
  const prev = state.providers.get(o.id);
  state.providers.set(o.id, {
    id: o.id,
    models,
    load: Number(o.load ?? 0),
    cap: Number(o.cap ?? 0),
    price: typeof o.price === "object" && o.price
      ? String((o.price as Record<string, unknown>).scheme ?? "free") : "free",
    version: Number(o.v ?? 0),
    verified,
    firstSeenMs: prev?.firstSeenMs ?? now,
    lastSeenMs: now,
    cardsHeard: (prev?.cardsHeard ?? 0) + 1,
  });
  state.cardTimestamps.push(now);
  state.lastCardAt = now;
  // keep 10 minutes of card timestamps
  while (state.cardTimestamps.length && state.cardTimestamps[0] < now - 600_000)
    state.cardTimestamps.shift();
}

function sampleHistory(): void {
  const now = Date.now();
  let active = 0;
  for (const [id, p] of state.providers) {
    if (now - p.lastSeenMs < LIVE_WINDOW_MS) active++;
    if (now - p.lastSeenMs > FORGET_MS) state.providers.delete(id);
  }
  state.history.push({ t: now, active });
  if (state.history.length > 90) state.history.shift();   // 15 min at 10s
}

async function start(): Promise<void> {
  const routingInfo = createRoutingInfo(NETWORK, { contentTopic: CONTENT_TOPIC });
  const decoder = createDecoder(CONTENT_TOPIC, routingInfo);

  const node = await createLightNode({
    networkConfig: NETWORK,
    defaultBootstrap: false,
    bootstrapPeers: BOOTSTRAP,
    libp2p: {
      // The fleet + our provider speak raw TCP (no websockets anywhere on
      // this network) — hence a server-side node at all.
      transports: [tcp()],
    },
  });
  await node.start();
  state.node = node;

  await node.filter.subscribe([decoder], (msg) => {
    if (!msg.payload) return;
    handleCard(Buffer.from(msg.payload).toString("utf8"));
  });

  // Backfill from store so a fresh dashboard isn't blind for 10s (and shows
  // providers that announced recently even if they just went quiet).
  try {
    await node.store.queryWithOrderedCallback([decoder], (msg) => {
      if (msg.payload) handleCard(Buffer.from(msg.payload).toString("utf8"));
    }, { timeStart: new Date(Date.now() - 3600_000) });
  } catch {
    // store is best-effort — filter keeps us live regardless
  }

  setInterval(sampleHistory, 10_000).unref();
}

export function ensureStarted(): void {
  if (!state.starting) {
    state.starting = start().catch((e) => {
      state.error = String(e?.message ?? e);
      state.starting = null;   // allow a retry on next request
    });
  }
}

export function snapshot() {
  ensureStarted();
  const now = Date.now();
  const providers = [...state.providers.values()]
    .sort((a, b) => b.lastSeenMs - a.lastSeenMs)
    .map((p) => ({
      ...p,
      live: now - p.lastSeenMs < LIVE_WINDOW_MS,
      ageMs: now - p.lastSeenMs,
    }));
  const live = providers.filter((p) => p.live);

  const modelCounts: Record<string, number> = {};
  for (const p of live)
    for (const m of p.models) modelCounts[m] = (modelCounts[m] ?? 0) + 1;

  const peerCount = state.node?.libp2p.getPeers().length ?? 0;
  return {
    connected: peerCount > 0,
    peerCount,
    error: state.error,
    contentTopic: CONTENT_TOPIC,
    cluster: NETWORK.clusterId,
    stats: {
      activeProviders: live.length,
      knownProviders: providers.length,
      modelsOffered: Object.keys(modelCounts).length,
      openSlots: live.reduce((s, p) => s + Math.max(0, p.cap - p.load), 0),
      cardsPerMin: state.cardTimestamps.filter((t) => t > now - 60_000).length,
      verifiedPct: providers.length
        ? Math.round(100 * providers.filter((p) => p.verified).length / providers.length)
        : null,
      lastCardAgoMs: state.lastCardAt ? now - state.lastCardAt : null,
    },
    modelCounts,
    providers,
    history: state.history,
  };
}
