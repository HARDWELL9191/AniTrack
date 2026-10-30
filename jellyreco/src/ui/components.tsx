// Building blocks shared by every screen (AniReco's cards, shelves, menus and sheets).

import { type CSSProperties, type ReactNode, useEffect, useLayoutEffect, useRef, useState, type MouseEvent as RMouseEvent } from "react";
import type { Jellyfin } from "../core/api";
import type { Item } from "../core/types";
import { itemSubtitle, itemTitle, playedPercent } from "./fmt";
import { Icon } from "./icons";
import { routeFor, ui, useModel, useNavigate } from "./state";

// MARK: Images

export type Shape = "poster" | "landscape" | "square";

export function shapeFor(item: Item): Shape {
  switch (item.Type) {
    case "Episode":
    case "Video":
    case "MusicVideo":
    case "TvChannel":
    case "LiveTvChannel":
    case "Program":
    case "TvProgram":
    case "LiveTvProgram":
    case "Recording":
    case "CollectionFolder":
    case "UserView":
    case "Photo":
      return "landscape";
    case "Audio":
    case "MusicAlbum":
    case "MusicArtist":
    case "Playlist":
    case "PhotoAlbum":
    case "Genre":
    case "MusicGenre":
      return "square";
    default:
      return "poster";
  }
}

/** The best image for a card of this shape (falls back to the series/album/parent images). */
export function cardImage(api: Jellyfin, item: Item, shape: Shape, width: number): string | undefined {
  const w = Math.round(width * Math.min(window.devicePixelRatio || 1, 2));
  const tags = item.ImageTags ?? {};
  if (shape === "landscape") {
    if (item.Type === "Episode" && tags.Primary) return api.image(item.Id, "Primary", { tag: tags.Primary, maxWidth: w });
    if (tags.Thumb) return api.image(item.Id, "Thumb", { tag: tags.Thumb, maxWidth: w });
    if (item.ParentThumbItemId && item.ParentThumbImageTag) return api.image(item.ParentThumbItemId, "Thumb", { tag: item.ParentThumbImageTag, maxWidth: w });
    if (item.BackdropImageTags?.length) return api.image(item.Id, "Backdrop", { tag: item.BackdropImageTags[0], maxWidth: w });
    if (item.ParentBackdropItemId && item.ParentBackdropImageTags?.length) return api.image(item.ParentBackdropItemId, "Backdrop", { tag: item.ParentBackdropImageTags[0], maxWidth: w });
    if (tags.Primary) return api.image(item.Id, "Primary", { tag: tags.Primary, maxWidth: w });
    return undefined;
  }
  if (tags.Primary) return api.image(item.Id, "Primary", { tag: tags.Primary, maxWidth: w });
  if (item.Type === "Episode" && item.SeriesId && item.SeriesPrimaryImageTag) return api.image(item.SeriesId, "Primary", { tag: item.SeriesPrimaryImageTag, maxWidth: w });
  if (item.Type === "Season" && item.SeriesId && item.SeriesPrimaryImageTag) return api.image(item.SeriesId, "Primary", { tag: item.SeriesPrimaryImageTag, maxWidth: w });
  if (item.AlbumId && item.AlbumPrimaryImageTag) return api.image(item.AlbumId, "Primary", { tag: item.AlbumPrimaryImageTag, maxWidth: w });
  if (item.Type === "Person" || item.Type === "MusicArtist" || item.Type === "Genre" || item.Type === "Studio") return api.image(item.Id, "Primary", { maxWidth: w });
  return undefined;
}

export function backdropUrl(api: Jellyfin, item: Item, width = 1920): string | undefined {
  if (item.BackdropImageTags?.length) return api.image(item.Id, "Backdrop", { tag: item.BackdropImageTags[0], maxWidth: width });
  if (item.ParentBackdropItemId && item.ParentBackdropImageTags?.length) return api.image(item.ParentBackdropItemId, "Backdrop", { tag: item.ParentBackdropImageTags[0], maxWidth: width });
  return undefined;
}

