// Building blocks shared by every screen (port of Components.swift / ShowActions.swift bubbles).

import { type ReactNode, useEffect, useLayoutEffect, useRef, useState, type MouseEvent as RMouseEvent } from "react";
import { ageExplanation, ageLabel } from "../core/kitsu";
import { coverURL, displayTitle, formatLabel, type Media, seasonLabel, statusIcon, thumbURL } from "../core/models";
import { hexColor, outOfTen, smiley } from "./fmt";
import { Icon } from "./icons";
import { ui, useModel, useOpenDetail } from "./state";
import { InSheetContext } from "./state";
import { useContext } from "react";

export function Cover({ url, color, width, height, radius = 10, className }: { url?: string; color?: string | null; width: number | string; height: number | string; radius?: number; className?: string }) {
  const [failed, setFailed] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const tint = hexColor(color) ?? "#5a5f6e";
  return (
    <div className={`cover ${className ?? ""}`} style={{ width, height, borderRadius: radius, background: `color-mix(in srgb, ${tint} 28%, transparent)` }}>
      {url && !failed && (
        <img src={url} alt="" loading="lazy" decoding="async" draggable={false}
          className={loaded ? "loaded" : ""} onLoad={() => setLoaded(true)} onError={() => setFailed(true)} />
      )}
    </div>
  );
}

export function MatchBubble({ value }: { value: number }) {
  return <span className="bubble bubble-match">{value}%</span>;
}

export function AgeBubble({ label }: { label: string }) {
  return <span className="bubble bubble-age">{label}</span>;
}

/** The age bubble for a show, if its rating is known (asks Kitsu when it appears). */
export function AgeBadge({ media }: { media: Media }) {
  const model = useModel();
  useEffect(() => model.ages.request(media), [media, model]);
  const label = ageLabel(model.ages.rating(media.id));
  return label ? <AgeBubble label={label} /> : null;
}

export function AgeLine({ media }: { media: Media }) {
  const model = useModel();
  useEffect(() => model.ages.request(media), [media, model]);
  const text = ageExplanation(model.ages.rating(media.id));
  return text ? <span className="age-line"><Icon name="shield" size={15} /> {text}</span> : null;
}

/** Community score out of 10 with a mood smiley. */
export function ScoreBadge({ score }: { score?: number | null }) {
  if (!score || score <= 0) return null;
  const tone = score >= 75 ? "good" : score >= 60 ? "ok" : "low";
  return (
    <span className={`score score-${tone}`}>
      <Icon name={smiley(score)} size={14} strokeWidth={1.8} />
      {outOfTen(score)}
    </span>
  );
}

/** Personal match %, next to the community score. */
export function MatchBadge({ media, word = false }: { media: Media; word?: boolean }) {
  const model = useModel();
  const v = model.matcher.match(media);
  if (v === undefined) return null;
  return <span className="match"><Icon name="wand" size={14} />{word ? `${v}% match` : `${v}%`}</span>;
}

export function Chip({ text, tone }: { text: string; tone?: "accent" | "muted" | "danger" }) {
  return <span className={`chip chip-${tone ?? "accent"}`}>{text}</span>;
}

function useMenu(media: Media) {
  const inSheet = useContext(InSheetContext);
  return (e: RMouseEvent) => {
    e.preventDefault();
    ui.showMenu({ x: e.clientX, y: e.clientY, media, inSheet });
  };
}

/** Cover card: cover with age and match bubbles, title and community score. */
export function MediaCard({ media, width = 150, showsStatus = true, onClick }: { media: Media; width?: number; showsStatus?: boolean; onClick?: () => void }) {
  const model = useModel();
  const open = useOpenDetail();
  const onMenu = useMenu(media);
  const entry = model.entry(media.id);
  const match = model.matcher.match(media);
  return (
    <button className="card" style={{ width }} onClick={onClick ?? (() => open(media.id))} onContextMenu={onMenu}
      title={displayTitle(media, model.settings.titleLanguage)}>
      <div className="card-cover">
        <Cover url={coverURL(media)} color={media.coverImage?.color} width={width} height={Math.round(width * 1.45)} radius={12} />
        <div className="card-age"><AgeBadge media={media} /></div>
        {match !== undefined && <div className="card-match"><MatchBubble value={match} /></div>}
        {showsStatus && entry && <div className="card-status"><Icon name={statusIcon[entry.status]} size={15} strokeWidth={2.2} /></div>}
      </div>
      <div className="card-title">{displayTitle(media, model.settings.titleLanguage)}</div>
      <ScoreBadge score={media.averageScore} />
    </button>
  );
}

export function defaultSubtitle(m: Media) {
  const parts = [formatLabel(m)];
  if (m.episodes) parts.push(`${m.episodes} eps`);
  const s = seasonLabel(m);
  if (s) parts.push(s);
  return parts.join(" · ");
}

