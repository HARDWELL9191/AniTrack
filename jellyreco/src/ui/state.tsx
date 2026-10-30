// Shared UI state: the model hook, per-tab page stacks, sheets, the right-click menu and the player.

import { createContext, type ReactNode, useContext, useSyncExternalStore } from "react";
import type { AppModel, Tab } from "../core/model";
import type { TmdbItem } from "../core/tmdb";
import type { Item } from "../core/types";

export const ModelContext = createContext<AppModel | null>(null);

/** The app model; the component re-renders whenever it changes. */
export function useModel(): AppModel {
  const model = useContext(ModelContext)!;
  useSyncExternalStore(model.subscribe, () => model.version);
  return model;
}

export type Route =
  | { kind: "item"; id: string; hint?: Item }
  | { kind: "library"; id: string; name: string; collectionType?: string | null }
  | { kind: "browse"; title: string; query: Record<string, unknown>; icon?: string }
  | { kind: "person"; id: string }
  | { kind: "genre"; name: string; id?: string; parentId?: string | null; types?: string[] }
  | { kind: "studio"; name: string; id?: string }
  | { kind: "dashboard"; page: string; arg?: string }
  | { kind: "liveGuide" };

export type Sheet =
  | { kind: "mediaInfo"; item: Item }
  | { kind: "editMetadata"; item: Item }
  | { kind: "editImages"; item: Item }
  | { kind: "identify"; item: Item }
  | { kind: "subtitles"; item: Item }
  | { kind: "refresh"; item: Item }
  | { kind: "addToPlaylist"; items: Item[] }
  | { kind: "addToCollection"; items: Item[] }
  | { kind: "share"; item: Item }
  | { kind: "quickConnectApprove" }
  | { kind: "syncPlay" }
  | { kind: "remoteControl" }
  | { kind: "versions"; item: Item; onPick: (mediaSourceId: string) => void }
  | { kind: "why"; item: Item; because: string[]; highlights: string[] }
  | { kind: "tmdb"; item: TmdbItem; genres: string[] }
  | { kind: "confirm"; title: string; text: string; danger?: boolean; confirmLabel?: string; run: () => void | Promise<void> }
  | { kind: "prompt"; title: string; label: string; initial?: string; confirmLabel?: string; run: (value: string) => void | Promise<void> };

export interface MenuRequest { x: number; y: number; item: Item; context?: "resume" | "playlist" | "queue"; playlistId?: string }

class UIStore {
  version = 0;
  stacks: Record<Tab, Route[]> = { home: [], forYou: [], search: [], favorites: [], library: [], settings: [], dashboard: [] };
  sheets: Sheet[] = [];
  menu: MenuRequest | null = null;
  private listeners = new Set<() => void>();

  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => void this.listeners.delete(fn);
  };
  private changed() {
    this.version++;
    for (const fn of this.listeners) fn();
  }
  push(tab: Tab, route: Route) {
    this.stacks = { ...this.stacks, [tab]: [...this.stacks[tab], route] };
    this.menu = null;
    this.changed();
  }
  replace(tab: Tab, route: Route) {
    this.stacks = { ...this.stacks, [tab]: [...this.stacks[tab].slice(0, -1), route] };
    this.changed();
  }
  pop(tab: Tab) {
    this.stacks = { ...this.stacks, [tab]: this.stacks[tab].slice(0, -1) };
    this.changed();
  }
  popToRoot(tab: Tab) {
    this.stacks = { ...this.stacks, [tab]: [] };
    this.changed();
  }
  openSheet(s: Sheet) {
    this.sheets = [...this.sheets, s];
    this.menu = null;
    this.changed();
  }
  closeSheet() {
    this.sheets = this.sheets.slice(0, -1);
    this.changed();
  }
  showMenu(m: MenuRequest | null) {
    this.menu = m;
    this.changed();
  }
}

export const ui = new UIStore();

export function useUI() {
  useSyncExternalStore(ui.subscribe, () => ui.version);
  return ui;
}

/** Opens a page in the tab you're on. */
export function useNavigate() {
  const model = useContext(ModelContext)!;
  return (route: Route) => ui.push(model.tab, route);
}

export function Provider({ model, children }: { model: AppModel; children: ReactNode }) {
  return <ModelContext.Provider value={model}>{children}</ModelContext.Provider>;
}

/** Where an item opens: folders and people get their own pages, the rest the details page. */
export function routeFor(item: Item): Route {
  switch (item.Type) {
    case "Person": return { kind: "person", id: item.Id };
    case "Genre":
    case "MusicGenre": return { kind: "genre", name: item.Name ?? "", id: item.Id };
    case "Studio": return { kind: "studio", name: item.Name ?? "", id: item.Id };
    case "CollectionFolder":
    case "UserView": return { kind: "library", id: item.Id, name: item.Name ?? "", collectionType: item.CollectionType };
    case "Folder": return { kind: "library", id: item.Id, name: item.Name ?? "", collectionType: "folders" };
    default: return { kind: "item", id: item.Id, hint: item };
  }
}
