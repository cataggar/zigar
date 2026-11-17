import { EventEmitter, Stream } from "./m3-heritage-base.mjs";
import $ = require("./m3-heritage-cjs.cjs");
import defaultCreate from "./m3-heritage-def.mjs";

export { EventEmitter, Stream, $, defaultCreate };

// External module augmentation targeting `./m3-heritage-base.mjs`
declare module "./m3-heritage-base.mjs" {
  interface EventEmitter {
    augmentedTag(): string;
  }
  namespace EventEmitter {
    export let specRevision: number;
  }
}

// 1. Multi-level single class inheritance + multiple `implements` + upcast `.as` / `.clone` / downcast `.tryAs`
export interface WritableLike {
  write(chunk: string): boolean;
}

export interface Closable {
  readonly isClosed: boolean;
  close(): void;
}

export declare class Readable extends Stream {
  readonly readableHighWaterMark: number;
  constructor(hwm: number);
  read(size?: number): string | null;
}

export declare class Duplex extends Readable implements WritableLike, Closable {
  isClosed: boolean;
  constructor(hwm: number);
  write(chunk: string): boolean;
  close(): void;
  duplexSummary(): string;
}

export function inspectAsEmitter(ee: EventEmitter): string;
export function inspectAsStream(st: Stream): string;
export function inspectAsClosable(cl: Closable): string;
export function makeMysteryEmitter(kind: "duplex" | "readable" | "closable_emitter"): EventEmitter;
export function closableGetterSideEffects(): number;
export function resetClosableGetterSideEffects(): void;

// 2. Diamond multiple interface inheritance (distinct overloads, covariant narrowing, optionality tightening)
//    + value-struct `.as(Base)` projection (with inline nominal enum projection)
export interface BaseNode {
  readonly id: string;
  tag?: string;
  status: "idle" | "open" | "closed";
  ping(): number;
  query(key: string): string;
}

export interface LeftReader extends BaseNode {
  open(id: number): boolean;
}

export interface RightReader extends BaseNode {
  open(path: string): string;
  query(code: number): number;
}

export interface DiamondChannel extends LeftReader, RightReader {
  tag: string;
  status: "open";
}

export function makeDiamondChannel(id: string, tag: string): DiamondChannel;

export interface HostConfig {
  host: string;
  port?: number;
}

export interface TlsConfig {
  tls: boolean;
  alpn?: "h2" | "http/1.1";
}

export interface ServerConfig extends HostConfig, TlsConfig {
  workers?: number;
}

export type CombinedConfig = HostConfig & TlsConfig & {
  workers: number;
};

export function describeHostConfig(cfg: HostConfig): string;
export function describeTlsConfig(cfg: TlsConfig): string;
export function describeCombinedConfig(cfg: CombinedConfig): string;

// 3. Intersections: uninhabited `never` (`noreturn`), branded primitives, discriminated union distribution,
//    and stateful `A & B` handle intersections with recursive `.bases` runtime guard
export type EmptyResult = string & number;
export type UserId = string & { readonly __brand: "UserId" };
export type PortNum = number & { readonly __portBrand: unique symbol };

export type TaggedOutcome = (
  | { kind: "ok"; value: number }
  | { kind: "err"; message: string }
) & { requestId: string };

export type AdminSession = Readable & Closable & {
  readonly role: "admin" | "auditor";
  audit(action: string): string;
};

export function echoBrandPair(uid: UserId, port: PortNum): string;
export function formatTaggedOutcome(outcome: TaggedOutcome): string;
export function makeAdminSession(valid: boolean): AdminSession;

// 4. Index signatures: pure string dict (`HeaderBag.init()`), dual readonly numeric + RW string (`DualTable`),
//    template-literal key (`DataAttrMap`), closed enum key (`VerbTable`), inline nominal enum value (`InlineEnumDict`),
//    JS `symbol` key (`SymbolVault`), and collision-safe named `get`/`set`/`init` (`CollidingDict`)
export interface HeaderBag {
  [key: string]: string;
}

export interface DualTable {
  readonly [index: number]: string;
  [key: string]: string | number;
}

export type DataKey = `data-${string}`;

export interface DataAttrMap {
  [key: DataKey]: string;
}

export enum HttpVerb {
  Get = "GET",
  Post = "POST",
}

export interface VerbTable {
  [verb: HttpVerb]: number;
}

export interface InlineEnumDict {
  [key: string]: "on" | "off";
}

export interface SymbolVault {
  [sym: symbol]: string;
}

export interface CollidingDict {
  get(slot: number): boolean;
  set(slot: number, active: boolean): void;
  init(label: string): void;
  [key: string]: number;
}

export function summarizeHeaderBag(bag: HeaderBag): string;
export function makeDualTable(): DualTable;
export function makeDataAttrMap(): DataAttrMap;
export function makeVerbTable(): VerbTable;
export function makeInlineEnumDict(): InlineEnumDict;
export function makeSymbolVault(): SymbolVault;
export function makeVaultSymbol(label: string): symbol;
export function makeCollidingDict(): CollidingDict;
export function collidingDictLabel(dict: CollidingDict): string;

// 5. Declaration merging across all TS combinations
export interface MergedRegistry {
  readonly name: string;
  has(key: string): boolean;
}

export interface MergedRegistry {
  count: number;
  clear(): number;
  [key: string]: number;
}

export function makeMergedRegistry(name: string): MergedRegistry;

export declare class RichService {
  readonly endpoint: string;
  constructor(endpoint: string);
  connect(): boolean;
}

export interface RichService {
  mixinPing(tag: string): string;
}

export declare namespace RichService {
  export interface Options {
    endpoint: string;
    timeoutMs?: number;
  }
  export let defaultTimeout: number;
  export function fromOptions(opts: Options): RichService;
}

export function formatMetric(name: string, value: number): string;
export declare namespace formatMetric {
  export let prefix: string;
  export function reset(): void;
}

export function _(items: string[]): number;
export declare namespace _ {
  export const VERSION: string;
  export function uniq(items: string[]): string[];
}

export enum LogLevel {
  Info = 0,
  Warn = 1,
  Err = 2,
}

export declare namespace LogLevel {
  export function parse(label: string): LogLevel;
  export let defaultLevel: LogLevel;
}

export declare namespace Telemetry {
  export let serviceName: string;
  export function flush(): number;
}

export declare namespace Telemetry {
  export let sampleRate: number;
  export function record(metric: string): void;
}

export function checkDefaultBridge(label: string): ReturnType<typeof defaultCreate>;
