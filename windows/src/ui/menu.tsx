// Right-click (or long-press on a touch screen) menu for any show: the long-press menu of the
// iPhone app, plus the actions the iPhone's swipes do (Remove from list, Completed, Bring back).

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { displayTitle, type Media } from "../core/models";
import { Icon } from "./icons";
import { ui, useModel, useUI } from "./state";

interface Item { label: string; icon: string; run: () => void; danger?: boolean }

export function ShowMenu() {
  const state = useUI();
  const model = useModel();
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ x: number; y: number } | null>(null);
  const req = state.menu;

  useEffect(() => {
    if (!req) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) ui.showMenu(null); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") ui.showMenu(null); };
    const scroll = () => ui.showMenu(null);
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", esc);
    window.addEventListener("wheel", scroll, { passive: true });
    window.addEventListener("resize", scroll);
    return () => {
      window.removeEventListener("mousedown", close);
      window.removeEventListener("keydown", esc);
      window.removeEventListener("wheel", scroll);
      window.removeEventListener("resize", scroll);
    };
  }, [req]);

  // Keep the menu on screen.
  useLayoutEffect(() => {
    if (!req || !ref.current) return setPos(null);
    const r = ref.current.getBoundingClientRect();
    setPos({ x: Math.min(req.x, window.innerWidth - r.width - 8), y: Math.min(req.y, window.innerHeight - r.height - 8) });
  }, [req]);

  if (!req) return null;
  const items = menuItems(req.media, !!req.inSheet, model);
  return (
    <div ref={ref} className="menu context-menu" style={{ left: pos?.x ?? req.x, top: pos?.y ?? req.y, visibility: pos ? "visible" : "hidden" }}>
      <div className="menu-title">{displayTitle(req.media, model.settings.titleLanguage)}</div>
      {items.map((it) => (
        <button key={it.label} className={`menu-item ${it.danger ? "danger" : ""}`} onClick={() => { ui.showMenu(null); it.run(); }}>
          <span className="menu-icon"><Icon name={it.icon} size={16} /></span>
          <span className="menu-label">{it.label}</span>
        </button>
      ))}
    </div>
  );
}

function menuItems(media: Media, inSheet: boolean, model: ReturnType<typeof useModel>): Item[] {
  const entry = model.entry(media.id);
  const dismissed = model.settings.dismissedPicks.has(media.id);
  const items: Item[] = [];
  // Only for shows not on your lists: it must never move a watched show back to Planning.
  if (model.canEdit && !entry) items.push({ label: "Plan to watch", icon: "bookmark", run: () => void model.planToWatch(media) });
  items.push({
    label: "Details", icon: "info", run: () => {
      if (inSheet) ui.setSheetRoute({ kind: "detail", id: media.id });
      else ui.push(model.selectedTab, { kind: "detail", id: media.id });
    },
  });
  if (!entry && !dismissed) items.push({ label: "Not for me", icon: "thumbsDown", danger: true, run: () => model.dismissPick(media.id, media) });
  if (dismissed) items.push({ label: "Bring back", icon: "undo", run: () => void model.undoNotForMe(media.id) });
  if (model.canEdit && entry?.status !== "COMPLETED") items.push({ label: "Already watched", icon: "eye", run: () => void model.markCompleted(media) });
  if (!inSheet) {
    items.push({ label: "More like this", icon: "layers", run: () => ui.openSheet({ kind: "moreLikeThis", media }) });
    items.push({ label: "Why would I like this?", icon: "sparkles", run: () => ui.openSheet({ kind: "why", media }) });
  }
  if (model.canEdit && entry) {
    // The whole show (every season), straight away, like the iPhone's swipe.
    items.push({
      label: "Remove from list", icon: "trash", danger: true, run: () => {
        model.removeShow(media, entry.id).catch((e) => model.showError((e as Error).message));
      },
    });
  }
  return items;
}
