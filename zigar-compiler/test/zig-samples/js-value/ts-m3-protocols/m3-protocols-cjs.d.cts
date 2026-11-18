declare namespace M3ProtocolsCjs {
  export function mulAsync(a: number, b: number): Promise<number>;
  export function joinIterable(parts: Iterable<string>, sep: string): string;
  export function asyncCountUp(n: number): AsyncIterable<number>;

  export class CjsResource implements Disposable {
    constructor(label: string);
    [Symbol.dispose](): void;
  }

  export function lastCjsDisposed(): string;
}

export = M3ProtocolsCjs;
