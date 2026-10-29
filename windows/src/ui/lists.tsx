// Lists (port of LibraryView.swift): one row per show, the status dropdown on the right, sort,
// filter, and "Not for me". Rows sit in columns on a wide window; right-click replaces the swipes.

import { useEffect, useMemo, useState } from "react";
import { AppModel, type ShowRow } from "../core/model";
import { ageLabel } from "../core/kitsu";
import { displayTitle, formatLabel, LIST_STATUSES, type ListEntry, type ListStatus, type Media, scoreValue, seasonLabel, statusIcon, statusName } from "../core/models";
import { Dropdown, Empty, MediaRow, PageHeader, SearchField, Spinner } from "./components";
import { myScore } from "./fmt";
import { useModel } from "./state";

const SORTS = ["Best match", "Recently added", "Last updated", "Title", "My score", "Average score", "Age rating"] as const;
type Sort = (typeof SORTS)[number];

function subtitle(e: ListEntry, extra: number) {
  const parts: string[] = [];
  if (extra > 0) parts.push(`${extra + 1} seasons`);
  if (scoreValue(e) > 0) parts.push(`Your score ★ ${myScore(e.score)}`);
  parts.push(formatLabel(e.media));
  const s = seasonLabel(e.media);
  if (s) parts.push(s);
  return parts.join(" · ");
}

function sorted(rows: ShowRow[], sort: Sort, model: AppModel): ShowRow[] {
  const lang = model.settings.titleLanguage;
  const list = [...rows];
  const title = (r: ShowRow) => displayTitle(r.entry.media, lang);
  switch (sort) {
    case "Last updated": return list.sort((a, b) => (b.entry.updatedAt ?? 0) - (a.entry.updatedAt ?? 0));
    case "Recently added": return list.sort((a, b) => (b.entry.createdAt ?? b.entry.updatedAt ?? 0) - (a.entry.createdAt ?? a.entry.updatedAt ?? 0));
    case "Title": return list.sort((a, b) => title(a).localeCompare(title(b)));
    case "My score": return list.sort((a, b) => scoreValue(b.entry) - scoreValue(a.entry));
    case "Average score": return list.sort((a, b) => (b.entry.media.averageScore ?? 0) - (a.entry.media.averageScore ?? 0));
    case "Age rating": {
      // 18+ first, down to PG; shows Kitsu hasn't rated go last. Ties: title.
      const rank = (r: ShowRow) => ({ "18+": 4, "17+": 3, "13+": 2, PG: 1 } as Record<string, number>)[ageLabel(model.ages.rating(r.entry.mediaId)) ?? ""] ?? 0;
      return list.sort((a, b) => rank(b) - rank(a) || title(a).localeCompare(title(b)));
    }
    case "Best match": {
      const keys = new Map(list.map((r) => [r.entry.id, model.matcher.match(r.entry.media) ?? Math.trunc(scoreValue(r.entry))]));
      return list.sort((a, b) => (keys.get(b.entry.id) ?? 0) - (keys.get(a.entry.id) ?? 0));
    }
  }
}

