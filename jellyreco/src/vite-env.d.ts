/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Set by the JellyRec PC workflow: "1.0.<build number>". */
  readonly VITE_APP_VERSION?: string;
}
