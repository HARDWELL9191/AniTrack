// App shell: sidebar (Home, For You, Search, Favorites, your libraries, Settings, Dashboard), a page
// stack per tab, sheets, the right-click menu, toasts, and the player on top of everything.

import { Component, type ReactNode, useEffect, useState } from "react";
import type { Tab } from "../core/model";
import appIcon from "../assets/app-icon.png";
import { DashboardRoot, DashboardPage } from "./dashboard";
import { DetailPage } from "./detail";
import { FavoritesPage } from "./favorites";
import { ForYouPage } from "./foryou";
import { HomePage } from "./home";
import { Icon } from "./icons";
import { BrowsePage, GenrePage, LibraryPage, LiveGuidePage, PersonPage, StudioPage } from "./library";
import { ItemMenu } from "./menu";
import { MiniPlayer, PlayerOverlay, usePlayer } from "./player";
import { SearchPage } from "./search";
import { SettingsPage } from "./settings";
import { Sheets } from "./sheets";
import { type Route, ui, useModel, useUI } from "./state";
import { WelcomePage } from "./welcome";
import { listCounts, MyListPage, NotForMePage } from "./lists";
import { Cover, Modal, Spinner } from "./components";

const MAIN_TABS: { id: Tab; label: string; icon: string }[] = [
  { id: "home", label: "Home", icon: "home" },
  { id: "forYou", label: "For You", icon: "wand" },
  { id: "search", label: "Search", icon: "search" },
  { id: "favorites", label: "Favorites", icon: "heart" },
];

export const viewIcon = (collectionType?: string | null) => {
  switch (collectionType) {
    case "movies": return "film";
    case "tvshows": return "tv";
    case "music": return "music";
    case "musicvideos": return "music";
    case "homevideos":
    case "photos": return "photo";
    case "books": return "book";
    case "livetv": return "live";
    case "playlists": return "playlist";
    case "boxsets": return "collection";
    default: return "folder";
  }
};

export function App() {
  const model = useModel();
  const state = useUI();
  const player = usePlayer();
  const [refresh, setRefresh] = useState(0);

  // F5 / Ctrl+R refreshes the page you're on. Alt+← and the mouse back button go back.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (player.active && !player.isAudio) return;
      if (e.key === "F5" || ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "r")) {
        e.preventDefault();
        setRefresh((r) => r + 1);
        model.dataChanged();
      } else if ((e.altKey && e.key === "ArrowLeft") || e.key === "BrowserBack") {
        if (ui.stacks[model.tab].length) ui.pop(model.tab);
      } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f") {
        e.preventDefault();
        select("search");
      }
    };
    const onMouse = (e: MouseEvent) => {
      if (e.button === 3 && ui.stacks[model.tab].length && !ui.sheets.length && !player.active) ui.pop(model.tab);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("mouseup", onMouse);
    return () => { window.removeEventListener("keydown", onKey); window.removeEventListener("mouseup", onMouse); };
  }); // eslint-disable-line react-hooks/exhaustive-deps

  if (!model.didBootstrap) return <div className="boot"><Spinner /></div>;
  // A video file opened with the app plays even before signing in.
  if (!model.signedIn) return (<>{!player.active && <WelcomePage />}{player.active && <Guard><PlayerOverlay /></Guard>}<ErrorAlert /><Toasts /></>);

  function select(tab: Tab, libraryId: string | null = null) {
    if (tab === model.tab && libraryId === model.libraryId) ui.popToRoot(tab);
    else if (tab === "library" && libraryId !== model.libraryId) ui.popToRoot("library");
    model.tab = tab;
    model.libraryId = libraryId;
    model.notify();
  }

  const videoOn = player.active && !player.isAudio;
  const counts = listCounts(model);
  const user = model.user!;
  const library = model.views.find((v) => v.Id === model.libraryId);
  const tabs: Tab[] = ["home", "forYou", "search", "favorites", "library", "myList", "notForMe", "settings", ...(model.isAdmin ? ["dashboard" as Tab] : [])];

  return (
    <>
      <div className={`shell ${videoOn ? "behind-video" : ""}`} aria-hidden={videoOn}>
        <nav className="sidebar">
          <div className="brand"><img src={appIcon} alt="" /> JellyReco</div>
          {MAIN_TABS.map((t) => (
            <button key={t.id} className={`nav-item ${model.tab === t.id ? "on" : ""}`} onClick={() => select(t.id)}>
              <Icon name={t.icon} size={20} /> {t.label}
            </button>
          ))}
          <div className="nav-section">Libraries</div>
          <div className="nav-libraries">
            {model.views.map((v) => (
              <button key={v.Id} className={`nav-item ${model.tab === "library" && model.libraryId === v.Id ? "on" : ""}`} onClick={() => select("library", v.Id)}
                onContextMenu={(e) => { e.preventDefault(); ui.showMenu({ x: e.clientX, y: e.clientY, item: v }); }}>
                <Icon name={viewIcon(v.CollectionType)} size={20} /> <span className="nav-label">{v.Name}</span>
              </button>
            ))}
            {/* Your For You lists, as on the iPhone's Library tab (saved on the server). */}
            <button className={`nav-item ${model.tab === "myList" ? "on" : ""}`} onClick={() => select("myList")}>
              <Icon name="bookmark" size={20} /> <span className="nav-label">My List</span>{counts.myList > 0 && <span className="nav-count">{counts.myList}</span>}
            </button>
            <button className={`nav-item ${model.tab === "notForMe" ? "on" : ""}`} onClick={() => select("notForMe")}>
              <Icon name="thumbsDown" size={20} /> <span className="nav-label">Not for me</span>{counts.notForMe > 0 && <span className="nav-count">{counts.notForMe}</span>}
            </button>
          </div>
          <div className="nav-bottom">
            <button className={`nav-item ${model.tab === "settings" ? "on" : ""}`} onClick={() => select("settings")}><Icon name="settings" size={20} /> Settings</button>
            {model.isAdmin && <button className={`nav-item ${model.tab === "dashboard" ? "on" : ""}`} onClick={() => select("dashboard")}><Icon name="dashboard" size={20} /> Dashboard</button>}
            <button className="sidebar-foot" onClick={() => select("settings")} title={`${user.Name} on ${model.server?.name}`}>
              <Cover url={user.PrimaryImageTag ? model.api!.userImage(user.Id, user.PrimaryImageTag, 64) : undefined} width={30} height={30} radius={15} icon="user" />
              <span className="foot-text"><strong>{user.Name}</strong><small>{model.server?.name}</small></span>
            </button>
          </div>
        </nav>
        <main className="content">
          {tabs.map((t) => {
            const stack = state.stacks[t];
            const top = stack[stack.length - 1];
            return (
              <div key={t} className="tab" hidden={model.tab !== t}>
                {/* The tab's first page stays mounted under pushed pages, keeping its scroll position. */}
                <div className="scroll" hidden={!!top}>
                  <Guard>
                  {t === "home" && <HomePage refreshKey={refresh} />}
                  {t === "forYou" && <ForYouPage refreshKey={refresh} />}
                  {t === "search" && <SearchPage />}
                  {t === "favorites" && <FavoritesPage refreshKey={refresh} />}
                  {t === "library" && library && <LibraryPage key={library.Id} view={library} refreshKey={refresh} />}
                  {t === "myList" && <MyListPage />}
                  {t === "notForMe" && <NotForMePage />}
                  {t === "settings" && <SettingsPage />}
                  {t === "dashboard" && model.isAdmin && <DashboardRoot />}
                  </Guard>
                </div>
                {top && (
                  <div className="scroll" key={`${stack.length}-${routeKey(top)}`}>
                    <Guard><RoutePage route={top} back={() => ui.pop(t)} refreshKey={refresh} /></Guard>
                  </div>
                )}
              </div>
            );
          })}
          {player.active && player.isAudio && <MiniPlayer />}
        </main>
      </div>
      {player.active && <Guard><PlayerOverlay /></Guard>}
      <Sheets />
      <ItemMenu />
      <ErrorAlert />
      <Toasts />
    </>
  );
}

