// "Why would I like this?" written by a language model on the Snapdragon NPU (Qwen3 4B
// Instruct, downloaded once on request): the twin of the iPhone's PickExplainer (Apple
// Intelligence). Same instructions and inputs as the iPhone; runs only when asked, answers
// kept per show.

import { displayTitle, plainDescription } from "./models";
import type { Media, TitleLanguage } from "./models";

export interface WriterStatus {
  state: "unsupported" | "notDownloaded" | "downloading" | "ready" | "error";
  model: string;
  sizeBytes: number;
  received: number;
  detail: string;
}

export interface Writer {
  status(): Promise<WriterStatus>;
  download(): Promise<void>;
  cancel(): Promise<void>;
  remove(): Promise<void>;
  write(system: string, user: string): Promise<string>;
}

let writer: Writer = {
  status: async () => ({ state: "unsupported", model: "", sizeBytes: 0, received: 0, detail: "The AI writer is only in the installed app." }),
  download: async () => {},
  cancel: async () => {},
  remove: async () => {},
  write: async () => { throw new Error("unavailable"); },
};

export function setWriter(w: Writer) {
  writer = w;
}

export function getWriter(): Writer {
  return writer;
}

export function gigabytes(bytes: number): string {
  return `${(bytes / 1e9).toFixed(1)} GB`;
}

const cache = new Map<number, string>();
const pending = new Map<number, Promise<string>>();

export function cachedExplanation(id: number): string | undefined {
  return cache.get(id);
}

/** The iPhone's instructions (PickExplainer.swift). */
const INSTRUCTIONS =
  "You are the recommendation assistant in an anime tracking app. In at most two short sentences (under 45 words total), "
  + "tell the user why they may enjoy the recommended anime, connecting it to anime they rated highly. "
  + "Be specific about tone, premise or characters. No spoilers, no markdown, no lists.";

/** Two short sentences on why you may enjoy the show. */
export function explainPick(
  media: Media,
  opts: { because: string[]; likedTitles: string[]; sharedHighlights: string[]; language: TitleLanguage },
): Promise<string> {
  const hit = cache.get(media.id);
  if (hit) return Promise.resolve(hit);
  const running = pending.get(media.id);
  if (running) return running;

  const because = opts.because.length ? opts.because.join("; ") : opts.likedTitles.slice(0, 5).join("; ");
  const user = [
    `Anime the user rated highly: ${because}`,
    `Themes they share: ${opts.sharedHighlights.join(", ")}`,
    `Recommended anime: ${displayTitle(media, opts.language)}`,
    `Genres: ${(media.genres ?? []).join(", ")}`,
    `Synopsis: ${plainDescription(media).slice(0, 700)}`,
  ].join("\n");

  const job = writer
    .write(INSTRUCTIONS, user)
    .then((text) => {
      const clean = text.trim().replace(/^["“]|["”]$/g, "");
      cache.set(media.id, clean);
      return clean;
    })
    .finally(() => pending.delete(media.id));
  pending.set(media.id, job);
  return job;
}