export function logoUrl(api: Jellyfin, item: Item, width = 600): string | undefined {
  if (item.ImageTags?.Logo) return api.image(item.Id, "Logo", { tag: item.ImageTags.Logo, maxWidth: width });
  if (item.ParentLogoItemId && item.ParentLogoImageTag) return api.image(item.ParentLogoItemId, "Logo", { tag: item.ParentLogoImageTag, maxWidth: width });
  return undefined;
}

const typeIcon: Partial<Record<string, string>> = {
  Movie: "film", Series: "tv", Season: "tv", Episode: "tv", MusicAlbum: "music", Audio: "music", MusicArtist: "music", Person: "person",
  BoxSet: "collection", Playlist: "playlist", Photo: "photo", PhotoAlbum: "photo", Book: "book", AudioBook: "book", TvChannel: "live",
  LiveTvChannel: "live", Folder: "folder", CollectionFolder: "folder", UserView: "folder",
};

export function Cover({ url, width, height, radius = 12, icon, className, style }: { url?: string; width: number | string; height: number | string; radius?: number; icon?: string; className?: string; style?: CSSProperties }) {
  const [failed, setFailed] = useState(false);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => { setFailed(false); setLoaded(false); }, [url]);
  return (
    <div className={`cover ${className ?? ""}`} style={{ width, height, borderRadius: radius, ...style }}>
      {url && !failed ? (
        <img src={url} alt="" loading="lazy" decoding="async" draggable={false} className={loaded ? "loaded" : ""} onLoad={() => setLoaded(true)} onError={() => setFailed(true)} />
      ) : (
        <div className="cover-placeholder"><Icon name={icon ?? "film"} size={28} strokeWidth={1.5} /></div>
      )}
    </div>
  );
}

// MARK: Cards

function useItemMenu(item: Item, context?: "resume" | "playlist" | "queue", playlistId?: string) {
  return (e: RMouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    ui.showMenu({ x: e.clientX, y: e.clientY, item, context, playlistId });
  };
}

export function Rating({ value }: { value?: number | null }) {
  if (!value) return null;
  return <span className="score score-ok"><Icon name="star" size={13} strokeWidth={2} />{value.toFixed(1)}</span>;
}

export function WatchedBadge({ item }: { item: Item }) {
  const ud = item.UserData;
  if (!ud) return null;
  if (ud.Played) return <div className="card-status played"><Icon name="check" size={15} strokeWidth={2.6} /></div>;
  if (ud.UnplayedItemCount && (item.Type === "Series" || item.Type === "Season" || item.Type === "BoxSet")) return <div className="card-status count">{ud.UnplayedItemCount}</div>;
  return null;
}

export function ProgressLine({ percent }: { percent: number }) {
  if (!(percent > 0 && percent < 100)) return null;
  return <div className="card-progress"><div style={{ width: `${percent}%` }} /></div>;
}

/** A cover card. Click opens it, the play button plays it, right-click opens the menu. */
export function ItemCard({ item, width, shape, onClick, subtitle, showPlay = true, context, playlistId, badge }: {
  item: Item; width?: number; shape?: Shape; onClick?: () => void; subtitle?: string | null; showPlay?: boolean;
  context?: "resume" | "playlist" | "queue"; playlistId?: string; badge?: ReactNode;
}) {
  const model = useModel();
  const navigate = useNavigate();
  const onMenu = useItemMenu(item, context, playlistId);
  const s = shape ?? shapeFor(item);
  const w = width ?? (s === "landscape" ? 300 : s === "square" ? 170 : model.settings.libraryCardSize);
  const h = s === "landscape" ? Math.round(w * 9 / 16) : s === "square" ? w : Math.round(w * 1.5);
  const api = model.api!;
  const playable = isPlayable(item);
  const percent = playedPercent(item);
  const blur = model.settings.blurUnwatched && item.Type === "Episode" && !item.UserData?.Played;
  return (
    <div className="card" style={{ width: w }} onContextMenu={onMenu}>
      <button className="card-cover" onClick={onClick ?? (() => navigate(routeFor(item)))} title={itemTitle(item)} aria-label={itemTitle(item)}>
        <Cover url={cardImage(api, item, s, w)} width={w} height={h} radius={s === "square" && (item.Type === "Person" || item.Type === "MusicArtist") ? w / 2 : 12} icon={typeIcon[item.Type]} style={blur ? { filter: "blur(10px)" } : undefined} />
        <WatchedBadge item={item} />
        {item.UserData?.IsFavorite && <div className="card-fav"><Icon name="heartFill" size={13} /></div>}
        {badge && <div className="card-age">{badge}</div>}
        <ProgressLine percent={percent} />
        {showPlay && playable && (
          <span className="card-play" role="button" aria-label="Play" onClick={(e) => { e.stopPropagation(); void model.player?.playItem(item, { resume: true }); }}>
            <Icon name="playFill" size={20} />
          </span>
        )}
        <span className="card-more" role="button" aria-label="More" onClick={onMenu}><Icon name="more" size={18} /></span>
      </button>
      <div className="card-title">{itemTitle(item)}</div>
      {(subtitle ?? itemSubtitle(item)) && <div className="card-sub">{subtitle ?? itemSubtitle(item)}</div>}
    </div>
  );
}

