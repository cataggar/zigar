/// <reference path="./buffer.d.ts" />
import { Buffer } from "node:buffer";
import MiniChannel = require("./m3-unions-cjs.cjs");

// 1. Enums: numeric (i32), aliases, const string enum, 64-bit numeric enum, mixed enum, unknown-value ambient enum
export declare enum HttpStatus {
  Ok = 200,
  Created = 201,
  SuccessAlias = 200,
  NotFound = 404,
}

export declare const enum LogLevel {
  Info = "info",
  Warn = "warn",
  InfoAlias = "info",
}

export declare enum LargeOffset {
  Zero = 0,
  FiveBillion = 5_000_000_000,
}

export declare enum MixedCode {
  Auto = "auto",
  Zero = 0,
  One = 1,
}

export declare enum RuntimeFlags {
  Read,
  Write,
}

export declare enum OpType {
  Add = "add",
  Reset = "reset",
}

// 2. Closed literal unions
export type Encoding = "utf8" | "utf-8" | "hex" | "base64";
export type CompareOrder = -1 | 0 | 1;
export type FloatStep = 0.5 | 1.5 | 2.5;
export type BigChoice = 10n | 20n;
export type MixedScalarUnion = "none" | 0 | false | 1n;

// 3. Open literal unions
export type OpenMime = "application/json" | "text/plain" | (string & {});
export type OpenPort = 80 | 443 | (number & {});

// 4. Finite & open template literals
export type HookEvent = `on${"Open" | "Close" | "Error"}`;
export type SemVer = `v${number}.${number}.${number}`;
export type RouteUrl = `${"http" | "https"}://${string}/api/${bigint}`;

// 5. Discriminated unions (intersection-flattened, multi-tag, boolean, enum-member)
export interface SharedTrace {
  traceId: string;
}

export type AuditEvent =
  | (SharedTrace & { kind: "created"; id: string })
  | (SharedTrace & { kind: "updated" | "patched"; id: string; rev: number })
  | (SharedTrace & { kind: "deleted"; soft?: boolean });

export type Outcome =
  | { ok: true; value: string }
  | { ok: false; code: number; detail: string | null };

export type OpCmd =
  | { op: OpType.Add; amount: number }
  | { op: OpType.Reset };

// 6. Heterogeneous unions, recursive JsonValue, and generic union nullish overrides
export type HeteroPayload =
  | [string]
  | [string, number]
  | string[]
  | Buffer
  | Uint8Array
  | MiniChannel
  | SemVer
  | { host: string; port?: number }
  | string
  | number
  | boolean;

export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export type GenericEnvelope<T> =
  | { tag: "val"; item: T }
  | { tag: "empty"; reason: string | null };

export declare function stepStatus(status: HttpStatus, level: LogLevel, big: LargeOffset): [HttpStatus, LogLevel, LargeOffset];
export declare function badStatusReturn(mode: number): HttpStatus;
export declare function echoMixedAndClosed(
  mixed: MixedCode,
  enc: Encoding,
  ord: CompareOrder,
  step: FloatStep,
  big: BigChoice,
  scalar: MixedScalarUnion,
): string;
export declare function combineRuntimeFlags(a: RuntimeFlags, b: RuntimeFlags): number;

export declare function inspectOpenLiterals(mime: OpenMime, port: OpenPort): [OpenMime, OpenPort];
export declare function inspectTemplates(hook: HookEvent, ver: SemVer, route: RouteUrl): SemVer;
export declare function badSemVerReturn(mode: number): SemVer;

export declare function processAuditEvent(ev: AuditEvent): AuditEvent;
export declare function badAuditEventReturn(mode: number): AuditEvent;
export declare function processOutcomeAndCmd(out: Outcome, cmd: OpCmd): string;

export declare function produceHetero(mode: number): HeteroPayload;
export declare function produceImpostorChannel(): HeteroPayload;
export declare function describeHetero(payload: HeteroPayload): string;
export declare function transformJson(val: JsonValue): JsonValue;
export declare function unwrapEnvelope(env: GenericEnvelope<number | undefined>): [string, GenericEnvelope<string | null>];
