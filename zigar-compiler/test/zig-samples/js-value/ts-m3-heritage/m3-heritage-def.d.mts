declare function defaultCreate(label: string): string;
declare function defaultCreate(label: string, count: number): string;

declare namespace defaultCreate {
  export let version: string;
  export function reset(): number;
}

export default defaultCreate;