export function isPlayable(item: Item): boolean {
  if (item.Type === "Person" || item.Type === "Genre" || item.Type === "Studio" || item.Type === "MusicGenre" || item.Type === "Book") return false;
  if (item.Type === "CollectionFolder" || item.Type === "UserView" || item.Type === "Folder") return false;
  if (item.Type === "Program" || item.Type === "TvProgram" || item.Type === "LiveTvProgram") return !!item.ChannelId;
  return true;
}

/** List row: thumbnail, title, subtitle and trailing content. */
export function ItemRow({ item, subtitle, trailing, onClick, index, context, playlistId }: { item: Item; subtitle?: ReactNode; trailing?: ReactNode; onClick?: () => void; index?: number; context?: "resume" | "playlist" | "queue"; playlistId?: string }) {
  const model = useModel();
  const navigate = useNavigate();
  const onMenu = useItemMenu(item, context, playlistId);
  const s = shapeFor(item);
  const w = s === "landscape" ? 128 : s === "square" ? 56 : 56;
  const h = s === "landscape" ? 72 : s === "square" ? 56 : 84;
  return (
    <button className="row" onClick={onClick ?? (() => navigate(routeFor(item)))} onContextMenu={onMenu}>
      {index !== undefined && <span className="row-index tabular">{index}</span>}
      <Cover url={cardImage(model.api!, item, s, w)} width={w} height={h} radius={8} icon={typeIcon[item.Type]} />
      <div className="row-text">
        <div className="row-title">{itemTitle(item)}</div>
        <div className="row-sub">{subtitle ?? itemSubtitle(item)}</div>
      </div>
      {item.UserData?.Played && <Icon name="checkCircle" size={18} className="row-played" />}
      {trailing}
      <span className="row-more" role="button" onClick={onMenu} aria-label="More"><Icon name="more" size={18} /></span>
    </button>
  );
}

// MARK: Shelves and grids

/** A horizontal shelf of cards with arrow buttons (and the mouse wheel). */
export function Shelf({ title, action, children, icon, subtitle }: { title: ReactNode; action?: { label: string; run: () => void }; children: ReactNode; icon?: string; subtitle?: ReactNode }) {
  const scroller = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState({ start: true, end: false });
  const update = () => {
    const el = scroller.current;
    if (!el) return;
    const start = el.scrollLeft < 4;
    const end = el.scrollLeft + el.clientWidth >= el.scrollWidth - 4;
    setEdges((e) => (e.start === start && e.end === end ? e : { start, end }));
  };
  useLayoutEffect(update);
  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const move = (dir: number) => {
    const el = scroller.current;
    if (el) el.scrollBy({ left: dir * el.clientWidth * 0.85, behavior: "smooth" });
  };
  return (
    <section className="shelf">
      <header className="shelf-head">
        <h2>{icon && <Icon name={icon} size={18} />} {title}</h2>
        {subtitle && <span className="muted small">{subtitle}</span>}
        <div className="shelf-actions">
          {action && <button className="link-button" onClick={action.run}>{action.label}</button>}
          <button className="round-button" disabled={edges.start} onClick={() => move(-1)} aria-label="Back"><Icon name="chevronLeft" size={16} /></button>
          <button className="round-button" disabled={edges.end} onClick={() => move(1)} aria-label="Next"><Icon name="chevronRight" size={16} /></button>
        </div>
      </header>
      <div className="shelf-row" ref={scroller} onScroll={update}>{children}</div>
    </section>
  );
}

