// On-device synopsis similarity. The iPhone uses Apple's NLContextualEmbedding; on Windows the
// same job runs in the app's Rust side with ONNX Runtime, on the Snapdragon NPU (QNN) when it
// can, otherwise the CPU. This file is the TypeScript side: what to embed and the vector math.

import { type Media, plainDescription, visibleTags } from "./models";

export interface EngineStatus {
  /** "npu" (every layer on the Snapdragon NPU), "npu+cpu" (NPU with CPU help), "cpu", or "off". */
  backend: "npu" | "npu+cpu" | "cpu" | "off";
  detail: string;
}

export interface Embedder {
  status(): Promise<EngineStatus>;
  /** Vectors already saved (no model work). */
  cached(ids: number[]): Promise<Map<number, Float32Array>>;
  /** Vectors for these shows, embedding the missing ones. */
  vectors(items: { id: number; text: string }[]): Promise<Map<number, Float32Array>>;
}

class NoEmbedder implements Embedder {
  async status(): Promise<EngineStatus> {
    return { backend: "off", detail: "Not available" };
  }
  async cached() {
    return new Map<number, Float32Array>();
  }
  async vectors() {
    return new Map<number, Float32Array>();
  }
}

let embedder: Embedder = new NoEmbedder();
export const setEmbedder = (e: Embedder) => (embedder = e);
export const getEmbedder = () => embedder;

/** The same text the iPhone embeds: title, genres, top tags and ~500 characters of synopsis. */
export function embeddingText(m: Media): string {
  const title = m.title.english ?? m.title.romaji ?? m.title.userPreferred ?? "";
  const genres = (m.genres ?? []).join(", ");
  const tags = visibleTags(m).slice(0, 6).map((t) => t.name).join(", ");
  const synopsis = plainDescription(m).slice(0, 500);
  return `${title}. ${genres}. ${tags}. ${synopsis}`;
}

export async function vectorsFor(media: Media[]): Promise<Map<number, Float32Array>> {
  const unique = new Map(media.map((m) => [m.id, m]));
  return embedder.vectors([...unique.values()].map((m) => ({ id: m.id, text: embeddingText(m) })));
}

export function normalized(v: Float32Array): Float32Array {
  let sum = 0;
  for (const x of v) sum += x * x;
  const norm = Math.sqrt(sum);
  if (!(norm > 0)) return v;
  const out = new Float32Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i] / norm;
  return out;
}

/** Both are unit length: the dot product. */
export function cosine(a: Float32Array, b: Float32Array): number {
  if (a.length !== b.length || !a.length) return 0;
  let dot = 0;
  for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
  return dot;
}

export function accumulate(v: Float32Array, scale: number, acc: Float32Array) {
  if (v.length !== acc.length) return;
  for (let i = 0; i < v.length; i++) acc[i] += v[i] * scale;
}

/** Cosine between a unit vector and the taste vector with that show's own share removed. */
export function leaveOneOutCosine(raw: Float32Array, v: Float32Array, w: number): number {
  const rv = cosine(raw, v);
  const rr = cosine(raw, raw);
  const normSq = rr - 2 * w * rv + w * w;
  if (!(normSq > 1e-9)) return 0;
  return (rv - w) / Math.sqrt(normSq);
}
