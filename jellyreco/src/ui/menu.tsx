// The item menu: right-click on any card or row, or the "⋯" button. One menu for everything
// jellyfin-web spreads over several places (play options, your status, organizing, admin tools).

import { useEffect, useRef } from "react";
import type { AppModel } from "../core/model";
import type { Item } from "../core/types";
import { dismiss, toggleMyList, undismiss } from "./foryou";
import { AccountStorage } from "../core/storage";
import { libraryAdminItems } from "./libraryadmin";
import type { DropItem } from "./components";
import { Icon } from "./icons";
import { routeFor, ui, useModel, useUI } from "./state";

type Action = () => void;

export function itemMenuItems(model: AppModel, item: Item, context?: "resume" | "playlist" | "queue", playlistId?: string): DropItem<Action>[] {
  const p = model.player;
  const policy = model.user?.Policy;
  const admin = !!policy?.IsAdministrator;
  const go = (route: ReturnType<typeof routeFor>) => () => ui.push(model.tab, route);
  const isProgram = ["Program", "TvProgram", "LiveTvProgram"].includes(item.Type);
  const playable = !["Person", "Genre", "Studio", "MusicGenre", "Book", "CollectionFolder", "UserView"].includes(item.Type) && !isProgram;
  const items: DropItem<Action>[] = [];
  // A library itself (sidebar, My media): what jellyfin-web's library menu offers.
  if (item.Type === "CollectionFolder" || item.Type === "UserView") {
    items.push({ value: go({ kind: "library", id: item.Id, name: item.Name ?? "", collectionType: item.CollectionType }), label: "Open", icon: "folder" });
    items.push(...libraryAdminItems(model, item));
    return items;
  }

  if (playable) {
    items.push({ value: () => void p?.playItem(item, { resume: true }), label: (item.UserData?.PlaybackPositionTicks ?? 0) > 0 ? "Resume" : "Play", icon: "playFill" });
    if ((item.UserData?.PlaybackPositionTicks ?? 0) > 0) items.push({ value: () => void p?.playItem(item, { startSeconds: 0 }), label: "Play from start", icon: "repeat" });
    if (item.IsFolder || ["Series", "Season", "MusicAlbum", "MusicArtist", "Playlist", "BoxSet"].includes(item.Type)) items.push({ value: () => void p?.playItem(item, { shuffle: true }), label: "Shuffle", icon: "shuffle" });
    if (p?.state.active) {
      items.push({ value: () => void p.enqueue(item, true), label: "Play next", icon: "next" });
      items.push({ value: () => void p.enqueue(item), label: "Add to queue", icon: "queue" });
    }
    if (["Audio", "MusicAlbum", "MusicArtist", "MusicGenre"].includes(item.Type)) items.push({
      value: async () => { try { const r = await model.api!.instantMix(item.Id); await p?.playNow(r.Items, 0); } catch (e) { model.fail(e); } }, label: "Instant mix", icon: "sparkles",
    });
  }
  if (isProgram && item.ChannelId) {
    items.push({ value: () => void p?.playItem({ Id: item.ChannelId!, Type: "TvChannel", Name: item.ChannelName }), label: `Watch ${item.ChannelName ?? "channel"}`, icon: "live" });
    if (model.user?.Policy?.EnableLiveTvManagement || admin) {
      items.push({ value: () => void record(model, item, false), label: item.TimerId ? "Cancel recording" : "Record", icon: "calendar" });
      if (item.IsSeries) items.push({ value: () => void record(model, item, true), label: item.SeriesTimerId ? "Cancel series recording" : "Record series", icon: "repeat" });
    }
  }

  items.push("divider");
  items.push({ value: go(routeFor(item)), label: "Open details", icon: "info" });
  if (item.SeriesId && item.Type !== "Series") items.push({ value: go({ kind: "item", id: item.SeriesId }), label: `Go to ${item.SeriesName ?? "show"}`, icon: "tv" });
  if (item.SeasonId && item.Type === "Episode") items.push({ value: go({ kind: "item", id: item.SeasonId }), label: `Go to ${item.SeasonName ?? "season"}`, icon: "layers" });
  if (item.AlbumId && item.Type === "Audio") items.push({ value: go({ kind: "item", id: item.AlbumId }), label: "Go to album", icon: "music" });
  if (item.ArtistItems?.[0]) items.push({ value: go({ kind: "item", id: item.ArtistItems[0].Id }), label: `Go to ${item.ArtistItems[0].Name}`, icon: "person" });

  items.push("divider");
  if (playable || item.Type === "Book") {
    items.push({ value: () => void model.togglePlayed(item), label: item.UserData?.Played ? "Mark unwatched" : "Mark watched", icon: "checkCircle" });
  }
  items.push({ value: () => void model.toggleFavorite(item), label: item.UserData?.IsFavorite ? "Remove from favorites" : "Add to favorites", icon: "heart" });
  if (context === "resume") items.push({
    value: async () => { try { await model.api!.updateUserData(item.Id, { PlaybackPositionTicks: 0 }); model.dataChanged(); } catch (e) { model.fail(e); } }, label: "Remove from Continue watching", icon: "x",
  });
  if (["Series", "Movie", "Season", "Episode"].includes(item.Type)) {
    const onList = !!model.storage?.hasServer(AccountStorage.listId(item));
    items.push({ value: () => void toggleMyList(model, item), label: onList ? "Remove from My List" : "Add to My List", icon: "bookmark" });
  }
  if (["Series", "Movie"].includes(item.Type)) {
    const out = model.dismissed.has(item.Id) || item.UserData?.Likes === false;
    items.push({ value: () => { if (out) { void undismiss(model, item); model.toast("Back in For You", "success"); } else { void dismiss(model, item); model.toast("Won't count towards For You", "success"); } }, label: out ? "Undo Not for me" : "Not for me", icon: "thumbsDown" });
  }
  if (playable) items.push({ value: () => ui.openSheet({ kind: "addToPlaylist", items: [item] }), label: "Add to playlist…", icon: "playlist" });
  if (playable && (admin || policy?.EnableCollectionManagement) && item.Type !== "BoxSet") items.push({ value: () => ui.openSheet({ kind: "addToCollection", items: [item] }), label: "Add to collection…", icon: "collection" });
  if (context === "playlist" && playlistId && item.PlaylistItemId) items.push({
    value: async () => { try { await model.api!.del(`/Playlists/${playlistId}/Items`, { entryIds: [item.PlaylistItemId!] }); model.dataChanged(); } catch (e) { model.fail(e); } }, label: "Remove from playlist", icon: "x", danger: true,
  });

  items.push("divider");
  if (item.MediaSources?.length || item.MediaType === "Video" || item.MediaType === "Audio") items.push({ value: () => ui.openSheet({ kind: "mediaInfo", item }), label: "Media info", icon: "info" });
  if (item.CanDownload || (policy?.EnableContentDownloading && playable && !item.IsFolder)) items.push({
    value: async () => { try { const { openUrl } = await import("@tauri-apps/plugin-opener"); await openUrl(model.api!.downloadUrl(item.Id)); } catch (e) { model.fail(e); } }, label: "Download", icon: "download",
  });
  if (playable && !item.IsFolder) items.push({ value: () => { void navigator.clipboard.writeText(model.api!.authedUrl(`/Items/${item.Id}/Download`)).then(() => model.toast("Stream link copied", "success")); }, label: "Copy stream link", icon: "copy" });
  if ((admin || policy?.EnableSubtitleManagement) && ["Movie", "Episode", "Video", "MusicVideo"].includes(item.Type)) items.push({ value: () => ui.openSheet({ kind: "subtitles", item }), label: "Edit subtitles…", icon: "subtitles" });

  if (admin) {
    items.push({ section: "Manage" });
    items.push({ value: () => ui.openSheet({ kind: "editMetadata", item }), label: "Edit metadata…", icon: "edit" });
    items.push({ value: () => ui.openSheet({ kind: "editImages", item }), label: "Edit images…", icon: "image" });
    if (["Movie", "Series", "MusicAlbum", "MusicArtist", "BoxSet", "Person", "Book", "MusicVideo", "Trailer"].includes(item.Type)) items.push({ value: () => ui.openSheet({ kind: "identify", item }), label: "Identify…", icon: "search" });
    items.push({ value: () => ui.openSheet({ kind: "refresh", item }), label: "Refresh metadata…", icon: "refresh" });
  }
  if (item.CanDelete || (admin && !["CollectionFolder", "UserView", "Person"].includes(item.Type))) {
    items.push({
      value: () => ui.openSheet({
        kind: "confirm", danger: true, confirmLabel: "Delete", title: `Delete ${item.Name}?`,
        text: "This deletes the files from the server's disk. It can't be undone.",
        run: async () => { await model.api!.deleteItem(item.Id); model.toast("Deleted", "success"); ui.popToRoot(model.tab); model.dataChanged(); },
      }), label: "Delete from server…", icon: "trash", danger: true,
    });
  }
  // Drop leading/trailing/double dividers.
  return items.filter((x, i, a) => x !== "divider" || (i > 0 && i < a.length - 1 && a[i - 1] !== "divider"));
}