export function Grid({ children, min = 160 }: { children: ReactNode; min?: number }) {
  return <div className="grid" style={{ gridTemplateColumns: `repeat(auto-fill, minmax(${min}px, 1fr))` }}>{children}</div>;
}

// MARK: Small pieces

export function Spinner({ label }: { label?: string }) {
  return (
    <div className="spinner-wrap">
      <span className="spinner" />
      {label && <span className="muted">{label}</span>}
    </div>
  );
}

export function Empty({ icon, title, text, children }: { icon: string; title: string; text?: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <Icon name={icon} size={40} strokeWidth={1.4} />
      <h3>{title}</h3>
      {text && <p>{text}</p>}
      {children}
    </div>
  );
}

export function Chip({ text, tone, onClick }: { text: string; tone?: "accent" | "muted" | "danger"; onClick?: () => void }) {
  if (onClick) return <button className={`chip chip-button chip-${tone ?? "accent"}`} onClick={onClick}>{text}</button>;
  return <span className={`chip chip-${tone ?? "accent"}`}>{text}</span>;
}

export type DropItem<T> = { value: T; label: string; detail?: string; icon?: string; selected?: boolean; danger?: boolean; disabled?: boolean } | { section: string } | "divider";

/** A glass dropdown button with a menu. */
export function Dropdown<T>({ label, icon, items, onPick, align = "right", compact, up, title, className }: {
  label: ReactNode; icon?: string; compact?: boolean; up?: boolean; title?: string; className?: string;
  items: DropItem<T>[]; onPick: (v: T) => void; align?: "left" | "right";
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); setOpen(false); } };
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", esc, true);
    return () => { window.removeEventListener("mousedown", close); window.removeEventListener("keydown", esc, true); };
  }, [open]);
  return (
    <div className={`dropdown ${className ?? ""}`} ref={ref}>
      <button className={`glass-button dropdown-button ${compact ? "icon-only" : ""}`} onClick={() => setOpen(!open)} aria-expanded={open} title={title}>
        {icon && <Icon name={icon} size={17} />}
        {label}
        {!compact && <Icon name="chevronDown" size={14} strokeWidth={2.4} />}
      </button>
      {open && (
        <div className={`menu dropdown-menu ${align} ${up ? "up" : ""}`}>
          {items.map((item, i) => {
            if (item === "divider") return <div key={i} className="menu-divider" />;
            if ("section" in item) return <div key={i} className="menu-section">{item.section}</div>;
            return (
              <button key={i} className={`menu-item ${item.danger ? "danger" : ""}`} disabled={item.disabled} onClick={() => { setOpen(false); onPick(item.value); }}>
                <span className="menu-icon">{item.selected ? <Icon name="check" size={16} /> : item.icon ? <Icon name={item.icon} size={16} /> : null}</span>
                <span className="menu-label">{item.label}{item.detail && <small>{item.detail}</small>}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

export function Modal({ title, onClose, children, width = 560, actions, closeLabel = "Close" }: { title: ReactNode; onClose: () => void; children: ReactNode; width?: number; actions?: ReactNode; closeLabel?: string }) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); onClose(); } };
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);
  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal" style={{ width }} role="dialog" aria-modal="true">
        <header className="modal-head">
          <button className="glass-button" onClick={onClose}>{closeLabel}</button>
          <h2>{title}</h2>
          <div className="modal-actions">{actions}</div>
        </header>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}

export function SearchField({ value, onChange, placeholder, autoFocus, onEnter }: { value: string; onChange: (v: string) => void; placeholder: string; autoFocus?: boolean; onEnter?: () => void }) {
  return (
    <label className="search-field">
      <Icon name="search" size={17} />
      <input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} autoFocus={autoFocus} spellCheck={false}
        onKeyDown={(e) => { if (e.key === "Enter") onEnter?.(); }} />
      {value && <button className="search-clear" onClick={() => onChange("")} aria-label="Clear"><Icon name="x" size={14} /></button>}
    </label>
  );
}

export function PageHeader({ title, children, back, subtitle }: { title: ReactNode; children?: ReactNode; back?: () => void; subtitle?: ReactNode }) {
  return (
    <header className="page-head">
      {back && <button className="round-button back" onClick={back} aria-label="Back"><Icon name="chevronLeft" size={18} /></button>}
      <div className="page-title">
        <h1>{title}</h1>
        {subtitle && <div className="muted small">{subtitle}</div>}
      </div>
      <div className="page-head-actions">{children}</div>
    </header>
  );
}

/** Loads more when the end of a list scrolls into view. */
export function LoadMore({ onVisible, active }: { onVisible: () => void; active: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el || !active) return;
    const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) onVisible(); }, { rootMargin: "600px" });
    io.observe(el);
    return () => io.disconnect();
  }, [onVisible, active]);
  return <div ref={ref} className="load-more" />;
}

