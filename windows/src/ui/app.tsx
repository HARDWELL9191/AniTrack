// App shell: sidebar with the five tabs (the iPhone's tab bar), a page stack per tab, sheets,
// the right-click menu and the error alert.

import { useEffect, useState } from "react";
import { type AppTab } from "../core/model";
import appIcon from "../assets/app-icon.png";
import { DetailPage } from "./detail";
import { CategoryPage, DiscoverPage } from "./discover";
import { ForYouPage } from "./foryou";
import { HomePage } from "./home";
import { Icon } from "./icons";
import { ListsPage } from "./lists";
import { ShowMenu } from "./menu";
import { ProfilePage } from "./profile";
import { Sheets } from "./sheets";
import { ui, useModel, useUI } from "./state";
import { WelcomePage } from "./welcome";
import { Modal, Spinner } from "./components";

const TABS: { id: AppTab; label: string; icon: string }[] = [
  { id: "home", label: "Home", icon: "home" },
  { id: "forYou", label: "For You", icon: "wand" },
  { id: "discover", label: "Discover", icon: "search" },
  { id: "lists", label: "Lists", icon: "list" },
  { id: "profile", label: "Profile", icon: "user" },
];

export function App() {
  const model = useModel();
  const state = useUI();
  const [refresh, setRefresh] = useState<Record<AppTab, number>>({ home: 0, forYou: 0, discover: 0, lists: 0, profile: 0 });

  useEffect(() => { void model.loadCategories(); }, [model]);

  // F5 / Ctrl+R: the iPhone's pull to refresh, for the page you're on. Alt+← goes back.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "F5" || ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "r")) {
        e.preventDefault();
        const tab = model.selectedTab;
        if (tab === "home") void model.reloadAll();
        setRefresh((r) => ({ ...r, [tab]: r[tab] + 1 }));
      } else if ((e.altKey && e.key === "ArrowLeft") || e.key === "BrowserBack") {
        if (ui.stacks[model.selectedTab].length) ui.pop(model.selectedTab);
      }
    };
    const onMouse = (e: MouseEvent) => {
      if (e.button === 3 && ui.stacks[model.selectedTab].length && !ui.sheets.length) ui.pop(model.selectedTab);
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("mouseup", onMouse);
    return () => { window.removeEventListener("keydown", onKey); window.removeEventListener("mouseup", onMouse); };
  }, [model]);

  if (!model.didBootstrap) return <div className="boot"><Spinner /></div>;
  if (model.mode.kind === "none") return (<><WelcomePage /><ErrorAlert /></>);

  const select = (tab: AppTab) => {
    // Clicking the tab you're on goes back to its first page (like the iPhone).
    if (tab === model.selectedTab) ui.popToRoot(tab);
    model.selectedTab = tab;
    model.notify();
  };

  return (
    <div className="shell">
      <nav className="sidebar">
        <div className="brand"><img src={appIcon} alt="" /> AniReco</div>
        {TABS.map((t) => (
          <button key={t.id} className={`nav-item ${model.selectedTab === t.id ? "on" : ""}`} onClick={() => select(t.id)}>
            <Icon name={t.icon} size={20} /> {t.label}
          </button>
        ))}
        <div className="sidebar-foot">
          {model.viewer?.avatar?.large && <img src={model.viewer.avatar.large} alt="" />}
          <span>{model.viewer?.name}</span>
        </div>
      </nav>
      <main className="content">
        {TABS.map((t) => {
          const stack = state.stacks[t.id];
          const top = stack[stack.length - 1];
          return (
            <div key={t.id} className="tab" hidden={model.selectedTab !== t.id}>
              {/* The tab's first page stays mounted under pushed pages, keeping its scroll position. */}
              <div className="scroll" hidden={!!top}>
                {t.id === "home" && <HomePage refreshKey={refresh.home} />}
                {t.id === "forYou" && <ForYouPage refreshKey={refresh.forYou} />}
                {t.id === "discover" && <DiscoverPage refreshKey={refresh.discover} />}
                {t.id === "lists" && <ListsPage refreshKey={refresh.lists} />}
                {t.id === "profile" && <ProfilePage />}
              </div>
              {top && (
                <div className="scroll" key={stack.length}>
                  {top.kind === "detail" ? (
                    <div className="page wide">
                      <button className="glass-button back-float" onClick={() => ui.pop(t.id)}><Icon name="chevronLeft" size={16} /> Back</button>
                      <DetailPage id={top.id} />
                    </div>
                  ) : (
                    <CategoryPage category={top.category} back={() => ui.pop(t.id)} />
                  )}
                </div>
              )}
            </div>
          );
        })}
      </main>
      <Sheets />
      <ShowMenu />
      <ErrorAlert />
    </div>
  );
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
