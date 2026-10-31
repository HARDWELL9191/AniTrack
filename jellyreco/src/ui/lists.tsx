// My List and Not for me: the same lists as the iPhone app, saved in your account's JellyReco
// storage on the server (so they're the same on every device).
// My List holds titles on your server (they play from here) and For You picks you don't have yet
// (they open their TMDB page, and show as "On your server" once you've added them).

import { useState } from "react";
import { type ExternalListName } from "../core/storage";
import { type ExternalTitle, entryId, type MyListEntry, titleId } from "../core/titles";
import type { Item } from "../core/types";
import { Cover, Dropdown, Empty, Grid, ItemCard, PageHeader, useLoad } from "./components";
import { TitleCard, titleAction } from "./foryou";
import { type MenuAction, ui, useModel } from "./state";

type Filter = "all" | "server" | "outside";

export function MyListPage({ back }: { back?: () => void }) {
  const model = useModel();
  const st = model.storage;
  const [filter, setFilter] = useState<Filter>("all");
  const entries = st?.myList ?? [];
  const serverIds = entries.flatMap((e) => (e.serverId ? [e.serverId] : []));
  const key = serverIds.join(",");
  const { data: serverItems } = useLoad(async () => {
    if (!serverIds.length) return new Map<string, Item>();
    const out = new Map<string, Item>();
    for (let i = 0; i < serverIds.length; i += 150) {
      const r = await model.api!.items({ ids: serverIds.slice(i, i + 150), fields: ["PrimaryImageAspectRatio", "ProductionYear", "Overview"], enableUserData: true });
      for (const it of r.Items) out.set(it.Id, it);
    }
    return out;
  }, [key, model.dataVersion]);
  // A pick you've since added to the server counts as "on your server".
  const c = model.discoveryContext();
  const nowOnServer = (e: MyListEntry) => !!e.external && !!c && model.reco.ready && model.discovery.ownedNow(c, e.external);
  const onServer = (e: MyListEntry) => !!e.serverId || nowOnServer(e);
  const shown = entries.filter((e) => (filter === "all" ? true : filter === "server" ? onServer(e) : !!e.external && !nowOnServer(e)));
  const count = (f: Filter) => entries.filter((e) => (f === "all" ? true : f === "server" ? onServer(e) : !!e.external && !nowOnServer(e))).length;
  const labels: Record<Filter, [string, string]> = { all: ["All", "bookmark"], server: ["On your server", "server"], outside: ["Not on server yet", "cloudDown"] };

  return (
    <div className="page">
      <PageHeader title="My List" back={back} subtitle="Everything you want to watch, saved on your Jellyfin server">
        <Dropdown label={`${labels[filter][0]} (${count(filter)})`} icon={labels[filter][1]}
          items={(Object.keys(labels) as Filter[]).map((f) => ({ value: f, label: `${labels[f][0]} (${count(f)})`, selected: f === filter, icon: labels[f][1] }))} onPick={setFilter} />
      </PageHeader>
      {!st?.loaded ? <div className="spinner-wrap"><span className="spinner" /></div>
        : !entries.length ? <Empty icon="bookmark" title="My List is empty" text={'Add titles with "Add to My List" on For You picks, on item pages, or by right-clicking any poster. It\'s saved on your Jellyfin server.'} />
        : !shown.length ? <Empty icon="bookmark" title="Nothing here" text="Nothing on My List matches this filter." />
        : (
          <Grid min={model.settings.libraryCardSize}>
            {shown.map((e) => {
              const item = e.serverId ? serverItems?.get(e.serverId) : undefined;
              if (item) return <ItemCard key={entryId(e)} item={item} width={undefined} />;
              // A pick you've since added to the server: that server title, with the green cloud (iPhone).
              const owned = e.external && c && model.reco.ready ? model.discovery.ownedItem(c, e.external) : undefined;
              if (owned) return <ItemCard key={entryId(e)} item={owned} width={undefined} nowOnServer />;
              if (e.external) return <TitleCard key={entryId(e)} t={e.external} width={model.settings.libraryCardSize} notOnServer actions={myListActions(model, e.external)} />;
              return <MissingCard key={entryId(e)} entry={e} />;
            })}
          </Grid>
        )}
    </div>
  );
}