export function Toggle({ checked, onChange, label, detail, disabled }: { checked: boolean; onChange: (v: boolean) => void; label: ReactNode; detail?: ReactNode; disabled?: boolean }) {
  return (
    <label className="toggle-row">
      <span className="toggle-text"><span>{label}</span>{detail && <small className="muted">{detail}</small>}</span>
      <input type="checkbox" className="switch" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

export function Segmented<T extends string | number>({ value, options, onChange }: { value: T; options: { value: T; label: string; icon?: string }[]; onChange: (v: T) => void }) {
  return (
    <div className="segmented">
      {options.map((o) => (
        <button key={String(o.value)} className={o.value === value ? "on" : ""} onClick={() => onChange(o.value)}>
          {o.icon && <Icon name={o.icon} size={14} />}{o.label}
        </button>
      ))}
    </div>
  );
}

export function Field({ label, children, hint }: { label: ReactNode; children: ReactNode; hint?: ReactNode }) {
  return (
    <label className="field">
      <span>{label}</span>
      {children}
      {hint && <small className="muted">{hint}</small>}
    </label>
  );
}

export function Group({ title, children, actions }: { title?: ReactNode; children: ReactNode; actions?: ReactNode }) {
  return (
    <section className="group panel">
      {(title || actions) && <div className="group-head">{title && <div className="group-title">{title}</div>}{actions}</div>}
      {children}
    </section>
  );
}

/** Runs an async action and shows its error as a toast. */
export function useAction() {
  const model = useModel();
  const [busy, setBusy] = useState(false);
  const run = async (fn: () => Promise<unknown>, success?: string) => {
    setBusy(true);
    try {
      await fn();
      if (success) model.toast(success, "success");
      return true;
    } catch (e) {
      model.fail(e);
      return false;
    } finally {
      setBusy(false);
    }
  };
  return { busy, run };
}

/** Loads data with cancellation; reloads when deps change. */
export function useLoad<T>(load: (signal: AbortSignal) => Promise<T>, deps: unknown[]): { data: T | undefined; error: string | null; loading: boolean; reload: () => void; setData: (v: T) => void } {
  const [data, setData] = useState<T>();
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [nonce, setNonce] = useState(0);
  useEffect(() => {
    const ctrl = new AbortController();
    setLoading(true);
    setError(null);
    load(ctrl.signal)
      .then((v) => { if (!ctrl.signal.aborted) setData(v); })
      .catch((e) => { if (!ctrl.signal.aborted && e?.name !== "AbortError") setError(e?.message ?? String(e)); })
      .finally(() => { if (!ctrl.signal.aborted) setLoading(false); });
    return () => ctrl.abort();
  }, [...deps, nonce]); // eslint-disable-line react-hooks/exhaustive-deps
  return { data, error, loading, reload: () => setNonce((n) => n + 1), setData };
}

export function ErrorNote({ text, retry }: { text: string; retry?: () => void }) {
  return (
    <div className="empty">
      <Icon name="info" size={36} strokeWidth={1.5} />
      <h3>Couldn't load this</h3>
      <p>{text}</p>
      {retry && <button className="glass-button" onClick={retry}><Icon name="refresh" size={15} /> Try again</button>}
    </div>
  );
}
