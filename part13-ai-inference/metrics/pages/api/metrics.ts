import type { NextApiRequest, NextApiResponse } from "next";

export default async function handler(_req: NextApiRequest, res: NextApiResponse) {
  // Dynamic import keeps the waku node (and its ESM deps) out of the page
  // bundle and defers startup to first request.
  const { snapshot } = await import("../../lib/wakuMetrics");
  res.status(200).json(snapshot());
}
