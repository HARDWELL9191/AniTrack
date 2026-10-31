// A drop-down list drawn by the app (Liquid Glass menu), used everywhere instead of <select>:
// WebKitGTK on Linux draws <select> as a GTK menu in the desktop's theme, and WebView2 as a plain
// Windows list, neither of which matches the rest of the app. Written like <select>: <option>
// children (inside fragments or arrays too), value, onChange(e) with e.target.value.

import { Children, type CSSProperties, Fragment, isValidElement, type KeyboardEvent, type ReactElement, type ReactNode, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Icon } from "./icons";

interface Opt { value: string; label: ReactNode; text: string; disabled: boolean }

function textOf(n: ReactNode): string {
  if (n === null || n === undefined || typeof n === "boolean") return "";
  if (typeof n === "string" || typeof n === "number") return String(n);
  if (Array.isArray(n)) return n.map(textOf).join("");
  if (isValidElement(n)) return textOf((n.props as { children?: ReactNode }).children);
  return "";
}

function collect(children: ReactNode, out: Opt[] = []): Opt[] {
  Children.forEach(children, (c) => {
    if (!isValidElement(c)) return;
    const el = c as ReactElement<{ value?: unknown; children?: ReactNode; disabled?: boolean }>;
    if (el.type === Fragment) collect(el.props.children, out);
    else if (el.type === "option") {
      const label = el.props.children;
      out.push({ value: el.props.value === undefined ? textOf(label) : String(el.props.value), label, text: textOf(label), disabled: !!el.props.disabled });
    }
  });
  return out;
}

export function Select({ value, onChange, children, disabled, className, style, title, "aria-label": ariaLabel }: {
  value: string | number | readonly string[] | undefined;
  onChange?: (e: { target: { value: string }; currentTarget: { value: string } }) => void;
  children?: ReactNode; disabled?: boolean; className?: string; style?: CSSProperties; title?: string; "aria-label"?: string;
}) {
  const opts = collect(children);
  const current = String(value ?? "");
  const selected = opts.findIndex((o) => o.value === current);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const [pos, setPos] = useState<{ left: number; top?: number; bottom?: number; width: number; maxHeight: number } | null>(null);
  const button = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const typed = useRef({ text: "", at: 0 });

  const place = () => {
    const r = button.current?.getBoundingClientRect();
    if (!r) return;
    const below = window.innerHeight - r.bottom - 12, above = r.top - 12;
    const want = Math.min(360, opts.length * 40 + 14);
    const width = Math.max(r.width, 180);
    const left = Math.min(r.left, window.innerWidth - width - 8);
    if (below >= want || below >= above) setPos({ left, top: r.bottom + 6, width, maxHeight: Math.max(120, below) });
    else setPos({ left, bottom: window.innerHeight - r.top + 6, width, maxHeight: Math.max(120, above) });
  };
  const show = () => { if (disabled || !opts.length) return; place(); setActive(Math.max(0, selected)); setOpen(true); };
  const hide = (focus = true) => { setOpen(false); if (focus) button.current?.focus(); };
  const pick = (i: number) => {
    const o = opts[i];
    if (!o || o.disabled) return;
    hide();
    if (o.value !== current) onChange?.({ target: { value: o.value }, currentTarget: { value: o.value } });
  };

  useLayoutEffect(() => { if (open) place(); }, [open]);
  useEffect(() => {
    if (!open) return;
    const away = (e: MouseEvent) => { if (!menu.current?.contains(e.target as Node) && !button.current?.contains(e.target as Node)) hide(false); };
    const move = (e: Event) => { if (!menu.current?.contains(e.target as Node)) hide(false); };
    window.addEventListener("mousedown", away, true);
    window.addEventListener("scroll", move, true);
    window.addEventListener("resize", move);
    return () => { window.removeEventListener("mousedown", away, true); window.removeEventListener("scroll", move, true); window.removeEventListener("resize", move); };
  }, [open]);
  useEffect(() => { if (open) menu.current?.querySelector<HTMLElement>(`[data-i="${active}"]`)?.scrollIntoView({ block: "nearest" }); }, [open, active]);

  const step = (from: number, d: number) => {
    for (let i = from + d; i >= 0 && i < opts.length; i += d) if (!opts[i].disabled) return i;
    return from;
  };
  const onKey = (e: KeyboardEvent) => {
    if (disabled) return;
    if (!open) {
      if (["ArrowDown", "ArrowUp", "Enter", " "].includes(e.key)) { e.preventDefault(); show(); }
      return;
    }
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); hide(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); setActive((a) => step(a, 1)); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => step(a, -1)); }
    else if (e.key === "Home") { e.preventDefault(); setActive(step(-1, 1)); }
    else if (e.key === "End") { e.preventDefault(); setActive(step(opts.length, -1)); }
    else if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(active); }
    else if (e.key === "Tab") hide(false);
    else if (e.key.length === 1) {
      // Type to jump, like a native list.
      const now = Date.now();
      typed.current = { text: (now - typed.current.at < 700 ? typed.current.text : "") + e.key.toLowerCase(), at: now };
      const i = opts.findIndex((o) => !o.disabled && o.text.toLowerCase().startsWith(typed.current.text));
      if (i >= 0) setActive(i);
    }
  };

  return (
    <>
      <button ref={button} type="button" className={`select-button ${open ? "open" : ""} ${className ?? ""}`} style={style} disabled={disabled} title={title}
        aria-label={ariaLabel} aria-haspopup="listbox" aria-expanded={open}
        onClick={() => (open ? hide() : show())} onKeyDown={onKey}>
        <span className="select-value">{selected >= 0 ? opts[selected].label : <span className="muted">Choose…</span>}</span>
        <Icon name="chevronDown" size={14} strokeWidth={2.4} className="select-chevron" />
      </button>
      {open && pos && createPortal(
        <div ref={menu} className="menu select-menu" role="listbox" style={{ left: pos.left, top: pos.top, bottom: pos.bottom, minWidth: pos.width, maxHeight: pos.maxHeight }}
          onKeyDown={onKey} onMouseDown={(e) => e.preventDefault()}>
          {opts.map((o, i) => (
            <button key={`${o.value}-${i}`} type="button" data-i={i} role="option" aria-selected={i === selected} disabled={o.disabled}
              className={`menu-item ${i === active ? "active" : ""} ${i === selected ? "selected" : ""}`}
              onMouseEnter={() => setActive(i)} onClick={() => pick(i)}>
              <span className="menu-icon">{i === selected && <Icon name="check" size={15} strokeWidth={2.4} />}</span>
              <span className="menu-label">{o.label}</span>
            </button>
          ))}
        </div>,
        document.body,
      )}
    </>
  );
}
