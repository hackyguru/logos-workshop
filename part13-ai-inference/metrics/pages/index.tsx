import { useEffect, useRef, useState } from "react";
import Head from "next/head";
import { Geist, Geist_Mono } from "next/font/google";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

interface Provider {
  id: string; models: string[]; load: number; cap: number; price: string;
  version: number; verified: boolean; live: boolean; ageMs: number;
  cardsHeard: number; firstSeenMs: number;
}
interface Snapshot {
  connected: boolean; peerCount: number; error: string | null;
  contentTopic: string; cluster: number;
  stats: {
    activeProviders: number; knownProviders: number; modelsOffered: number;
    openSlots: number; cardsPerMin: number; verifiedPct: number | null;
    lastCardAgoMs: number | null;
  };
  modelCounts: Record<string, number>;
  providers: Provider[];
  history: { t: number; active: number }[];
}

function ago(ms: number): string {
  if (ms < 1_000) return "now";
  if (ms < 60_000) return `${Math.floor(ms / 1000)}s ago`;
  if (ms < 3_600_000) return `${Math.floor(ms / 60_000)}m ago`;
  return `${Math.floor(ms / 3_600_000)}h ago`;
}

// Single-series sparkline (active providers). One series → no legend; the
// tile's label names it. Recessive: no axes, just the line and the last point.
function Sparkline({ points }: { points: { t: number; active: number }[] }) {
  if (points.length < 2) return null;
  const w = 120, h = 32, pad = 3;
  const max = Math.max(1, ...points.map((p) => p.active));
  const xs = (i: number) => pad + (i * (w - 2 * pad)) / (points.length - 1);
  const ys = (v: number) => h - pad - (v * (h - 2 * pad)) / max;
  const d = points.map((p, i) => `${xs(i)},${ys(p.active)}`).join(" ");
  const last = points[points.length - 1];
  return (
    <svg width={w} height={h} aria-label="active providers over the last 15 minutes" role="img">
      <polyline points={d} fill="none" stroke="var(--series-1)" strokeWidth="2"
        strokeLinejoin="round" strokeLinecap="round" />
      <circle cx={xs(points.length - 1)} cy={ys(last.active)} r="3" fill="var(--series-1)" />
    </svg>
  );
}

function Tile({ label, value, sub, children }: {
  label: string; value: string | number; sub?: string; children?: React.ReactNode;
}) {
  return (
    <div className="tile">
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
      {sub ? <div className="tile-sub">{sub}</div> : null}
      {children}
    </div>
  );
}

