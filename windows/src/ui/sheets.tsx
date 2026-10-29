// Sheets that open over any screen: list editor, rating prompt, More like this, Why, Export,
// All categories (ports of EntryEditorView, TasteViews.swift, ListExportView.swift…).

import { useEffect, useMemo, useState } from "react";
import { isCancellation } from "../core/anilist";
import {
  AnimeCategory, categoryId, displayTitle, EntryLite, formatLabel, LIST_STATUSES, ListStatus, Media, progressValue, scoreValue,
  seasonLabel, statusIcon, statusName, statusLabel, thumbURL, coverURL, visibleTags, isMovie,
} from "../core/models";
import { entryWeight, scoreStats, TasteProfile } from "../core/recommender";
import { SeasonRoots } from "../core/seasons";
import * as X from "../core/xlsx";
import { Chip, Cover, Empty, MatchBadge, MediaRow, Modal, SearchField, Spinner } from "./components";
import { DetailPage } from "./detail";
import { myScore } from "./fmt";
import { Icon } from "./icons";
import { InSheetContext, ui, useModel, useUI } from "./state";
import { save as saveDialog } from "@tauri-apps/plugin-dialog";
import { invoke } from "@tauri-apps/api/core";

export function Sheets() {
  const state = useUI();
  const model = useModel();
  const top = state.sheets[state.sheets.length - 1];
  return (
    <>
      {state.sheets.map((s, i) => {
        const close = () => ui.closeSheet();
        const key = `${s.kind}-${i}`;
        switch (s.kind) {
          case "editor": return <EntryEditor key={key} media={s.media} onClose={close} />;
          case "moreLikeThis": return <MoreLikeThis key={key} media={s.media} onClose={close} />;
          case "why": return <WhyThis key={key} media={s.media} onClose={close} />;
          case "export": return <ExportSheet key={key} onClose={close} />;
          case "allCategories": return <AllCategories key={key} onPick={(c) => { close(); s.onPick(c); }} onClose={close} />;
        }
      })}
      {model.ratePrompt && (!top || top.kind === "moreLikeThis") && <RatePrompt media={model.ratePrompt} />}
    </>
  );
}

// MARK: Editor

