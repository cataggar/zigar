import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import {
  instantiateTypeScriptComponent,
  MODIFIER_FLAGS,
} from "./wasi-component-runner.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..", "..", "..");
const defaultWasmPath = path.resolve(
  __dirname,
  "..",
  "dist",
  "typescript-compiler.component.wasm",
);
const wasmPath = process.env.TS_ZIGAR_COMPONENT_WASM
  ? path.resolve(process.env.TS_ZIGAR_COMPONENT_WASM)
  : defaultWasmPath;

const ALL_EXPECTED_DECL_KINDS = [
  "function-decl",
  "variable-decl",
  "interface-decl",
  "class-decl",
  "type-alias-decl",
  "enum-decl",
  "namespace-decl",
  "import-equals-decl",
  "re-export-decl",
];

const ALL_EXPECTED_TYPE_KINDS = [
  "any-type",
  "unknown-type",
  "void-type",
  "undefined-type",
  "null-type",
  "never-type",
  "boolean-type",
  "number-type",
  "bigint-type",
  "string-type",
  "symbol-type",
  "unique-symbol",
  "object-type",
  "this-type",
  "literal",
  "template-literal",
  "array",
  "readonly-array",
  "tuple",
  "readonly-tuple",
  "union-type",
  "intersection",
  "reference",
  "type-param",
  "infer-type",
  "function-type",
  "constructor-type",
  "object-literal",
  "keyof-type",
  "typeof-query",
  "indexed-access",
  "conditional",
  "mapped",
  "type-predicate",
  "import-type",
  "intrinsic",
];

function ensureTypesNode26Dir() {
  const fromEnv = process.env.TS_ZIGAR_CACHE_DIR?.trim();
  const cacheBase = fromEnv
    ? path.resolve(fromEnv)
    : fs.existsSync("/d/zigar-worktrees")
      ? "/d/zigar-worktrees/.cache/ts-zigar"
      : path.join(repoRoot, ".cache", "ts-zigar");
  const prefixDir = path.join(cacheBase, "types-node26");
  const pkgDir = path.join(prefixDir, "node_modules", "@types", "node");
  if (!fs.existsSync(path.join(pkgDir, "index.d.ts"))) {
    fs.mkdirSync(prefixDir, { recursive: true });
    const npmCache =
      process.env.NPM_CONFIG_CACHE ?? path.join(cacheBase, "npm-cache");
    const npmTmp = path.join(cacheBase, "npm-tmp");
    fs.mkdirSync(npmCache, { recursive: true });
    fs.mkdirSync(npmTmp, { recursive: true });
    execFileSync(
      "npm",
      [
        "install",
        "--prefix",
        prefixDir,
        "--no-save",
        "--no-audit",
        "--no-fund",
        "@types/node@26",
      ],
      {
        env: { ...process.env, NPM_CONFIG_CACHE: npmCache, TMPDIR: npmTmp },
        stdio: "inherit",
      },
    );
  }
  return pkgDir;
}

function mountDirectoryIntoVfs(vfs, hostDir, vfsPrefix) {
  const entries = fs.readdirSync(hostDir, { withFileTypes: true });
  for (const entry of entries) {
    const hostPath = path.join(hostDir, entry.name);
    const vfsPath = `${vfsPrefix}/${entry.name}`;
    if (entry.isDirectory()) {
      mountDirectoryIntoVfs(vfs, hostPath, vfsPath);
    } else if (
      entry.isFile() &&
      (entry.name.endsWith(".d.ts") || entry.name === "package.json")
    ) {
      vfs.writeFile(vfsPath, fs.readFileSync(hostPath, "utf8"));
    }
  }
}

function findDecl(graph, name, kindTag = null, moduleId = null) {
  return graph.decls.find(
    (d) =>
      graph.str(d.name) === name &&
      (kindTag == null || d.kind.tag === kindTag) &&
      (moduleId == null || d.module === moduleId),
  );
}

function findDecls(graph, name) {
  return graph.decls.filter((d) => graph.str(d.name) === name);
}

