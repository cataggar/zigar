import CjsSocket = require("./m3-objects-cjs.cjs");
import DefaultSession from "./m3-objects-def.mjs";

// 1. Plain Data / Options Interfaces (Zig structs with `= null` defaults & cyclic self-pointers)
export interface BaseOptions {
  readonly host?: string;
  keepAlive?: boolean;
}

export interface ExtraOptions {
  retries?: number;
  headers?: string[];
}

export interface RequestOptions extends BaseOptions, ExtraOptions {
  host: string;
  port?: number;
}

export interface LinkedNode {
  id: string;
  value: number;
  next?: LinkedNode;
}

export function describeRequestOptions(
  opts: RequestOptions,
  note: { label: string; reason: string | null },
): string;
export function makeDefaultOptions(): RequestOptions;
export function sumLinkedNodes(head: LinkedNode): string;

// 2. Abstract Base Class + Derived Class + Divergent/Write-Only/Readonly/Nominal Accessors + Static Members
export declare abstract class BaseTransport {
  static readonly SPEC_VERSION = 2;
  readonly protocol: string;
  constructor(protocol: string);
  static supportedCount(): number;
  ping(): boolean;
}

export declare class HttpClient extends BaseTransport {
  readonly baseUrl: string;
  timeout: number;
  mode: "fast" | "slow";
  get endpoint(): string;
  set endpoint(val: string | number);
  set authToken(token: string);
  static defaultPort: number;
  static readonly version: string;
  static set logSink(sink: string);
  static get env(): string;
  static set env(val: string | null);
  constructor(baseUrl: string);
  constructor(baseUrl: string, timeout: number);
  static createDefault(): HttpClient;
  request(path: string, opts?: RequestOptions): string;
}

export function upcastTransport(client: HttpClient): BaseTransport;
export function produceImpostorTransport(): BaseTransport;
export function verifyClientAndState(client: HttpClient): string;

// 3. Companion `interface` + Constructable `declare var` + Default & CJS Class Verification
export interface CustomUrl {
  href: string;
  readonly origin: string;
  toJSON(): string;
}

export interface CustomUrlConstructor {
  prototype: CustomUrl;
  new(input: string, base?: string): CustomUrl;
  canParse(input: string, base?: string): boolean;
  readonly schemeVersion: number;
}

export declare var CustomUrl: CustomUrlConstructor;

export function produceImpostorCustomUrl(): CustomUrl;
export function produceImpostorSocket(): CjsSocket;
export function verifySocketAndSession(sock: CjsSocket, sess: DefaultSession): string;

// 4. Stateful Duck-Typed Interfaces (Zero-Side-Effect `Reflect.has` Validation) & Callable/Constructable Interfaces
export interface StatefulCursor {
  readonly position: number;
  next(): string | null;
  reset(): void;
}

export interface LiveCounter {
  get count(): number;
  set count(v: number | string);
}

export interface CallableFactory {
  (prefix: string): string;
  new(baseUrl: string): HttpClient;
  readonly tag: string;
}

export function makeCursor(items: string[]): StatefulCursor;
export function cursorPositionGetterReads(): number;
export function produceBadCursor(mode: number): StatefulCursor;

export function makeLiveCounter(initial: number): LiveCounter;
export function readLastCounterValue(): number;
export function produceArrayAsCounter(): LiveCounter;

export function getCallableFactory(): CallableFactory;
export function produceBadCallableFactory(): CallableFactory;

// 5. Same-Named Factory Functions (`interface X` + `function X`) & Generic `extends` Instantiation
export interface Widget {
  readonly id: number;
  render(): string;
}
export function Widget(name: string): Widget;

export interface FactoryConfig {
  host: string;
  port?: number;
}
export function FactoryConfig(host: string): FactoryConfig;
export function formatFactoryConfig(cfg: FactoryConfig): string;

export interface Box<T, M = string> {
  value: T;
  meta?: M;
}
export interface StrBox extends Box<string> {
  extra: number;
}
export function echoStrBox(box: StrBox): StrBox;

export interface BaseEmitter<E, R = boolean> {
  emit(event: E): R;
  readonly topic: E;
}
export interface MidEmitter<X> extends BaseEmitter<X, number> {}
export interface Svc extends MidEmitter<string> {
  port: number;
}
export function makeSvc(topic: string, port: number): Svc;
export function produceBadSvc(): Svc;

export declare class StoreBase<T> {
  getCurrent(): T;
  setCurrent(val: T): void;
}
export declare class NumberStore extends StoreBase<number> {
  constructor(initial: number);
  step(): number;
}