export function EntryEditor({ media, onClose, lite }: { media: Media; onClose: () => void; lite?: EntryLite | null }) {
  const model = useModel();
  const existing = model.entry(media.id);
  const entryId = existing?.id ?? lite?.id;
  const [status, setStatus] = useState<ListStatus>(existing?.status ?? lite?.status ?? "PLANNING");
  const [progress, setProgress] = useState(progressValue(existing ?? lite ?? {}));
  const [score, setScore] = useState(scoreValue(existing ?? lite ?? {}) / 10);
  const [picked, setPicked] = useState(false);
  const [saving, setSaving] = useState(false);
  const total = media.episodes ?? undefined;

  const changeProgress = (n: number) => {
    const next = Math.max(0, Math.min(total ?? 9999, n));
    setProgress(next);
    if (total && next >= total && total > 0 && status !== "REPEATING") setStatus("COMPLETED");
    else if (next > 0 && status === "PLANNING") setStatus("CURRENT");
  };

  const save = async () => {
    setSaving(true);
    const isNew = entryId === undefined;
    const oldScore = Math.round(scoreValue(existing ?? lite ?? {}));
    const newScore = Math.round(score * 10);
    try {
      await model.save(media, status, progress, newScore);
      if (picked && status === "COMPLETED") model.updateOtherSeasons(media, { kind: "watched" });
      else if (isNew || (picked && status === "PLANNING")) model.updateOtherSeasons(media, { kind: "planned" });
      if (newScore > 0 && newScore !== oldScore) model.updateOtherSeasons(media, { kind: "scored", score: newScore });
      onClose();
    } catch (e) {
      model.showError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  const remove = () => {
    if (entryId === undefined) return;
    onClose();
    model.removeShow(media, entryId).catch((e) => model.showError((e as Error).message));
  };

  return (
    <Modal title={displayTitle(media, model.settings.titleLanguage)} onClose={onClose} width={520}
      actions={<button className="glass-button prominent" disabled={saving} onClick={save}>Save</button>}>
      <div className="form">
        <div className="form-row">
          <span>Status</span>
          <div className="segmented">
            {LIST_STATUSES.map((s) => (
              <button key={s} className={s === status ? "on" : ""} onClick={() => { setStatus(s); setPicked(true); }}>
                <Icon name={statusIcon[s]} size={15} />{statusName[s]}
              </button>
            ))}
          </div>
        </div>
        <div className="form-row">
          <span>Episodes {progress}/{total ?? "?"}</span>
          <div className="stepper">
            <button className="round-button" onClick={() => changeProgress(progress - 1)} disabled={progress <= 0}>−</button>
            <input type="number" min={0} max={total ?? 9999} value={progress} onChange={(e) => changeProgress(Number(e.target.value) || 0)} />
            <button className="round-button" onClick={() => changeProgress(progress + 1)} disabled={total !== undefined && progress >= total}>+</button>
          </div>
        </div>
        <div className="form-row column">
          <span>{score > 0 ? `Score ★ ${myScore(score * 10)}` : "Score: not rated"}</span>
          <input type="range" min={0} max={10} step={0.5} value={score} onChange={(e) => setScore(Number(e.target.value))} />
        </div>
        {entryId !== undefined && (
          // Removes the whole show (every season), no question asked.
          <button className="text-button danger" disabled={saving} onClick={remove}>Remove from list</button>
        )}
      </div>
    </Modal>
  );
}

// MARK: Rating prompt

function RatePrompt({ media }: { media: Media }) {
  const model = useModel();
  const [saving, setSaving] = useState(false);
  const close = () => { model.ratePrompt = null; model.notify(); };
  const rate = async (value: number) => {
    setSaving(true);
    try {
      const status = model.entry(media.id)?.status ?? "COMPLETED";
      await model.save(media, status, null, value * 10);
      model.updateOtherSeasons(media, { kind: "scored", score: value * 10 });
      close();
    } catch (e) {
      model.showError((e as Error).message);
    } finally {
      setSaving(false);
    }
  };
  return (
    <Modal title="How did you like it?" onClose={close} width={460}>
      <div className="rate-head">
        <Cover url={thumbURL(media)} color={media.coverImage?.color} width={52} height={74} radius={7} />
        <div className="muted">{displayTitle(media, model.settings.titleLanguage)}</div>
      </div>
      <div className="rate-grid">
        {Array.from({ length: 10 }, (_, i) => i + 1).map((v) => (
          <button key={v} className={`glass-button rate rate-${v >= 8 ? "good" : v >= 5 ? "ok" : "low"}`} disabled={saving} onClick={() => rate(v)}>{v}</button>
        ))}
      </div>
      <button className="text-button" onClick={close}>Skip</button>
    </Modal>
  );
}

// MARK: More like this

function MoreLikeThis({ media, onClose }: { media: Media; onClose: () => void }) {
  const model = useModel();
  const state = useUI();
  const [items, setItems] = useState<Media[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    (async () => {
      try {
        const detail = await model.detail(media.id);
        const recs = (detail.recommendations?.nodes ?? []).map((n) => n.mediaRecommendation).filter((m): m is Media => !!m);
        const collapsed = await SeasonRoots.collapse(recs, model.client);
        if (!live) return;
        setItems(collapsed
          .filter((m) => m.id !== media.id && !model.entry(m.id) && m.isAdult !== true && !isMovie(m))
          .filter((m) => !model.franchises.contains(m) && !model.settings.dismissedPicks.has(m.id))
          .filter((m) => !(model.settings.hideChinese && m.countryOfOrigin === "CN"))
          .sort((a, b) => (model.matcher.match(b) ?? 0) - (model.matcher.match(a) ?? 0)));
      } catch (e) {
        if (!live || isCancellation(e)) return;
        setError((e as Error).message);
        setItems([]);
      }
    })();
    return () => { live = false; };
  }, [media.id, model, media]);

  const route = state.sheetRoute;
  const shown = (items ?? []).filter((m) => !model.entry(m.id) && !model.settings.dismissedPicks.has(m.id));
  return (
    <Modal title={route ? "" : `Like ${displayTitle(media, model.settings.titleLanguage)}`} onClose={onClose} width={route ? 980 : 640}>
      <InSheetContext.Provider value={true}>
        {route?.kind === "detail" ? (
          <div className="sheet-detail">
            <button className="glass-button back-in-sheet" onClick={() => ui.setSheetRoute(null)}><Icon name="chevronLeft" size={16} /> Back</button>
            <DetailPage id={route.id} />
          </div>
        ) : items === null ? (
          <Spinner />
        ) : shown.length === 0 ? (
          <Empty icon="layers" title="Nothing similar found" text={error ?? "Fans haven't linked shows to this one yet."} />
        ) : (
          <div className="rows">{shown.map((m) => <MediaRow key={m.id} media={m} />)}</div>
        )}
      </InSheetContext.Provider>
    </Modal>
  );
}

// MARK: Why would I like this?

/** Written from your list (fans' links, shared genres and tags, the shows it's closest to). */
function explain(media: Media, model: ReturnType<typeof useModel>): string {
  const lang = model.settings.titleLanguage;
  const entries = model.entries;
  const { mean, spread } = scoreStats(entries);
  const profile = new TasteProfile();
  for (const e of entries) {
    const w = entryWeight(e, mean, spread);
    if (w !== 0) profile.add(e.media, w);
  }
  profile.finalize();
  const shared = profile.highlights(media, 4);
  const features = new Set([...(media.genres ?? []), ...visibleTags(media).filter((t) => (t.rank ?? 0) >= 50).map((t) => t.name)]);
  const liked = entries.filter((e) => scoreValue(e) >= 75 || (e.status === "COMPLETED" && scoreValue(e) === 0));
  const closest = liked
    .map((e) => {
      const theirs = new Set([...(e.media.genres ?? []), ...visibleTags(e.media).filter((t) => (t.rank ?? 0) >= 50).map((t) => t.name)]);
      let common = 0;
      for (const f of features) if (theirs.has(f)) common++;
      return { e, common };
    })
    .filter((x) => x.common >= 2 && x.e.mediaId !== media.id)
    .sort((a, b) => b.common - a.common || scoreValue(b.e) - scoreValue(a.e))
    .slice(0, 2)
    .map((x) => displayTitle(x.e.media, lang));
  const because = [...model.feeds.values()].flatMap((f) => f.picks).find((p) => p.id === media.id)?.because ?? [];
  const sentences: string[] = [];
  if (because.length) sentences.push(`Fans of ${because.slice(0, 2).join(" and ")} recommend it.`);
  if (shared.length) sentences.push(`It leans on what you rate highly: ${shared.slice(0, 3).join(", ")}.`);
  if (closest.length) sentences.push(`Closest to ${closest.join(" and ")} on your list.`);
  const match = model.matcher.match(media);
  if (match !== undefined) sentences.push(match >= 80 ? "A strong fit for your taste." : match >= 65 ? "A decent fit, a little outside your favorites." : "Further from your usual, so it could be a change of pace.");
  return sentences.join(" ") || "Rate a few shows on your list and this gets more specific.";
}

function WhyThis({ media, onClose }: { media: Media; onClose: () => void }) {
  const model = useModel();
  const text = useMemo(() => explain(media, model), [media, model]);
  return (
    <Modal title="Why you might like it" onClose={onClose} width={520}>
      <div className="why-head">
        <Cover url={coverURL(media)} color={media.coverImage?.color} width={80} height={116} radius={9} />
        <div>
          <h3>{displayTitle(media, model.settings.titleLanguage)}</h3>
          <MatchBadge media={media} word />
        </div>
      </div>
      <div className="why-text"><Icon name="sparkles" size={18} /><p>{text}</p></div>
      <p className="footnote">Based on your list: fan recommendations, shared genres and tags, and the shows it's closest to.</p>
    </Modal>
  );
}

// MARK: Export to Excel

interface Choice { id: string; label: string; icon: string; status?: ListStatus }
const CHOICES: Choice[] = [
  ...(["CURRENT", "REPEATING", "COMPLETED", "PAUSED", "DROPPED", "PLANNING"] as ListStatus[]).map((s) => ({ id: s, label: statusName[s], icon: statusIcon[s], status: s })),
  { id: "NOT_FOR_ME", label: "Not for me", icon: "thumbsDown" },
];

function ExportSheet({ onClose }: { onClose: () => void }) {
  const model = useModel();
  const count = (c: Choice) => (c.status ? model.entries.filter((e) => e.status === c.status).length : model.settings.dismissedPicks.size);
  const [selected, setSelected] = useState<Set<string>>(() => new Set(CHOICES.filter((c) => count(c) > 0).map((c) => c.id)));
  const [building, setBuilding] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);
  useEffect(() => { void model.loadNotForMeMedia(); }, [model]);
  const all = selected.size === CHOICES.length;

  const sheet = (c: Choice): X.Sheet => {
    const lang = model.settings.titleLanguage;
    const other = (m: Media) => {
      const main = displayTitle(m, lang);
      const o = lang === "romaji" ? (m.title.english ?? m.title.native) : (m.title.romaji ?? m.title.native);
      return o && o !== main ? o : "";
    };
    if (c.status) {
      const entries = model.entries.filter((e) => e.status === c.status)
        .sort((a, b) => displayTitle(a.media, lang).localeCompare(displayTitle(b.media, lang)));
      return {
        name: c.label,
        columns: [
          { title: "Title", width: 42 }, { title: "Other title", width: 36 }, { title: "My score (/10)", width: 14 },
          { title: "Episodes watched", width: 16 }, { title: "Episodes", width: 10 }, { title: "Format", width: 10 },
          { title: "Season", width: 13 }, { title: "Show status", width: 12 }, { title: "Average score (/10)", width: 18 },
          { title: "Match %", width: 10 }, { title: "Genres", width: 34 }, { title: "Added", width: 12 },
          { title: "Last updated", width: 13 }, { title: "AniList", width: 36 },
        ],
        rows: entries.map((e) => {
          const m = e.media;
          return [
            X.text(displayTitle(m, lang)), X.text(other(m)), X.num(scoreValue(e) > 0 ? scoreValue(e) / 10 : null),
            X.num(progressValue(e)), X.num(m.episodes), X.text(formatLabel(m)), X.text(seasonLabel(m) ?? ""), X.text(statusLabel(m)),
            X.num(m.averageScore != null ? m.averageScore / 10 : null), X.num(model.matcher.match(m)),
            X.text((m.genres ?? []).join(", ")), X.date(e.createdAt), X.date(e.updatedAt), X.link(m.siteUrl ?? `https://anilist.co/anime/${m.id}`),
          ];
        }),
      };
    }
    const ids = [...model.settings.dismissedPicks];
    const known = ids.map((id) => model.notForMeMedia.get(id)).filter((m): m is Media => !!m)
      .sort((a, b) => displayTitle(a, lang).localeCompare(displayTitle(b, lang)));
    const unknown = ids.filter((id) => !model.notForMeMedia.has(id)).sort((a, b) => a - b);
    return {
      name: c.label,
      columns: [
        { title: "Title", width: 42 }, { title: "Other title", width: 36 }, { title: "Episodes", width: 10 }, { title: "Format", width: 10 },
        { title: "Season", width: 13 }, { title: "Show status", width: 12 }, { title: "Average score (/10)", width: 18 },
        { title: "Match %", width: 10 }, { title: "Genres", width: 34 }, { title: "AniList", width: 36 },
      ],
      rows: [
        ...known.map((m) => [
          X.text(displayTitle(m, lang)), X.text(other(m)), X.num(m.episodes), X.text(formatLabel(m)), X.text(seasonLabel(m) ?? ""),
          X.text(statusLabel(m)), X.num(m.averageScore != null ? m.averageScore / 10 : null), X.num(model.matcher.match(m)),
          X.text((m.genres ?? []).join(", ")), X.link(m.siteUrl ?? `https://anilist.co/anime/${m.id}`),
        ]),
        ...unknown.map((id) => [X.text(`AniList #${id}`), X.empty, X.empty, X.empty, X.empty, X.empty, X.empty, X.empty, X.empty, X.link(`https://anilist.co/anime/${id}`)]),
      ],
    };
  };

  const build = async () => {
    setBuilding(true);
    setMessage(null);
    try {
      const data = X.xlsx(CHOICES.filter((c) => selected.has(c.id)).map(sheet));
      const user = (model.viewer?.name ?? "").replace(/[^\p{L}\p{N}_-]/gu, "");
      const day = new Date().toISOString().slice(0, 10);
      const path = await saveDialog({ defaultPath: `AniTrack${user ? " " + user : ""} lists ${day}.xlsx`, filters: [{ name: "Excel workbook", extensions: ["xlsx"] }] });
      if (!path) return;
      let binary = "";
      for (let i = 0; i < data.length; i += 0x8000) binary += String.fromCharCode(...data.subarray(i, i + 0x8000));
      await invoke("write_file", { path, base64: btoa(binary) });
      setMessage({ ok: true, text: `Saved ${path.split(/[\\/]/).pop()}.` });
    } catch (e) {
      setMessage({ ok: false, text: `Couldn't save the file: ${(e as Error).message ?? e}` });
    } finally {
      setBuilding(false);
    }
  };

  return (
    <Modal title="Export to Excel" onClose={onClose} width={520}>
      <div className="group">
        <div className="group-title">Lists to include</div>
        {CHOICES.map((c) => (
          <label key={c.id} className="toggle-row">
            <span><Icon name={c.icon} size={16} /> {c.label}</span>
            <span className="muted tabular">{count(c)}</span>
            <input type="checkbox" checked={selected.has(c.id)} onChange={(e) => {
              const s = new Set(selected);
              if (e.target.checked) s.add(c.id); else s.delete(c.id);
              setSelected(s);
            }} />
          </label>
        ))}
        <button className="text-button" onClick={() => setSelected(all ? new Set() : new Set(CHOICES.map((c) => c.id)))}>{all ? "Deselect all" : "Select all"}</button>
      </div>
      <p className="footnote">Each list becomes its own sheet with titles, your score, progress, episodes, format, season, average score, match %, genres, dates and an AniList link. Opens in Excel, Numbers and Google Sheets.</p>
      <div className="center">
        <button className="glass-button prominent save-excel" disabled={!selected.size || building} onClick={build}>
          {building ? <span className="spinner small" /> : "Save Excel file"}
        </button>
        {message && <p className={message.ok ? "footnote center-text" : "footnote center-text error"}>{message.text}</p>}
      </div>
    </Modal>
  );
}

// MARK: All categories

function AllCategories({ onPick, onClose }: { onPick: (c: AnimeCategory) => void; onClose: () => void }) {
  const model = useModel();
  const [search, setSearch] = useState("");
  useEffect(() => { void model.loadCategories(); }, [model]);
  const source = model.allCategories.length ? model.allCategories : model.featuredCategories;
  const filtered = (kind: "genre" | "tag") => source.filter((c) => c.kind === kind && (!search || c.name.toLowerCase().includes(search.toLowerCase())))
    .sort((a, b) => a.name.localeCompare(b.name));
  return (
    <Modal title="Categories" onClose={onClose} width={560}>
      <SearchField value={search} onChange={setSearch} placeholder="Isekai, Romance, Ecchi…" autoFocus />
      {(["genre", "tag"] as const).map((kind) => {
        const list = filtered(kind);
        if (!list.length) return null;
        return (
          <div key={kind} className="group">
            <div className="group-title">{kind === "genre" ? "Genres" : "Tags"}</div>
            <div className="chips-wrap">
              {list.map((c) => <button key={categoryId(c)} className="chip chip-button" onClick={() => onPick(c)}>{c.name}</button>)}
            </div>
          </div>
        );
      })}
    </Modal>
  );
}

export { Chip };