export function ListsPage({ refreshKey }: { refreshKey: number }) {
  const model = useModel();
  const [status, setStatus] = useState<ListStatus>("CURRENT");
  const [notForMe, setNotForMe] = useState(false);
  const [userPicked, setUserPicked] = useState(false);
  const [sort, setSort] = useState<Sort>("Last updated");
  const [filter, setFilter] = useState("");
  const [notForMeFailed, setNotForMeFailed] = useState(false);

  // Opens on the first list that has shows, unless you picked one.
  useEffect(() => {
    if (userPicked || notForMe || model.showCount(status) > 0) return;
    const order: ListStatus[] = ["CURRENT", "REPEATING", "PLANNING", "COMPLETED", "PAUSED", "DROPPED"];
    const first = order.find((s) => model.showCount(s) > 0);
    if (first) setStatus(first);
  }, [model.entries.length, userPicked, notForMe, status, model]);

  useEffect(() => {
    if (notForMe) void model.loadNotForMeMedia().then((ok) => setNotForMeFailed(!ok));
  }, [notForMe, model]);

  // F5: refresh the list (the iPhone's pull to refresh).
  const [lastRefresh, setLastRefresh] = useState(refreshKey);
  useEffect(() => {
    if (refreshKey === lastRefresh) return;
    setLastRefresh(refreshKey);
    void model.refreshList();
    if (notForMe) void model.loadNotForMeMedia().then((ok) => setNotForMeFailed(!ok));
  }, [refreshKey, lastRefresh, model, notForMe]);

  // Sorting by age: make sure every show in this list has its rating.
  useEffect(() => {
    if (sort !== "Age rating") return;
    for (const r of model.shows([status])) model.ages.request(r.entry.media);
  }, [sort, status, model]);

  const text = filter.trim().toLowerCase();
  const rows = useMemo(() => {
    let grouped = model.shows([status]);
    if (text) {
      grouped = grouped.filter((r) => [r.entry.media.title, ...r.foldedTitles].some((t) =>
        [t.english, t.romaji, t.native].some((s) => s?.toLowerCase().includes(text))));
    }
    return sorted(grouped, sort, model);
  }, [model, model.version, status, text, sort]); // eslint-disable-line react-hooks/exhaustive-deps

  const notForMeItems = useMemo(() => {
    const lang = model.settings.titleLanguage;
    return [...model.settings.dismissedPicks].map((id) => model.notForMeMedia.get(id)).filter((m): m is Media => !!m)
      .filter((m) => !text || [m.title.english, m.title.romaji, m.title.native].some((s) => s?.toLowerCase().includes(text)))
      .sort((a, b) => displayTitle(a, lang).localeCompare(displayTitle(b, lang)));
  }, [model, model.version, text]); // eslint-disable-line react-hooks/exhaustive-deps

  type V = ListStatus | "NOT_FOR_ME";
  const statusItems: Parameters<typeof Dropdown<V>>[0]["items"] = [
    ...LIST_STATUSES.map((s) => ({ value: s as V, label: `${statusName[s]} (${model.showCount(s)})`, icon: statusIcon[s], selected: s === status && !notForMe })),
    "divider",
    { value: "NOT_FOR_ME", label: `Not for me (${model.settings.dismissedPicks.size})`, icon: "thumbsDown", selected: notForMe },
  ];
  const label = notForMe ? `Not for me (${model.settings.dismissedPicks.size})` : `${statusName[status]} (${model.showCount(status)})`;

  return (
    <div className="page">
      <PageHeader title="Lists">
        <Dropdown<Sort> icon="sort" compact label="" onPick={setSort} items={SORTS.map((s) => ({ value: s, label: s, selected: s === sort }))} />
      </PageHeader>
      <div className="toolbar-row">
        <SearchField value={filter} onChange={setFilter} placeholder="Filter this list" />
        <Dropdown<V> icon={notForMe ? "thumbsDown" : statusIcon[status]} label={label} items={statusItems}
          onPick={(v) => { setUserPicked(true); if (v === "NOT_FOR_ME") setNotForMe(true); else { setNotForMe(false); setStatus(v); } }} />
      </div>
      {model.isLoadingList && model.entries.length > 0 && <div className="refreshing"><span className="spinner small" /></div>}
      {notForMe ? (
        notForMeItems.length === 0 ? (
          <Empty icon="thumbsDown" title={model.settings.dismissedPicks.size === 0 ? "Nothing here" : text ? "No matches" : notForMeFailed ? "Couldn't load these shows" : "Loading…"}
            text={model.settings.dismissedPicks.size === 0 ? "Shows you mark \"Not for me\" in For You appear here." : notForMeFailed ? "Press F5 to try again." : undefined} />
        ) : (
          <>
            <p className="footnote pad">Hidden from your picks. Right-click a show and choose Bring back to see it again.</p>
            <div className="rows columns">{notForMeItems.map((m) => <MediaRow key={m.id} media={m} subtitle={[formatLabel(m), seasonLabel(m)].filter(Boolean).join(" · ")} />)}</div>
          </>
        )
      ) : rows.length === 0 ? (
        model.isLoadingList || !model.listLoadedOnce ? <Spinner label="Loading…" /> : <Empty icon="list" title={text ? "No matches" : `No shows marked ${statusName[status].toLowerCase()}.`} />
      ) : (
        <div className="rows columns">
          {rows.map((r) => <MediaRow key={r.entry.id} media={r.entry.media} subtitle={subtitle(r.entry, r.extraSeasons)} />)}
        </div>
      )}
    </div>
  );
}