export default function Home() {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [fetchErr, setFetchErr] = useState<string | null>(null);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    const poll = async () => {
      try {
        const r = await fetch("/api/metrics");
        setSnap(await r.json());
        setFetchErr(null);
      } catch (e) {
        setFetchErr(String(e));
      }
    };
    poll();
    timer.current = setInterval(poll, 5000);
    return () => { if (timer.current) clearInterval(timer.current); };
  }, []);

  const s = snap?.stats;
  const netUp = !!snap?.connected;

  return (
    <div className={`${geistSans.className} ${geistMono.className} viz-root min-h-screen font-sans`}>
      <Head><title>Inference Network — Metrics</title></Head>
      <style jsx global>{`
        .viz-root {
          --surface-1: #fcfcfb;
          --surface-2: #ffffff;
          --border: #e6e4df;
          --text-primary: #0b0b0b;
          --text-secondary: #52514e;
          --text-muted: #8a887f;
          --series-1: #2a78d6;
          --status-good: #008300;
          --status-warning: #eda100;
          --status-serious: #e34948;
          background: var(--surface-1);
          color: var(--text-primary);
        }
        @media (prefers-color-scheme: dark) {
          .viz-root {
            --surface-1: #1a1a19;
            --surface-2: #232322;
            --border: #3a3936;
            --text-primary: #ffffff;
            --text-secondary: #c3c2b7;
            --text-muted: #8a887f;
            --series-1: #3987e5;
            --status-good: #35b135;
            --status-warning: #c98500;
            --status-serious: #e66767;
          }
        }
        .tile {
          background: var(--surface-2); border: 1px solid var(--border);
          border-radius: 10px; padding: 14px 16px; min-width: 150px; flex: 1;
        }
        .tile-label { font-size: 12px; color: var(--text-secondary); }
        .tile-value { font-size: 34px; font-weight: 650; line-height: 1.2; }
        .tile-sub { font-size: 11px; color: var(--text-muted); }
        table { border-collapse: collapse; width: 100%; }
        th { text-align: left; font-size: 11px; font-weight: 500; color: var(--text-secondary);
             padding: 6px 10px; border-bottom: 1px solid var(--border); }
        td { font-size: 13px; padding: 8px 10px; border-bottom: 1px solid var(--border); }
        .mono { font-family: var(--font-geist-mono), monospace; font-size: 12px; }
        .chip { display: inline-block; background: var(--surface-2); border: 1px solid var(--border);
                border-radius: 999px; padding: 3px 10px; font-size: 12px; margin: 0 6px 6px 0; }
      `}</style>

      <main className="mx-auto max-w-5xl px-6 py-10">
        <header className="mb-8">
          <div className="flex items-baseline gap-3 flex-wrap">
            <h1 className="text-2xl font-semibold">Inference Network</h1>
            <span style={{ color: netUp ? "var(--status-good)" : "var(--status-warning)", fontSize: 13 }}>
              {netUp ? `● connected — ${snap?.peerCount} waku peer(s)` : "◌ connecting to waku…"}
            </span>
          </div>
          <p style={{ color: "var(--text-muted)", fontSize: 12 }} className="mt-1">
            live from <span className="mono">{snap?.contentTopic ?? "/inference/1/discovery/json"}</span>
            {" "}· cluster {snap?.cluster ?? 2} · js-waku (server-side, TCP)
          </p>
          {(snap?.error || fetchErr) && (
            <p style={{ color: "var(--status-serious)", fontSize: 12 }} className="mt-2">
              ⚠ {snap?.error ?? fetchErr}
            </p>
          )}
        </header>

        {/* KPI row */}
        <section className="flex gap-4 flex-wrap mb-8" aria-label="headline metrics">
          <Tile label="Active providers" value={s?.activeProviders ?? "—"}
                sub={s ? `${s.knownProviders} known` : undefined}>
            <Sparkline points={snap?.history ?? []} />
          </Tile>
          <Tile label="Models offered" value={s?.modelsOffered ?? "—"}
                sub="distinct, live providers" />
          <Tile label="Open slots" value={s?.openSlots ?? "—"}
                sub="unused concurrency, network-wide" />
          <Tile label="Cards / min" value={s?.cardsPerMin ?? "—"}
                sub={s?.lastCardAgoMs != null ? `last card ${ago(s.lastCardAgoMs)}` : "waiting for first card…"} />
        </section>

        {/* Models */}
        <section className="mb-8" aria-label="models offered">
          <h2 className="text-sm font-medium mb-2" style={{ color: "var(--text-secondary)" }}>
            Models on the marketplace
          </h2>
          {snap && Object.keys(snap.modelCounts).length > 0 ? (
            <div>
              {Object.entries(snap.modelCounts).sort((a, b) => b[1] - a[1]).map(([m, n]) => (
                <span className="chip" key={m}>
                  <span className="mono">{m}</span>
                  <span style={{ color: "var(--text-muted)" }}> × {n} provider{n > 1 ? "s" : ""}</span>
                </span>
              ))}
            </div>
          ) : (
            <p style={{ color: "var(--text-muted)", fontSize: 13 }}>
              none heard yet — providers announce every 10s
            </p>
          )}
        </section>

        {/* Providers table (also the accessibility/table view) */}
        <section aria-label="providers">
          <h2 className="text-sm font-medium mb-2" style={{ color: "var(--text-secondary)" }}>
            Providers
          </h2>
          <div style={{ overflowX: "auto", background: "var(--surface-2)", border: "1px solid var(--border)", borderRadius: 10 }}>
            <table>
              <thead>
                <tr>
                  <th>status</th><th>provider</th><th>models</th><th>price</th>
                  <th>card</th><th>slots</th><th>last seen</th><th>cards heard</th>
                </tr>
              </thead>
              <tbody>
                {(snap?.providers ?? []).map((p) => (
                  <tr key={p.id} style={{ opacity: p.live ? 1 : 0.55 }}>
                    <td style={{ color: p.live ? "var(--status-good)" : "var(--text-muted)", whiteSpace: "nowrap" }}>
                      {p.live ? "● live" : "💤 stale"}
                    </td>
                    <td className="mono" title={p.id}>{p.id.slice(0, 16)}…</td>
                    <td className="mono">{p.models.join(", ") || "?"}</td>
                    <td>{p.price}</td>
                    <td style={{ whiteSpace: "nowrap" }}>
                      {p.verified
                        ? <span style={{ color: "var(--status-good)" }}>✓ signed</span>
                        : <span style={{ color: "var(--status-warning)" }}>⚠ unverified</span>}
                      <span style={{ color: "var(--text-muted)" }}> v{p.version}</span>
                    </td>
                    <td>{p.cap > 0 ? `${Math.max(0, p.cap - p.load)}/${p.cap} free` : "—"}</td>
                    <td style={{ whiteSpace: "nowrap" }}>{ago(p.ageMs)}</td>
                    <td>{p.cardsHeard}</td>
                  </tr>
                ))}
                {(!snap || snap.providers.length === 0) && (
                  <tr><td colSpan={8} style={{ color: "var(--text-muted)" }}>
                    no providers heard yet
                  </td></tr>
                )}
              </tbody>
            </table>
          </div>
          <p style={{ color: "var(--text-muted)", fontSize: 11 }} className="mt-2">
            a provider is <b>live</b> if a signed capability card arrived in the last 30s ·
            cards verified against Ed25519 identity (fingerprint = SHA-256 of signing key)
          </p>
        </section>
      </main>
    </div>
  );
}
