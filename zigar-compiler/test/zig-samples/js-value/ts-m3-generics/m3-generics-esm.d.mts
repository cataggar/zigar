export interface UserProfile {
  id: number;
  displayName: string;
  hostName: string;
  port?: number;
}

export interface DefaultMeta {
  version: number;
  tag: string;
}

export interface Envelope<T, Meta = DefaultMeta> {
  payload: T;
  meta: Meta;
  ok: boolean;
}

export type HttpVerb = "GET" | "POST" | "DELETE";
export type UserProfileKey = keyof UserProfile;

// Open user-defined homomorphic mapped & conditional utility types
export type MutablePatch<T> = {
  -readonly [P in keyof T]?: T[P];
};

export type UnwrapAsync<T> = T extends Promise<infer U> ? U : T;

// 1. Generic functions: explicit, *Default, *Infer, const T, NoInfer<T>
export declare function identity<T = string>(value: T): T;
export declare function wrapEnvelope<T, Meta = DefaultMeta>(payload: T, meta?: Meta): Envelope<T, Meta>;
export declare function freezeTuple<const T extends readonly number[]>(items: T): T;
export declare function selectWithFallback<T>(candidates: readonly T[], fallback: NoInfer<T>): T;

// 2. Constrained generics (`T extends { id: number }`, `K extends keyof T -> T[K]`, generic overloads)
export declare function formatIdentified<T extends { id: number }>(item: T, prefix: string): string;
export declare function getField<T, K extends keyof T>(obj: T, key: K): T[K];

export declare function describeInput<T extends { id: number }>(item: T): string;
export declare function describeInput(label: string): string;

// 3. Generic handle class (`GenericStore<K = string, V = number>`, *Default, *With, generic method)
export declare class GenericStore<K = string, V = number> {
  readonly label: string;
  readonly size: number;
  constructor(label: string);
  set(key: K, value: V): void;
  get(key: K): V | undefined;
  snapshot(key: K): Envelope<V, K> | null;
  transformGet<R = string>(key: K, mapper: (value: V) => R): R | null;
}

// 4. Built-in & open utility types (`Partial`, `Required`, `Readonly`, `Pick`, `Omit`, `Record`, `NonNullable`, `Awaited`)
export declare function applyUserPatch(base: UserProfile, patch: Partial<UserProfile>): Required<UserProfile>;
export declare function applyGenericPatch<T>(base: T, patch: Partial<T>): Required<T>;
export declare function mergePickedAndOmitted<T, K extends keyof T>(picked: Pick<T, K>, omitted: Omit<T, K>): T;
export declare function summarizeUserSummary(
  summary: Pick<UserProfile, "id" | "displayName">,
): Omit<UserProfile, "id" | "port">;
export declare function sumReadonlyCoords(coords: Readonly<readonly number[]>): number;
export declare function totalVerbCounts(counts: Record<HttpVerb, number>): number;
export declare function buildDynamicScores(prefix: string): Record<string, number>;
export declare function requireText(val: NonNullable<string | null | undefined>): string;
export declare function patchMeta<M>(meta: M, patch: MutablePatch<M>): M;
export declare function formatUnwrappedProfile(
  profile: Awaited<Promise<Promise<UnwrapAsync<Promise<UserProfile>>>>>,
): string;

export interface NullishConfig {
  reqNull: string | null;
  optNull?: string | null;
  reqUndef: string | undefined;
  optStr?: string;
}
export declare function inspectRequiredNullish<T>(val: Required<T>): string;
export declare function inspectNullableVerbRecord<V>(rec: Record<HttpVerb, V>): string;

export enum Direction {
  Up = 0,
  Down = 1,
}
export type ValueAtUp<V> = Record<Direction, V>[Direction.Up];
export type At0<T extends { 0: string; 1: number }> = T[0];
export declare function inspectNumericEnumRecord<V>(rec: Record<Direction, V>): Record<Direction, V>;

export type Flags<T> = { [P in keyof T]: boolean };
export declare function flagsOf<T>(obj: T): Flags<T>;

// 5. `typeof`, `Parameters<typeof fn>`, `ReturnType<typeof fn>`, and concrete `T["prop"]` indexed-access
export declare const defaultEndpoint: { readonly host: string; readonly port: number };
export type EndpointConfig = typeof defaultEndpoint;
export type RequireTextArgs = Parameters<typeof requireText>;
export type UserDisplayName = UserProfile["displayName"];
export declare function describeEndpointTuple(
  endpoint: EndpointConfig,
  args: RequireTextArgs,
  owner: UserDisplayName,
): ReturnType<typeof requireText>;

