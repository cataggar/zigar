declare namespace cjsGenerics {
  export interface Box<T = number> {
    value: T;
    revision: number;
  }

  export function makeBox<T = number>(value: T, revision?: number): Box<T>;
  export function pluckKey<T, K extends keyof T>(target: T, key: K): T[K];
}

export = cjsGenerics;
