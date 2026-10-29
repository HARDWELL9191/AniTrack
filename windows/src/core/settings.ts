// User preferences (port of AppSettings.swift), saved like UserDefaults.

import { Defaults } from "./cache";
import { TitleLanguage } from "./models";

export class AppSettings {
  onChange: () => void = () => {};

  private _titleLanguage: TitleLanguage = Defaults.get<TitleLanguage>("titleLanguage", "english");
  private _hideChinese: boolean = Defaults.get("hideChinese", true);
  private _includeUnreleased: boolean = Defaults.get("includeUnreleased", false);
  private _clientId: string = Defaults.get("clientId", "");
  private _dismissed = new Set<number>(Defaults.get<number[]>("dismissedPicks", []));
  private _useAI: boolean = Defaults.get("useOnDeviceAI", true);

  get titleLanguage() { return this._titleLanguage; }
  set titleLanguage(v: TitleLanguage) { this._titleLanguage = v; Defaults.set("titleLanguage", v); this.onChange(); }

  get hideChinese() { return this._hideChinese; }
  set hideChinese(v: boolean) { this._hideChinese = v; Defaults.set("hideChinese", v); this.onChange(); }

  get includeUnreleased() { return this._includeUnreleased; }
  set includeUnreleased(v: boolean) { this._includeUnreleased = v; Defaults.set("includeUnreleased", v); this.onChange(); }

  get clientId() { return this._clientId; }
  set clientId(v: string) { this._clientId = v; Defaults.set("clientId", v); this.onChange(); }

  get useOnDeviceAI() { return this._useAI; }
  set useOnDeviceAI(v: boolean) { this._useAI = v; Defaults.set("useOnDeviceAI", v); this.onChange(); }

  /** "Not for me" shows (a copy; change it through the setters below). */
  get dismissedPicks(): ReadonlySet<number> { return this._dismissed; }
  setDismissed(ids: Iterable<number>) {
    this._dismissed = new Set(ids);
    Defaults.set("dismissedPicks", [...this._dismissed]);
    this.onChange();
  }
  addDismissed(id: number) { this.setDismissed([...this._dismissed, id]); }
  removeDismissed(id: number) { const s = new Set(this._dismissed); s.delete(id); this.setDismissed(s); }
}
