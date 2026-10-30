// Simple line icons (drawn for AniReco), 24×24 grid, current color.

import type { JSX } from "react";

const paths: Record<string, JSX.Element> = {
  home: <path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z" />,
  wand: <><path d="m4 20 11-11" /><path d="m13 7 2 2" /><path d="M17 3v3M15.5 4.5h3M20 9v2M19 10h2M10 3v2M9 4h2" /></>,
  search: <><circle cx="11" cy="11" r="7" /><path d="m20 20-3.5-3.5" /></>,
  list: <><rect x="4" y="3" width="16" height="18" rx="2" /><path d="M8 8h8M8 12h8M8 16h5" /></>,
  user: <><circle cx="12" cy="8" r="4" /><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6" /></>,
  bookmark: <path d="M6 3h12v18l-6-4.5L6 21z" />,
  check: <path d="m5 12.5 4.5 4.5L19 7" />,
  checkCircle: <><circle cx="12" cy="12" r="9" /><path d="m8 12.5 3 3 5-6" /></>,
  play: <><circle cx="12" cy="12" r="9" /><path d="m10 8.5 5.5 3.5-5.5 3.5z" /></>,
  pause: <><circle cx="12" cy="12" r="9" /><path d="M10 9v6M14 9v6" /></>,
  x: <path d="M6 6l12 12M18 6 6 18" />,
  xCircle: <><circle cx="12" cy="12" r="9" /><path d="m9 9 6 6M15 9l-6 6" /></>,
  repeat: <><path d="M4 12a8 8 0 0 1 13.7-5.6L20 9" /><path d="M20 4v5h-5" /><path d="M20 12a8 8 0 0 1-13.7 5.6L4 15" /><path d="M4 20v-5h5" /></>,
  chevronDown: <path d="m6 9 6 6 6-6" />,
  chevronLeft: <path d="m15 5-7 7 7 7" />,
  chevronRight: <path d="m9 5 7 7-7 7" />,
  plus: <><circle cx="12" cy="12" r="9" /><path d="M12 8v8M8 12h8" /></>,
  info: <><circle cx="12" cy="12" r="9" /><path d="M12 11v6M12 7.5v.5" /></>,
  thumbsDown: <><path d="M7 14V4H4v10z" /><path d="M7 14l4 7c1.5 0 2.5-1 2.3-2.5L13 15h5.5a2 2 0 0 0 2-2.3l-1.2-7A2 2 0 0 0 17.3 4H7" /></>,
  eye: <><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z" /><circle cx="12" cy="12" r="3" /></>,
  layers: <><path d="m12 3 9 5-9 5-9-5z" /><path d="m3 13 9 5 9-5" /></>,
  shuffle: <><path d="M3 7h4c4 0 6 10 10 10h4" /><path d="M3 17h4c1.6 0 2.8-1.6 3.8-3.5M14 9.5C15 8 16 7 17 7h4" /><path d="m18 4 3 3-3 3M18 14l3 3-3 3" /></>,
  heart: <path d="M12 20s-7.5-4.6-9-9.5C2 6.9 4.3 4 7.4 4c2 0 3.6 1.1 4.6 2.8C13 5.1 14.6 4 16.6 4 19.7 4 22 6.9 21 10.5 19.5 15.4 12 20 12 20z" />,
  clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  shield: <><path d="M12 3 5 6v5c0 4.5 3 8.5 7 10 4-1.5 7-5.5 7-10V6z" /><path d="m9 12 2 2 4-4" /></>,
  external: <><path d="M14 4h6v6" /><path d="M20 4 11 13" /><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5" /></>,
  trash: <><path d="M4 7h16M10 11v6M14 11v6" /><path d="M6 7l1 13h10l1-13M9 7V4h6v3" /></>,
  download: <><path d="M12 4v11M7 10l5 5 5-5" /><path d="M5 20h14" /></>,
  undo: <><path d="M9 14 4 9l5-5" /><path d="M4 9h11a5 5 0 0 1 0 10h-3" /></>,
  sort: <><path d="M7 4v16M7 20l-3-3M7 20l3-3" /><path d="M17 20V4M17 4l-3 3M17 4l3 3" /></>,
  refresh: <><path d="M20 12a8 8 0 1 1-2.3-5.7L20 8.5" /><path d="M20 3.5v5h-5" /></>,
  filter: <path d="M4 6h16M7 12h10M10 18h4" />,
  flame: <path d="M12 21c-4 0-7-2.8-7-6.5 0-3.3 2.5-5.4 4-8 .8 1.6 1.8 2.6 3 3 0-2.5 1-5 3-6.5.3 3 4 5.6 4 10C19 17.5 16 21 12 21z" />,
  sparkles: <><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z" /><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z" /></>,
  diamond: <><path d="M6 3h12l4 6-10 12L2 9z" /><path d="M2 9h20M12 21 8 9l2-6M12 21l4-12-2-6" /></>,
  compass: <><circle cx="12" cy="12" r="9" /><path d="m15.5 8.5-2 5-5 2 2-5z" /></>,
  dice: <><rect x="4" y="4" width="16" height="16" rx="3" /><circle cx="9" cy="9" r="1" /><circle cx="15" cy="15" r="1" /><circle cx="15" cy="9" r="1" /><circle cx="9" cy="15" r="1" /><circle cx="12" cy="12" r="1" /></>,
  table: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 10h18M3 15h18M9 4v16" /></>,
  logout: <><path d="M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4" /><path d="M10 17l-5-5 5-5M5 12h11" /></>,
  key: <><circle cx="8" cy="15" r="4" /><path d="m11 12 9-9M17 6l3 3M15 8l2 2" /></>,
  chip: <><rect x="6" y="6" width="12" height="12" rx="2" /><rect x="9.5" y="9.5" width="5" height="5" rx="1" /><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3" /></>,
  tag: <><path d="M3 12V4h8l10 10-8 8z" /><circle cx="7.5" cy="8.5" r="1.3" /></>,
  grid: <><rect x="4" y="4" width="7" height="7" rx="1.5" /><rect x="13" y="4" width="7" height="7" rx="1.5" /><rect x="4" y="13" width="7" height="7" rx="1.5" /><rect x="13" y="13" width="7" height="7" rx="1.5" /></>,
  star: <path d="m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z" />,
  smileHappy: <><circle cx="12" cy="12" r="9" fill="currentColor" stroke="none" /><path d="M8 14c1 1.7 2.4 2.5 4 2.5s3-.8 4-2.5" stroke="var(--icon-cut, #0b0d12)" /><circle cx="9" cy="10" r="1.1" fill="var(--icon-cut, #0b0d12)" stroke="none" /><circle cx="15" cy="10" r="1.1" fill="var(--icon-cut, #0b0d12)" stroke="none" /></>,
  smile: <><circle cx="12" cy="12" r="9" /><path d="M8.5 14.5c1 1.3 2.1 2 3.5 2s2.5-.7 3.5-2" /><circle cx="9" cy="10" r=".6" fill="currentColor" /><circle cx="15" cy="10" r=".6" fill="currentColor" /></>,
  smileDashed: <><circle cx="12" cy="12" r="9" strokeDasharray="3 2.4" /><path d="M9 15.5h6" /><circle cx="9" cy="10" r=".6" fill="currentColor" /><circle cx="15" cy="10" r=".6" fill="currentColor" /></>,
  menu: <><circle cx="5" cy="12" r="1.4" fill="currentColor" /><circle cx="12" cy="12" r="1.4" fill="currentColor" /><circle cx="19" cy="12" r="1.4" fill="currentColor" /></>,
};

export type IconName = keyof typeof paths;

export function Icon({ name, size = 18, className, strokeWidth = 1.9 }: { name: IconName | string; size?: number; className?: string; strokeWidth?: number }) {
  return (
    <svg className={className} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {paths[name] ?? null}
    </svg>
  );
}
