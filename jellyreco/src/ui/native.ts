// Small bridges to the native side that only some screens need.

import { invoke } from "@tauri-apps/api/core";

/** A local file (picked in an Open dialog) as base64, e.g. an image to upload. */
export function readFile(path: string): Promise<string> {
  return invoke<string>("read_file_base64", { path });
}

/** Saves text to a path picked in a Save dialog. */
export function writeTextFile(path: string, contents: string): Promise<void> {
  return invoke("write_text_file", { path, contents });
}