describe("Go Semantic Declaration-Graph Extractor (zigar:typescript/extractor@7.1.0)", () => {
  let ts;

  before(() => {
    ts = instantiateTypeScriptComponent(wasmPath);
  });

  it("extracts every decl-kind (9/9) and type-kind (36/36), symbol keys, getters/setters, JSDoc, merging, and module directives", () => {
    const vfs = ts.createVfs(true);
    try {
      // Custom type package for `/// <reference types="custom-env" />`
      vfs.writeFile(
        "/node_modules/@types/custom-env/index.d.ts",
        "declare namespace CustomEnv { interface Config { mode: string; } }\n",
      );
      // Helper path reference for `/// <reference path="./extra.d.ts" />`
      vfs.writeFile(
        "/extra.d.ts",
        "declare var EXTRA_GLOBAL_FLAG: boolean;\n",
      );
      // CommonJS `export =` module
      vfs.writeFile(
        "/cjs.d.ts",
        [
          "declare namespace CjsLib {",
          "  interface Options { port: number; }",
          "}",
          "declare function CjsLib(opts: CjsLib.Options): void;",
          "export = CjsLib;",
          "",
        ].join("\n"),
      );
      // Dependency module for named, type-only, namespace, and star re-exports + import types
      vfs.writeFile(
        "/dep.ts",
        [
          "export interface OrigGeneric<T = string> { value: T; }",
          "export type OnlyType = { tag: 'only' };",
          "export const depValue = 123;",
          "export const starItem = 'from-star';",
          "",
        ].join("\n"),
      );

      // Comprehensive entry module exercising all 9 decl-kinds & all 36 type-kinds
      const entrySource = [
        '/// <reference types="custom-env" />',
        '/// <reference path="./extra.d.ts" />',
        '/// <reference lib="es2024" />',
        "",
        "export as namespace SyntheticUMD;",
        "",
        "export declare const myUniqueSym: unique symbol;",
        "",
        "/** Primary user model. @deprecated Use V2User instead */",
        "export interface BaseEntity {",
        "  readonly id: string;",
        "}",
        "",
        "export interface MergedBox<out T = unknown> extends BaseEntity {",
        "  item: T;",
        "  optionalProp?: number;",
        "  (input: string): T;",
        "  new (seed: T): MergedBox<T>;",
        "  readonly [index: number]: unknown;",
        "  [Symbol.iterator](): Iterator<T>;",
        "  [Symbol.asyncIterator](): AsyncIterator<T>;",
        "  [Symbol.dispose](): void;",
        "  [Symbol.asyncDispose](): Promise<void>;",
        "  [Symbol.toPrimitive](hint: string): string | number;",
        "  readonly [Symbol.toStringTag]: string;",
        "  [myUniqueSym]: symbol;",
        "}",
        "// Second interface block for multi-block interface merging",
        "export interface MergedBox<out T = unknown> {",
        "  extraMergedField: boolean;",
        "}",
        "export namespace MergedBox {",
        "  export const version = 2;",
        "  export namespace Nested {",
        "    export type Flag = true;",
        "  }",
        "}",
        "",
        "/** Overloaded parser function. @param raw input text @returns parsed value */",
        "export function parseInput(this: BaseEntity, raw: string): number;",
        "export function parseInput(raw: number, radix?: number, ...rest: string[]): string;",
        "export function parseInput(raw: string | number): number | string {",
        "  return typeof raw === 'string' ? Number(raw) : String(raw);",
        "}",
        "export namespace parseInput {",
        "  export const strictMode = true;",
        "}",
        "",
        "export function isString(x: unknown): x is string {",
        "  return typeof x === 'string';",
        "}",
        "export function assertNonNull<T>(val: T): asserts val is NonNullable<T> {",
        "  if (val == null) throw new Error('null');",
        "}",
        "export function assertCondition(cond: boolean): asserts cond {",
        "  if (!cond) throw new Error('failed');",
        "}",
        "",
        "export enum LogLevel {",
        "  Silent = 0,",
        "  Info = 1 << 1,",
        "  Custom = 'custom-level',",
        "}",
        "export const enum ConstFlags {",
        "  None = 0,",
        "  Fast = 4,",
        "}",
        "",
        "export abstract class AbstractWidget<in out State = string> implements BaseEntity {",
        "  readonly id: string = 'w';",
        "  static readonly category: string = 'ui';",
        "  static [Symbol.hasInstance](instance: unknown): boolean { return false; }",
        "  private hiddenSecret: number = 7;",
        "  #ecmaPrivate: string = 'secret';",
        "  protected protField?: boolean;",
        "  constructor(id: string);",
        "  constructor(id: string, initial?: State) { this.id = id; }",
        "  get label(): string { return this.id; }",
        "  set label(v: string | number) {}",
        "  fluent(): this { return this; }",
        "  abstract render(state: State): void;",
        "  [key: string]: any;",
        "}",
        "",
        "export class ConcreteWidget extends AbstractWidget<number> {",
        "  render(_state: number): void {}",
        "}",
        "",
        "// Interface + variable declaration merging (Buffer pattern)",
        "export interface BufLike { readonly byteLength: number; }",
        "export declare var BufLike: { new (len: number): BufLike; isBuf(x: unknown): x is BufLike };",
        "",
        "// Every primitive, literal, tuple, operator, and intrinsic type-kind",
        "export type PrimAny = any;",
        "export type PrimUnknown = unknown;",
        "export type PrimVoid = void;",
        "export type PrimUndefined = undefined;",
        "export type PrimNull = null;",
        "export type PrimNever = never;",
        "export type PrimBool = boolean;",
        "export type PrimNum = number;",
        "export type PrimBigInt = bigint;",
        "export type PrimStr = string;",
        "export type PrimSym = symbol;",
        "export type PrimObj = object;",
        "export type UniqueSymRef = typeof myUniqueSym;",
        "export type LitStr = 'zigar';",
        "export type LitNum = -42;",
        "export type LitBigInt = -99n;",
        "export type LitBoolTrue = true;",
        "export type LitBoolFalse = false;",
        "export type TplLit = `zigar-${string}-${number}`;",
        "export type MutArr = string[];",
        "export type RoArr = readonly number[];",
        "export type MutTuple = [id: string, count?: number, ...flags: boolean[]];",
        "export type RoTuple = readonly [first: number, ...rest: string[]];",
        "export type UnionSample = string | number;",
        "export type IntersectSample = BaseEntity & { extra: number };",
        "export type FnTypeSample = <const U extends string = 'a'>(this: BaseEntity, x: U, y?: number, ...z: boolean[]) => x is U;",
        "export type CtorTypeConcrete = new (id: string) => ConcreteWidget;",
        "export type CtorTypeAbstract = abstract new (id: string) => AbstractWidget<number>;",
        "export type ObjLitSample = {",
        "  readonly prop: string;",
        "  opt?: number;",
        "  (a: number): boolean;",
        "  new (a: string): object;",
        "  readonly [k: string]: unknown;",
        "};",
        "export type KeyofSample = keyof BaseEntity;",
        "export type TypeofSample = typeof parseInput;",
        "export type IndexedSample = MergedBox<number>['item'];",
        "export type InferConditional<T> = T extends Promise<infer R extends BaseEntity> ? R : never;",
        "export type MappedRemap<T> = { -readonly [K in keyof T as `get_${string & K}`]+?: T[K] };",
        "export type MappedAdd<T> = { +readonly [K in keyof T]-?: T[K] };",
        "export type ImportQualType = import('./dep').OrigGeneric<number>;",
        "export type ImportTypeofMod = typeof import('./dep');",
        "export type IntrinsicUpper<S extends string> = intrinsic;",
        "export type ExpandedPick = Pick<{ a: string; b: number; c: boolean }, 'a' | 'b'>;",
        "",
        "export import AliasedNested = MergedBox.Nested;",
        "export { OrigGeneric as RenamedOrig } from './dep';",
        "export type { OnlyType } from './dep';",
        "export * as depNs from './dep';",
        "export * from './dep';",
        "",
        "declare module 'virtual:plugin' {",
        "  export interface PluginConfig { enabled: boolean; }",
        "  export function registerPlugin(cfg: PluginConfig): void;",
        "}",
        "",
        "declare global {",
        "  interface GlobalRegistry { syntheticLoaded: boolean; }",
        "}",
        "",
        "const defaultValue = { ready: true } as const;",
        "export default defaultValue;",
        "",
      ].join("\n");

      vfs.writeFile("/index.ts", entrySource);

      const progRes = ts.createProgram(vfs, ["/index.ts", "/cjs.d.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
        typeRoots: ["/node_modules/@types"],
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        // 1. Default extraction with JSDoc + utility expansion, excluding private members
        const res = ts.extractModuleGraph(program, {
          rootFiles: ["/index.ts", "/cjs.d.ts"],
          followReExports: true,
          expandUtilityTypes: true,
          includeJsdoc: true,
          includePrivateMembers: false,
        });
        assert.equal(res.ok, true);
        const g = res.value;

        // Verify all 9 decl-kinds are present
        const seenDeclKinds = new Set(g.decls.map((d) => d.kind.tag));
        for (const expectedKind of ALL_EXPECTED_DECL_KINDS) {
          assert.ok(
            seenDeclKinds.has(expectedKind),
            `Missing decl-kind '${expectedKind}'; saw: ${[...seenDeclKinds].join(", ")}`,
          );
        }
        assert.equal(seenDeclKinds.size, 9);

        // Verify all 36 type-kinds are present
        const seenTypeKinds = new Set(g.types.map((t) => t.kind.tag));
        for (const expectedTypeKind of ALL_EXPECTED_TYPE_KINDS) {
          assert.ok(
            seenTypeKinds.has(expectedTypeKind),
            `Missing type-kind '${expectedTypeKind}'; saw: ${[...seenTypeKinds].join(", ")}`,
          );
        }
        assert.equal(seenTypeKinds.size, 36);

        // Verify module metadata on `/index.ts` and `/cjs.d.ts`
        const indexMod = g.modules.find((m) => g.str(m.filePath) === "/index.ts");
        assert.ok(indexMod, "Expected /index.ts module");
        assert.equal(g.str(indexMod.umdNamespace), "SyntheticUMD");
        assert.deepEqual(indexMod.tripleSlashTypes.map((id) => g.str(id)), ["custom-env"]);
        assert.deepEqual(indexMod.tripleSlashPaths.map((id) => g.str(id)), ["./extra.d.ts"]);
        assert.deepEqual(indexMod.tripleSlashLibs.map((id) => g.str(id)), ["es2024"]);
        assert.deepEqual(
          indexMod.starReExports.map((modId) => g.str(g.modules[modId].filePath)),
          ["/dep.ts"],
        );
        assert.ok(indexMod.defaultExport != null, "Expected defaultExport on /index.ts");
        assert.equal(indexMod.ambientModules.length, 1);
        assert.equal(g.str(indexMod.ambientModules[0].moduleName), "virtual:plugin");
        assert.ok(indexMod.ambientModules[0].decls.length >= 2);
        assert.ok(indexMod.globalAugmentations.length >= 1);

        const cjsMod = g.modules.find((m) => g.str(m.filePath) === "/cjs.d.ts");
        assert.ok(cjsMod, "Expected /cjs.d.ts module");
        assert.ok(cjsMod.exportEquals != null, "Expected exportEquals on /cjs.d.ts");

        // Verify function overloads, `this` param, optional/rest params, predicates, and JSDoc
        const parseFn = findDecl(g, "parseInput", "function-decl", indexMod.id);
        assert.ok(parseFn);
        assert.equal(parseFn.kind.val.length, 2, "Expected 2 overload signatures on parseInput");
        const sig0 = g.signatures[parseFn.kind.val[0]];
        assert.ok(sig0.thisParam != null, "Expected explicit `this` parameter on overload 1");
        const sig1 = g.signatures[parseFn.kind.val[1]];
        assert.equal(sig1.params.length, 3);
        assert.equal(sig1.params[1].optional, true);
        assert.equal(sig1.params[2].rest, true);
        assert.ok(parseFn.jsdoc);
        assert.match(g.str(parseFn.jsdoc.summary) ?? "", /Overloaded parser function/);
        assert.ok(parseFn.jsdoc.tags.some((t) => g.str(t.name) === "param"));
        assert.ok(parseFn.jsdoc.tags.some((t) => g.str(t.name) === "returns"));

        // Type predicates (`x is string`, `asserts val is NonNullable<T>`, `asserts cond`)
        const isStringFn = findDecl(g, "isString", "function-decl", indexMod.id);
        const isStringPred = g.signatures[isStringFn.kind.val[0]].typePredicate;
        assert.ok(isStringPred);
        assert.equal(g.str(isStringPred.paramName), "x");
        assert.equal(isStringPred.paramIndex, 0);
        assert.equal(isStringPred.asserts, false);
        assert.ok(isStringPred.targetType != null);

        const assertNonNullFn = findDecl(g, "assertNonNull", "function-decl", indexMod.id);
        const assertNonNullPred = g.signatures[assertNonNullFn.kind.val[0]].typePredicate;
        assert.ok(assertNonNullPred);
        assert.equal(assertNonNullPred.asserts, true);
        assert.ok(assertNonNullPred.targetType != null);

        const assertCondFn = findDecl(g, "assertCondition", "function-decl", indexMod.id);
        const assertCondPred = g.signatures[assertCondFn.kind.val[0]].typePredicate;
        assert.ok(assertCondPred);
        assert.equal(assertCondPred.asserts, true);
        assert.equal(assertCondPred.targetType, null);

        // Verify deprecated JSDoc on BaseEntity
        const baseEntityDecl = findDecl(g, "BaseEntity", "interface-decl", indexMod.id);
        assert.ok(baseEntityDecl?.jsdoc);
        assert.equal(baseEntityDecl.jsdoc.isDeprecated, true);
        assert.match(g.str(baseEntityDecl.jsdoc.deprecationMessage) ?? "", /Use V2User instead/);

        // Verify multi-block interface merging + interface/namespace `mergedWith` + symbol keys
        const mergedBoxIface = findDecl(g, "MergedBox", "interface-decl", indexMod.id);
        const mergedBoxNs = findDecl(g, "MergedBox", "namespace-decl", indexMod.id);
        assert.ok(mergedBoxIface && mergedBoxNs);
        assert.ok(mergedBoxIface.mergedWith.includes(mergedBoxNs.id));
        assert.ok(mergedBoxNs.mergedWith.includes(mergedBoxIface.id));

        const mergedBoxProps = mergedBoxIface.kind.val.properties.map((pid) => g.properties[pid]);
        const propNames = mergedBoxProps.map((p) => g.str(p.name));
        assert.ok(propNames.includes("item"));
        assert.ok(propNames.includes("extraMergedField"), "Second interface block must merge");
        assert.ok(
          mergedBoxProps.some(
            (p) => p.computedSymbol?.tag === "well-known" && p.computedSymbol.val === "to-string-tag",
          ),
        );
        const uniqueSymDecl = findDecl(g, "myUniqueSym", "variable-decl", indexMod.id);
        assert.ok(uniqueSymDecl);
        assert.ok(
          mergedBoxProps.some(
            (p) => p.computedSymbol?.tag === "unique" && p.computedSymbol.val === uniqueSymDecl.id,
          ),
        );

        const wellKnownMethods = mergedBoxIface.kind.val.methods
          .map((m) => m.computedSymbol)
          .filter((s) => s?.tag === "well-known")
          .map((s) => s.val);
        for (const wk of ["iterator", "async-iterator", "dispose", "async-dispose", "to-primitive"]) {
          assert.ok(wellKnownMethods.includes(wk), `Expected well-known symbol method ${wk}`);
        }

        // Verify function + namespace and interface + variable merging
        const parseNs = findDecl(g, "parseInput", "namespace-decl", indexMod.id);
        assert.ok(parseFn.mergedWith.includes(parseNs.id));
        const bufIface = findDecl(g, "BufLike", "interface-decl", indexMod.id);
        const bufVar = findDecl(g, "BufLike", "variable-decl", indexMod.id);
        assert.ok(bufIface && bufVar);
        assert.ok(bufIface.mergedWith.includes(bufVar.id));

        // Verify enums & const enums with Checker-evaluated constant values
        const logEnum = findDecl(g, "LogLevel", "enum-decl", indexMod.id);
        assert.ok(logEnum);
        assert.equal(logEnum.kind.val.isConst, false);
        const infoMember = logEnum.kind.val.members.find((m) => g.str(m.name) === "Info");
        assert.deepEqual(infoMember?.value, { tag: "num", val: 2 });
        const customMember = logEnum.kind.val.members.find((m) => g.str(m.name) === "Custom");
        assert.equal(customMember?.value?.tag, "str");
        assert.equal(g.str(customMember.value.val), "custom-level");

        const constEnum = findDecl(g, "ConstFlags", "enum-decl", indexMod.id);
        assert.ok(constEnum);
        assert.equal(constEnum.kind.val.isConst, true);

        // Verify abstract class, constructors, divergent getter/setter, `[Symbol.hasInstance]`, and private filtering
        const widgetClass = findDecl(g, "AbstractWidget", "class-decl", indexMod.id);
        assert.ok(widgetClass);
        assert.ok((widgetClass.modifiers & MODIFIER_FLAGS.abstractMod) !== 0);
        assert.equal(widgetClass.kind.val.implementsClauses.length, 1);
        assert.equal(widgetClass.kind.val.implementsClauses[0].targetDecl, baseEntityDecl.id);
        assert.ok(widgetClass.kind.val.constructors.length >= 1);

        const widgetProps = widgetClass.kind.val.properties.map((pid) => g.properties[pid]);
        const widgetPropNames = widgetProps.map((p) => g.str(p.name));
        assert.ok(!widgetPropNames.includes("hiddenSecret"), "Private member must be omitted by default");
        assert.ok(!widgetPropNames.includes("#ecmaPrivate"), "#private member must be omitted by default");

        const labelProp = widgetProps.find((p) => g.str(p.name) === "label");
        assert.ok(labelProp, "Expected getter/setter property `label`");
        assert.equal(labelProp.hasGetter, true);
        assert.equal(labelProp.hasSetter, true);
        assert.ok(labelProp.setterTy != null, "Expected divergent setterTy on `label`");
        assert.equal(g.types[labelProp.ty].kind.tag, "string-type");
        assert.equal(g.types[labelProp.setterTy].kind.tag, "union-type");

        assert.ok(
          widgetClass.kind.val.methods.some(
            (m) =>
              m.computedSymbol?.tag === "well-known" &&
              m.computedSymbol.val === "has-instance" &&
              (m.modifiers & MODIFIER_FLAGS.staticMod) !== 0,
          ),
        );

        // Verify tuple labels/optional/variadic, abstract constructor type, mapped modifiers, and `resolvedType`
        const mutTupleAlias = findDecl(g, "MutTuple", "type-alias-decl", indexMod.id);
        const mutTupleTy = g.types[mutTupleAlias.kind.val];
        assert.equal(mutTupleTy.kind.tag, "tuple");
        assert.equal(mutTupleTy.kind.val.length, 3);
        assert.equal(g.str(mutTupleTy.kind.val[0].label), "id");
        assert.equal(mutTupleTy.kind.val[0].optional, false);
        assert.equal(g.str(mutTupleTy.kind.val[1].label), "count");
        assert.equal(mutTupleTy.kind.val[1].optional, true);
        assert.equal(g.str(mutTupleTy.kind.val[2].label), "flags");
        assert.equal(mutTupleTy.kind.val[2].variadic, true);

        const absCtorAlias = findDecl(g, "CtorTypeAbstract", "type-alias-decl", indexMod.id);
        const absCtorTy = g.types[absCtorAlias.kind.val];
        assert.equal(absCtorTy.kind.tag, "constructor-type");
        assert.equal(g.signatures[absCtorTy.kind.val].isAbstract, true);

        const mappedRemapAlias = findDecl(g, "MappedRemap", "type-alias-decl", indexMod.id);
        const mappedRemapTy = g.types[mappedRemapAlias.kind.val];
        assert.equal(mappedRemapTy.kind.tag, "mapped");
        assert.equal(mappedRemapTy.kind.val.readonlyModifier, "remove");
        assert.equal(mappedRemapTy.kind.val.optionalModifier, "add");
        assert.ok(mappedRemapTy.kind.val.nameType != null);

        const expandedPickAlias = findDecl(g, "ExpandedPick", "type-alias-decl", indexMod.id);
        const expandedPickTy = g.types[expandedPickAlias.kind.val];
        assert.ok(
          expandedPickTy.resolvedType != null,
          "Expected expandUtilityTypes=true to populate resolvedType on Pick<...>",
        );
        const resolvedPickObj = g.types[expandedPickTy.resolvedType];
        assert.equal(resolvedPickObj.kind.tag, "object-literal");
        const resolvedPickPropNames = resolvedPickObj.kind.val.properties.map((pid) =>
          g.str(g.properties[pid].name),
        );
        assert.deepEqual(resolvedPickPropNames.sort(), ["a", "b"]);

        // 2. Re-extract with `includePrivateMembers: true` and `moduleSpecifiers` filter
        const privRes = ts.extractModuleGraph(program, {
          rootFiles: ["/index.ts", "/cjs.d.ts"],
          moduleSpecifiers: ["/index.ts"],
          followReExports: false,
          expandUtilityTypes: false,
          includeJsdoc: false,
          includePrivateMembers: true,
        });
        assert.equal(privRes.ok, true);
        const pg = privRes.value;
        assert.equal(pg.entryModules.length, 1);
        const privWidget = findDecl(pg, "AbstractWidget", "class-decl");
        const privPropNames = privWidget.kind.val.properties.map((pid) =>
          pg.str(pg.properties[pid].name),
        );
        assert.ok(privPropNames.includes("hiddenSecret"));
        assert.ok(privPropNames.includes("#ecmaPrivate"));
        assert.equal(privWidget.jsdoc, null, "includeJsdoc=false must omit JSDoc");
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("handles cyclic declaration & type graphs (fluent `this`, self-returning Buffer, mutual recursion, F-bounded generics, recursive JsonValue) without stack overflow", () => {
    const vfs = ts.createVfs(true);
    try {
      const cyclicSource = [
        "export interface DomNode {",
        "  parent: DomNode | null;",
        "  readonly children: readonly ChildDomNode[];",
        "  cloneNode(deep?: boolean): DomNode;",
        "}",
        "export interface ChildDomNode extends DomNode {",
        "  nextSibling: ChildDomNode | null;",
        "  previousSibling: ChildDomNode | null;",
        "  readonly owner: DomNode;",
        "}",
        "",
        "export interface EventSchema<Self extends EventSchema<Self>> {",
        "  [K: string]: (...args: any[]) => Self;",
        "}",
        "",
        "export class FluentEmitter<E extends EventSchema<E>> {",
        "  on<K extends keyof E>(event: K, listener: E[K]): this { return this; }",
        "  pipe(target: FluentEmitter<E>): FluentEmitter<E> { return target; }",
        "}",
        "",
        "export interface CyclicBuffer {",
        "  readonly length: number;",
        "  subarray(start?: number, end?: number): CyclicBuffer;",
        "  copy(target: CyclicBuffer): number;",
        "}",
        "export declare var CyclicBuffer: {",
        "  new (size: number): CyclicBuffer;",
        "  alloc(size: number, fill?: CyclicBuffer | number): CyclicBuffer;",
        "};",
        "",
        "export type JsonPrimitive = string | number | boolean | null;",
        "export type JsonArray = JsonValue[];",
        "export interface JsonObject { [key: string]: JsonValue; }",
        "export type JsonValue = JsonPrimitive | JsonArray | JsonObject;",
        "",
      ].join("\n");

      vfs.writeFile("/cyclic.ts", cyclicSource);
      const progRes = ts.createProgram(vfs, ["/cyclic.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        for (const expandUtilityTypes of [false, true]) {
          const res = ts.extractModuleGraph(program, {
            rootFiles: ["/cyclic.ts"],
            expandUtilityTypes,
          });
          assert.equal(res.ok, true);
          const g = res.value;

          const domNode = findDecl(g, "DomNode", "interface-decl");
          const childNode = findDecl(g, "ChildDomNode", "interface-decl");
          assert.ok(domNode && childNode);
          assert.equal(childNode.kind.val.extendsClauses[0].targetDecl, domNode.id);

          // Verify `DomNode.cloneNode()` return type points back to `DomNode` decl-id
          const cloneMethod = domNode.kind.val.methods.find(
            (m) => g.str(m.name) === "cloneNode",
          );
          assert.ok(cloneMethod);
          const cloneRetTy = g.types[g.signatures[cloneMethod.signatures[0]].returnType];
          assert.equal(cloneRetTy.kind.tag, "reference");
          assert.equal(cloneRetTy.kind.val.targetDecl, domNode.id);

          // Verify fluent `this` return type on `FluentEmitter.on`
          const emitter = findDecl(g, "FluentEmitter", "class-decl");
          assert.ok(emitter);
          const onMethod = emitter.kind.val.methods.find((m) => g.str(m.name) === "on");
          assert.ok(onMethod);
          const onRetTy = g.types[g.signatures[onMethod.signatures[0]].returnType];
          assert.equal(onRetTy.kind.tag, "this-type");

          // Verify merged CyclicBuffer interface + variable
          const cycBufIface = findDecl(g, "CyclicBuffer", "interface-decl");
          const cycBufVar = findDecl(g, "CyclicBuffer", "variable-decl");
          assert.ok(cycBufIface && cycBufVar);
          assert.ok(cycBufIface.mergedWith.includes(cycBufVar.id));

          // Verify recursive JsonValue union
          const jsonVal = findDecl(g, "JsonValue", "type-alias-decl");
          assert.ok(jsonVal);
          assert.equal(g.types[jsonVal.kind.val].kind.tag, "union-type");
        }
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("extracts real @types/node@26 (.d.ts) with ambient modules, Buffer, EventEmitter, readFile overloads, and global augmentations", () => {
    const typesNodeDir = ensureTypesNode26Dir();
    const vfs = ts.createVfs(true);
    try {
      mountDirectoryIntoVfs(vfs, typesNodeDir, "/node_modules/@types/node");

      const rootFiles = ["/node_modules/@types/node/index.d.ts"];
      const progRes = ts.createProgram(vfs, rootFiles, {
        target: "esnext",
        module: "nodenext",
        moduleResolution: "nodenext",
        strict: true,
        skipLibCheck: true,
        typeRoots: ["/node_modules/@types"],
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        const res = ts.extractModuleGraph(program, {
          rootFiles,
          followReExports: true,
          expandUtilityTypes: false,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(res.ok, true);
        const g = res.value;

        assert.ok(g.modules.length >= 20, `Expected >= 20 modules, got ${g.modules.length}`);
        assert.ok(g.decls.length >= 200, `Expected >= 200 decls, got ${g.decls.length}`);
        assert.ok(g.types.length >= 500, `Expected >= 500 types, got ${g.types.length}`);

        // Collect all ambient modules across the extracted @types/node@26 module graph
        const ambientBySpec = new Map();
        for (const mod of g.modules) {
          for (const amb of mod.ambientModules) {
            const spec = g.str(amb.moduleName);
            const prev = ambientBySpec.get(spec) ?? [];
            ambientBySpec.set(spec, prev.concat(amb.decls));
          }
        }

        for (const requiredMod of ["fs", "node:fs", "http", "node:http", "events", "node:events", "buffer", "node:buffer"]) {
          assert.ok(
            ambientBySpec.has(requiredMod),
            `Expected ambient module '${requiredMod}' in @types/node@26`,
          );
        }

        // Verify `readFile` overload signatures inside `fs` / `node:fs`
        const fsDeclIds = [
          ...(ambientBySpec.get("fs") ?? []),
          ...(ambientBySpec.get("node:fs") ?? []),
        ];
        const readFileDecl = fsDeclIds
          .map((id) => g.decls[id])
          .find((d) => g.str(d.name) === "readFile" && d.kind.tag === "function-decl");
        assert.ok(readFileDecl, "Expected `readFile` function-decl in `fs`/`node:fs`");
        assert.ok(
          readFileDecl.kind.val.length >= 3,
          `Expected >= 3 overloads on fs.readFile, got ${readFileDecl.kind.val.length}`,
        );

        // Verify `Buffer` declarations (interface + constructor variable) and `subarray` method
        const bufferDecls = findDecls(g, "Buffer");
        assert.ok(
          bufferDecls.some((d) => d.kind.tag === "interface-decl"),
          "Expected `interface Buffer` in @types/node@26",
        );
        assert.ok(
          bufferDecls.some((d) => d.kind.tag === "variable-decl"),
          "Expected `var Buffer: BufferConstructor` in @types/node@26",
        );

        // Verify `EventEmitter` declaration in `events`
        const eventEmitterDecls = findDecls(g, "EventEmitter");
        assert.ok(
          eventEmitterDecls.some(
            (d) => d.kind.tag === "class-decl" || d.kind.tag === "interface-decl",
          ),
          "Expected `EventEmitter` class/interface in @types/node@26",
        );

        // Verify global augmentations (`process`, `Buffer`, `NodeJS`, etc.)
        const totalGlobalAugmentations = g.modules.reduce(
          (sum, m) => sum + m.globalAugmentations.length,
          0,
        );
        assert.ok(
          totalGlobalAugmentations >= 1,
          "Expected non-empty globalAugmentations from @types/node@26 globals.d.ts",
        );

        // Also verify targeted `moduleSpecifiers: ["node:fs"]` filtering on @types/node@26
        const fsOnlyRes = ts.extractModuleGraph(program, {
          rootFiles,
          moduleSpecifiers: ["node:fs"],
          followReExports: false,
          expandUtilityTypes: false,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(fsOnlyRes.ok, true);
        const fg = fsOnlyRes.value;
        assert.ok(fg.entryModules.length >= 1);
        const fgAmbSpecs = new Set(
          fg.modules.flatMap((m) => m.ambientModules.map((a) => fg.str(a.moduleName))),
        );
        assert.ok(fgAmbSpecs.has("node:fs"));
        assert.ok(!fgAmbSpecs.has("node:http"), "Filtered graph must not include node:http");
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });
});
