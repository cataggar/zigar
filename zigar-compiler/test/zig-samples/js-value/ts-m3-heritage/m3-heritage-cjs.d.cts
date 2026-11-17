declare function $(selector: string): $.Selection;
declare function $(selector: string, root: string): $.Selection;

declare namespace $ {
  export interface Selection {
    readonly length: number;
    text(): string;
  }
  export let version: string;
  export function ajax(url: string): string;
}

export = $;
