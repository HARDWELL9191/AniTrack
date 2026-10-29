// "Why would I like this?" written by an on-device language model: Windows' (Phi Silica, then
// Aion Instruct) on the PC, the twin of the iPhone's PickExplainer (Apple Intelligence). Same
// instructions and inputs as the iPhone; runs only when asked, answers kept per show.

import { displayTitle, plainDescription } from "./models";
import type { Media, TitleLanguage } from "./models";

export interface ExplainerStatus {
  available: boolean;
  detail: string;
}

export interface Explainer {
  status(): Promise<ExplainerStatus>;
  write(prompt: string): Promise<string>;
}

let explainer: Explainer = {
  status: async () => ({ available: false, detail: "Windows AI is only in the installed app." }),
  write: async () => { throw new Error("unavailable"); },
};

export function setExplainer(e: Explainer) {
  explainer = e;
}

let statusPromise: Promise<ExplainerStatus> | null = null;
/** Checked once per launch (the first check also sets Windows AI up for this user). */
export function explainerStatus(): Promise<ExplainerStatus> {
  statusPromise ??= explainer.status().catch((e) => ({ available: false, detail: String(e) }));
  return statusPromise;
}

const cache = new Map<number, string>();
const pending = new Map<number, Promise<string>>();

export function cachedExplanation(id: number): string | undefined {
  return cache.get(id);
}

/** Two short sentences on why you may enjoy the show (the iPhone's prompt). */
export function explainPick(
  media: Media,
  opts: { because: string[]; likedTitles: string[]; sharedHighlights: string[]; language: TitleLanguage },
): Promise<string> {
  const hit = cache.get(media.id);
  if (hit) return Promise.resolve(hit);
  const running = pending.get(media.id);
  if (running) return running;

  const because = opts.because.length ? opts.because.join("; ") : opts.likedTitles.slice(0, 5).join("; ");
  // Windows' model takes one prompt, so the iPhone's instructions lead it.
  const prompt = [
    "You are the recommendation assistant in an anime tracking app. In at most two short sentences (under 45 words total), "
      + "tell the user why they may enjoy the recommended anime, connecting it to anime they rated highly. "
      + "Be specific about tone, premise or characters. No spoilers, no markdown, no lists.",
    "",
    `Anime the user rated highly: ${because}`,
    `Themes they share: ${opts.sharedHighlights.join(", ")}`,
    `Recommended anime: ${displayTitle(media, opts.language)}`,
    `Genres: ${(media.genres ?? []).join(", ")}`,
    `Synopsis: ${plainDescription(media).slice(0, 700)}`,
  ].join("\n");

  const job = explainer
    .write(prompt)
    .then((text) => {
      const clean = text.trim().replace(/^["“]|["”]$/g, "");
      cache.set(media.id, clean);
      return clean;
    })
    .finally(() => pending.delete(media.id));
  pending.set(media.id, job);
  return job;
}