/** A server title that isn't there any more (or hasn't loaded yet). */
function MissingCard({ entry }: { entry: MyListEntry }) {
  const model = useModel();
  return (
    <div className="card">
      <div className="card-cover"><Cover width="100%" height="auto" radius={14} icon="film" /></div>
      <div className="card-title">{entry.name ?? "Unknown title"}</div>
      <button className="link-button small danger" onClick={() => void model.storage?.removeEntries(new Set([entryId(entry)]), entryId).then(() => model.tasteChanged())}>Remove from My List</button>
    </div>
  );
}

export function NotForMePage({ back }: { back?: () => void }) {
  const model = useModel();
  const st = model.storage;
  const [tab, setTab] = useState<ExternalListName>("notforme");
  const list = (tab === "notforme" ? st?.notForMe : st?.seenElsewhere) ?? [];
  const label = (t: ExternalListName) => (t === "notforme" ? `Not for me (${st?.notForMe.length ?? 0})` : `Already seen (${st?.seenElsewhere.length ?? 0})`);
  return (
    <div className="page">
      <PageHeader title="Not for me" back={back} subtitle="For You picks you turned down, saved on your Jellyfin server">
        <Dropdown label={label(tab)} icon={tab === "notforme" ? "thumbsDown" : "eye"}
          items={(["notforme", "seenelsewhere"] as ExternalListName[]).map((t) => ({ value: t, label: label(t), selected: t === tab, icon: t === "notforme" ? "thumbsDown" : "eye" }))} onPick={setTab} />
        {list.length > 0 && <button className="glass-button" onClick={() => ui.openSheet({ kind: "confirm", title: tab === "notforme" ? "Clear Not for me?" : "Clear Already seen?", text: "These titles can be suggested by For You again.", confirmLabel: "Clear all", danger: true, run: async () => { await st?.clear(tab); model.tasteChanged(); } })}>Clear all</button>}
      </PageHeader>
      {!st?.loaded ? <div className="spinner-wrap"><span className="spinner" /></div>
        : !list.length ? <Empty icon={tab === "notforme" ? "thumbsDown" : "eye"} title="Nothing here" text={tab === "notforme" ? 'Titles you mark "Not for me" in For You show up here.' : 'Titles you mark "Already seen" in For You show up here.'} />
        : (
          // The same poster grid as My List (age bubbles; right-click or … to undo or add to My List).
          <Grid min={model.settings.libraryCardSize}>
            {list.map((t) => <TitleCard key={titleId(t)} t={t} width={model.settings.libraryCardSize} actions={turnedDownActions(model, t, tab)} />)}
          </Grid>
        )}
      <p className="footnote">For titles on your server, Not for me is Jellyfin's own thumbs-down: undo it on the title's page.</p>
    </div>
  );
}

/** What a turned-down pick offers (the iPhone's long-press menu): undo, My List, details. */
function turnedDownActions(model: ReturnType<typeof useModel>, t: ExternalTitle, tab: ExternalListName): MenuAction[] {
  const onList = !!model.storage?.hasTitle(t);
  return [
    { label: tab === "notforme" ? "Undo Not for me" : "Undo Already seen", icon: "undo", run: () => void titleAction(model, t, tab === "notforme" ? "undoNotForMe" : "undoSeen") },
    { label: onList ? "Remove from My List" : "Add to My List", icon: "bookmark", run: () => void titleAction(model, t, "myList") },
    { label: "Details", icon: "info", run: () => ui.openSheet({ kind: "tmdb", item: t }) },
  ];
}

/** A My List pick's menu (as on the iPhone): remove it, or mark it seen / not for me. */
export function myListActions(model: ReturnType<typeof useModel>, t: ExternalTitle): MenuAction[] {
  return [
    { label: "Details", icon: "info", run: () => ui.openSheet({ kind: "tmdb", item: t }) },
    { label: "Remove from My List", icon: "bookmark", danger: true, run: () => void titleAction(model, t, "myList") },
    { label: "Already seen", icon: "eye", run: () => void titleAction(model, t, "seen") },
    { label: "Not for me", icon: "thumbsDown", run: () => void titleAction(model, t, "notForMe") },
  ];
}

/** Counts for the sidebar. */
export function listCounts(model: ReturnType<typeof useModel>) {
  const st = model.storage;
  return { myList: st?.myList.length ?? 0, notForMe: (st?.notForMe.length ?? 0) + (st?.seenElsewhere.length ?? 0) };
}
