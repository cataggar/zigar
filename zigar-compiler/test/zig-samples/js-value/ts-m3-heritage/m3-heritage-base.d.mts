export declare class EventEmitter {
  readonly listenerTotal: number;
  constructor();
  on(event: string): this;
  emit(event: string): boolean;
}

export interface EventEmitter {
  listenerCount(event: string): number;
}

export declare namespace EventEmitter {
  export const defaultMaxListeners: number;
  export function isEmitter(val: EventEmitter): boolean;
}

export declare class Stream extends EventEmitter {
  constructor();
  pipe(dest: string): string;
}
