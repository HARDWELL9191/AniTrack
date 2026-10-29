// Shared UI state: the app model hook, per-tab navigation and the sheets that can open anywhere.

import { createContext, ReactNode, useContext, useSyncExternalStore } from "react";
import { AppModel, AppTab } from "../core/model";
import { AnimeCategory, Media } from "../core/models";

export const ModelContext = createContext<AppModel | null>(null);

/** The app model; the calling component re-renders whenever it changes. */
export function useModel(): AppModel {
  const model = useContext(ModelContext)!;
  useSyncExternalStore((fn) => model.subscribe(fn), () => model.version);
  return model;
}

export type Route = { kind: "detail"; id: number } | { kind: "category"; category: AnimeCategory };

export type Sheet =
  | { kind: "editor"; media: Media }
  | { kind: "moreLikeThis"; media: Media }
  | { kind: "why"; media: Media }
  | { kind: "export" }
  | { kind: "allCategories"; onPick: (c: AnimeCategory) => void };

export interface MenuRequest {
  x: number;
  y: number;
  media: Media;
  /** In a sheet: no second sheet on top. */
  inSheet?: boolean;
}

class UIStore {
  version = 0;
  stacks: Record<AppTab, Route[]> = { home: [], forYou: [], discover: [], lists: [], profile: [] };
  sheets: Sheet[] = [];
  menu: MenuRequest | null = null;
  /** The More like this sheet has its own little stack (details open inside it). */
  sheetRoute: Route | null = null;
  private listeners = new Set<() => void>();

  subscribe = (fn: () => void) => {
    this.listeners.add(fn);
    return () => void this.listeners.delete(fn);
  };
  private changed() {
    this.version++;
    for (const fn of this.listeners) fn();
  }
  push(tab: AppTab, route: Route) {
    this.stacks = { ...this.stacks, [tab]: [...this.stacks[tab], route] };
    this.changed();
  }
  pop(tab: AppTab) {
    this.stacks = { ...this.stacks, [tab]: this.stacks[tab].slice(0, -1) };
    this.changed();
  }
  popToRoot(tab: AppTab) {
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
    if (!this.sheets.some((s) => s.kind === "moreLikeThis")) this.sheetRoute = null;
    this.changed();
  }
  showMenu(m: MenuRequest | null) {
    this.menu = m;
    this.changed();
  }
  setSheetRoute(r: Route | null) {
    this.sheetRoute = r;
    this.changed();
  }
}

export const ui = new UIStore();

export function useUI() {
  useSyncExternalStore(ui.subscribe, () => ui.version);
  return ui;
}

/** Inside a sheet, "open details" opens within the sheet instead of the tab behind it. */
export const InSheetContext = createContext(false);

/** Opens a show's details in the current tab (or inside the sheet). */
export function useOpenDetail() {
  const model = useContext(ModelContext)!;
  const inSheet = useContext(InSheetContext);
  return (id: number) => {
    if (inSheet) ui.setSheetRoute({ kind: "detail", id });
    else ui.push(model.selectedTab, { kind: "detail", id });
  };
}

export function Provider({ model, children }: { model: AppModel; children: ReactNode }) {
  return <ModelContext.Provider value={model}>{children}</ModelContext.Provider>;
}
