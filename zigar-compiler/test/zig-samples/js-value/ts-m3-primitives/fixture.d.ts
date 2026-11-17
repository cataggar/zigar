export {};

declare module "node:buffer" {
  export class Buffer extends Uint8Array {}
}

declare module "./m3-esm.mjs" {
  import { Buffer } from "node:buffer";

  export const SMALL_BIGINT = -99_999_000_111n;
  export const HUGE_BIGINT = 1_267_650_600_228_229_401_496_703_205_383n;
  export const ULTRA_BIGINT = 999_999_999_999_999_999_999_999_999_999_999_999_999_999n;

  export const UNIQUE_TOKEN: unique symbol;
  export let moduleTag: string;
  export let moduleCount: number;
  export function mutateEsmBindings(nextTag: string, delta: number): void;

  export default function defaultBanner(prefix: string, code?: number): string;

  export function recordVoid(delta: number): void;
  export function getVoidAcc(): number;
  export function alwaysThrow(reason: string): never;
  export function formatPrimitives(flag: boolean, score: number, id: bigint, label: string): string;
  export function addHugeBigInt(lhs: BigInt, delta: bigint): BigInt;
  export function borrowJsString(input: String): String;
  export function checkUniqueSymbol(sym: symbol): boolean;
  export function roundtripIntrinsics(obj: object, anyVal: any, unkVal: unknown): [object, any, unknown];

  export function callWithDefaults(base: string, suffix?: string, repeat?: number): string;
  export function classifyNullishArgs(
    nullArm: string | null,
    undefArm: string | undefined,
    bothArm: string | null | undefined,
  ): string;
  export function produceInboundOptional(mode: number): string | null | undefined;
  export function produceRawForNullable(mode: number): any;
  export function consumeRawFromNullable(val: any): string;

  export function transformStringArray(items: ReadonlyArray<string>, extra: number[]): string[];

  export type FixedPair = [number, boolean];
  export type LabeledOptEndpoint = [host: string, port?: number];
  export type TrailingRoute = [host: string, port?: number, ...tags: string[]];
  export type LeadingFlags = [...flags: boolean[], target: string];
  export type MiddleSandwich = [head: number, ...mid: string[], tail: boolean];

  export function flipFixedPair(pair: FixedPair): FixedPair;
  export function normalizeEndpoint(ep: LabeledOptEndpoint, omitPortOut: boolean): LabeledOptEndpoint;
  export function routeSummary(route: TrailingRoute): TrailingRoute;
  export function evalLeadingFlags(input: LeadingFlags): LeadingFlags;
  export function evalMiddleSandwich(input: MiddleSandwich): MiddleSandwich;
  export function malformedTupleReturn(kind: number): TrailingRoute;

  export function mutateBinaryInPlace(
    buf: Buffer,
    u8: Uint8Array,
    i32: Int32Array,
    f64: Float64Array,
    i64: BigInt64Array,
    ab: ArrayBuffer,
    sab: SharedArrayBuffer,
    dv: DataView,
  ): Buffer;

  export namespace nested {
    export let hits: number;
    export namespace deep {
      export function combine(a: string, b?: number): string;
    }
  }
}

declare module "./m3-cjs.cjs" {
  function cjsTransform(prefix: string, code?: number): [string, number];
  namespace cjsTransform {
    let invocations: number;
    function describe(tag: string | null): string;
  }
  export = cjsTransform;
}

declare global {
  var __m3GlobalLabel: string;
  function __m3GlobalCompute(name: string, bonus?: number): [string, number];
  namespace __m3GlobalBox {
    let count: number;
    function step(by?: number): number;
  }
}