async function record(model: AppModel, program: Item, series: boolean) {
  const api = model.api!;
  try {
    if (series) {
      if (program.SeriesTimerId) await api.del(`/LiveTv/SeriesTimers/${program.SeriesTimerId}`);
      else {
        const defaults = await api.get<Record<string, unknown>>("/LiveTv/Timers/Defaults", { programId: program.Id });
        await api.post("/LiveTv/SeriesTimers", defaults);
      }
    } else if (program.TimerId) await api.del(`/LiveTv/Timers/${program.TimerId}`);
    else {
      const defaults = await api.get<Record<string, unknown>>("/LiveTv/Timers/Defaults", { programId: program.Id });
      await api.post("/LiveTv/Timers", defaults);
    }
    model.toast(series ? (program.SeriesTimerId ? "Series recording cancelled" : "Series will be recorded") : program.TimerId ? "Recording cancelled" : "Will be recorded", "success");
    model.dataChanged();
  } catch (e) {
    model.fail(e, "Recording");
  }
}

/** The floating right-click menu. */
export function ItemMenu() {
  const state = useUI();
  const model = useModel();
  const ref = useRef<HTMLDivElement>(null);
  const m = state.menu;
  useEffect(() => {
    if (!m) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) ui.showMenu(null); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); ui.showMenu(null); } };
    const t = setTimeout(() => window.addEventListener("mousedown", close), 0);
    window.addEventListener("keydown", esc, true);
    window.addEventListener("blur", () => ui.showMenu(null), { once: true });
    return () => { clearTimeout(t); window.removeEventListener("mousedown", close); window.removeEventListener("keydown", esc, true); };
  }, [m]);
  useEffect(() => {
    // Keep it on screen.
    const el = ref.current;
    if (!el || !m) return;
    const r = el.getBoundingClientRect();
    if (r.bottom > window.innerHeight - 8) el.style.top = `${Math.max(8, window.innerHeight - r.height - 8)}px`;
    if (r.right > window.innerWidth - 8) el.style.left = `${Math.max(8, window.innerWidth - r.width - 8)}px`;
  });
  if (!m) return null;
  const items: DropItem<Action>[] = m.actions ? m.actions.map((a) => ({ value: a.run, label: a.label, icon: a.icon, danger: a.danger })) : itemMenuItems(model, m.item, m.context, m.playlistId);
  return (
    <div ref={ref} className="menu context-menu" style={{ left: m.x, top: m.y }} role="menu">
      <div className="menu-title">{m.item.Name}</div>
      {items.map((item, i) => {
        if (item === "divider") return <div key={i} className="menu-divider" />;
        if ("section" in item) return <div key={i} className="menu-section">{item.section}</div>;
        return (
          <button key={i} className={`menu-item ${item.danger ? "danger" : ""}`} onClick={() => { ui.showMenu(null); item.value(); }}>
            <span className="menu-icon">{item.icon && <Icon name={item.icon} size={16} />}</span>
            <span className="menu-label">{item.label}</span>
          </button>
        );
      })}
    </div>
  );
}
