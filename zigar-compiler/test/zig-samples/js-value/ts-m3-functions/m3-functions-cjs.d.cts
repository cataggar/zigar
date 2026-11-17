declare function callableToolkit(text: string): string;
declare function callableToolkit(a: number, b: number): number;

declare namespace callableToolkit {
  export function joinParts(sep: string, ...parts: string[]): string;
}

export = callableToolkit;