function routeKey(r: Route): string {
  switch (r.kind) {
    case "item":
    case "person":
    case "library": return r.id;
    case "genre":
    case "studio": return r.name;
    case "browse": return r.title;
    case "dashboard": return r.page + (r.arg ?? "");
    default: return r.kind;
  }
}

function RoutePage({ route, back, refreshKey }: { route: Route; back: () => void; refreshKey: number }) {
  switch (route.kind) {
    case "item": return <DetailPage id={route.id} hint={route.hint} back={back} refreshKey={refreshKey} />;
    case "library": return <LibraryPage view={{ Id: route.id, Name: route.name, CollectionType: route.collectionType, Type: "CollectionFolder" }} back={back} refreshKey={refreshKey} />;
    case "browse": return <BrowsePage title={route.title} query={route.query} back={back} />;
    case "person": return <PersonPage id={route.id} back={back} />;
    case "genre": return <GenrePage name={route.name} id={route.id} parentId={route.parentId} types={route.types} back={back} />;
    case "studio": return <StudioPage name={route.name} id={route.id} back={back} />;
    case "dashboard": return <DashboardPage page={route.page} arg={route.arg} back={back} />;
    case "liveGuide": return <LiveGuidePage back={back} />;
    case "myList": return <MyListPage back={back} />;
    case "notForMe": return <NotForMePage back={back} />;
  }
}

function ErrorAlert() {
  const model = useModel();
  if (!model.errorMessage) return null;
  const close = () => { model.errorMessage = null; model.notify(); };
  return (
    <Modal title="Something went wrong" onClose={close} width={440}>
      <p>{model.errorMessage}</p>
      <div className="center"><button className="glass-button prominent" onClick={close}>OK</button></div>
    </Modal>
  );
}

function Toasts() {
  const model = useModel();
  if (!model.toasts.length) return null;
  return (
    <div className="toasts" role="status">
      {model.toasts.map((t) => (
        <div key={t.id} className={`toast toast-${t.tone ?? "info"}`}>
          <Icon name={t.tone === "error" ? "info" : t.tone === "success" ? "checkCircle" : "bell"} size={16} />
          <span>{t.text}</span>
          {t.action && <button className="link-button" onClick={() => { t.action!.run(); model.dismissToast(t.id); }}>{t.action.label}</button>}
          <button className="toast-close" onClick={() => model.dismissToast(t.id)} aria-label="Dismiss"><Icon name="x" size={13} /></button>
        </div>
      ))}
    </div>
  );
}

/** A screen that fails to draw shows what went wrong (with a retry) instead of blanking the app. */
class Guard extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(error: Error) { console.error("Screen failed:", error); }
  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="page"><div className="empty">
        <Icon name="info" size={40} strokeWidth={1.4} />
        <h3>This screen couldn't be shown</h3>
        <p>{this.state.error.message}</p>
        <button className="glass-button" onClick={() => this.setState({ error: null })}>Try again</button>
      </div></div>
    );
  }
}