/** List row: thumbnail, title, subtitle, score, match and age. */
export function MediaRow({ media, subtitle, onClick, trailing }: { media: Media; subtitle?: string; onClick?: () => void; trailing?: ReactNode }) {
  const model = useModel();
  const open = useOpenDetail();
  const onMenu = useMenu(media);
  const match = model.matcher.match(media);
  return (
    <button className="row" onClick={onClick ?? (() => open(media.id))} onContextMenu={onMenu}>
      <Cover url={thumbURL(media)} color={media.coverImage?.color} width={58} height={84} radius={8} />
      <div className="row-text">
        <div className="row-title">{displayTitle(media, model.settings.titleLanguage)}</div>
        <div className="row-sub">{subtitle ?? defaultSubtitle(media)}</div>
        <div className="row-badges">
          <ScoreBadge score={media.averageScore} />
          {match !== undefined && <span className="row-match"><Icon name="wand" size={14} /><MatchBubble value={match} /></span>}
          <AgeBadge media={media} />
        </div>
      </div>
      {trailing}
      <Icon name="chevronRight" size={16} className="row-chevron" />
    </button>
  );
}

/** A horizontal shelf of cards with arrow buttons (and the mouse wheel) to move along it. */
export function Shelf({ title, action, children, icon }: { title: ReactNode; action?: { label: string; run: () => void }; children: ReactNode; icon?: string }) {
  const scroller = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState({ start: true, end: false });
  const update = () => {
    const el = scroller.current;
    if (!el) return;
    const start = el.scrollLeft < 4;
    const end = el.scrollLeft + el.clientWidth >= el.scrollWidth - 4;
    // Only a real change re-renders (a new object every time would loop forever).
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

export function Spinner({ label }: { label?: string }) {
  return (
    <div className="spinner-wrap">
      <span className="spinner" />
      {label && <span className="muted">{label}</span>}
    </div>
  );
}

export function Empty({ icon, title, text }: { icon: string; title: string; text?: string }) {
  return (
    <div className="empty">
      <Icon name={icon} size={40} strokeWidth={1.4} />
      <h3>{title}</h3>
      {text && <p>{text}</p>}
    </div>
  );
}

/** A glass dropdown button with a menu (Categories, Lists' status, Seasons, sort). */
export function Dropdown<T>({ label, icon, items, onPick, align = "right", compact }: {
  label: ReactNode; icon?: string; compact?: boolean;
  items: ({ value: T; label: string; detail?: string; icon?: string; selected?: boolean } | { section: string } | "divider")[];
  onPick: (v: T) => void; align?: "left" | "right";
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", esc);
    return () => { window.removeEventListener("mousedown", close); window.removeEventListener("keydown", esc); };
  }, [open]);
  return (
    <div className="dropdown" ref={ref}>
      <button className={`glass-button dropdown-button ${compact ? "icon-only" : ""}`} onClick={() => setOpen(!open)} aria-expanded={open}>
        {icon && <Icon name={icon} size={17} />}
        {label}
        {!compact && <Icon name="chevronDown" size={14} strokeWidth={2.4} />}
      </button>
      {open && (
        <div className={`menu dropdown-menu ${align}`}>
          {items.map((item, i) => {
            if (item === "divider") return <div key={i} className="menu-divider" />;
            if ("section" in item) return <div key={i} className="menu-section">{item.section}</div>;
            return (
              <button key={i} className="menu-item" onClick={() => { setOpen(false); onPick(item.value); }}>
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

export function Modal({ title, onClose, children, width = 560, actions }: { title: ReactNode; onClose: () => void; children: ReactNode; width?: number; actions?: ReactNode }) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);
  return (
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal" style={{ width }} role="dialog" aria-modal="true">
        <header className="modal-head">
          <button className="glass-button" onClick={onClose}>Close</button>
          <h2>{title}</h2>
          <div className="modal-actions">{actions}</div>
        </header>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}

export function SearchField({ value, onChange, placeholder, autoFocus }: { value: string; onChange: (v: string) => void; placeholder: string; autoFocus?: boolean }) {
  return (
    <label className="search-field">
      <Icon name="search" size={17} />
      <input value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} autoFocus={autoFocus} spellCheck={false} />
      {value && <button className="search-clear" onClick={() => onChange("")} aria-label="Clear"><Icon name="x" size={14} /></button>}
    </label>
  );
}

export function PageHeader({ title, children, back }: { title: ReactNode; children?: ReactNode; back?: () => void }) {
  return (
    <header className="page-head">
      {back && <button className="round-button back" onClick={back} aria-label="Back"><Icon name="chevronLeft" size={18} /></button>}
      <h1>{title}</h1>
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
    const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) onVisible(); }, { rootMargin: "400px" });
    io.observe(el);
    return () => io.disconnect();
  }, [onVisible, active]);
  return <div ref={ref} className="load-more" />;
}
