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

  it("handles renamed local exports, multi-alias exports, export= namespace ExportName, followReExports=false bare re-exports, and instantiated signatures", () => {
    const vfs = ts.createVfs(true);
    try {
      // 1. Single locally renamed export (`const hidden = 2; export { hidden as visible };`)
      //    + multi-alias (`const base = 10; export { base as aliasA, base as aliasB };`)
      vfs.writeFile(
        "/renamed.ts",
        [
          "const hidden = 2;",
          "export { hidden as visible };",
          "const base = 10;",
          "export { base as aliasA, base as aliasB };",
        ].join("\n"),
      );

      // 2. Secondary export alias (`export const foo = 1; export { foo as foo2 };` and reverse order)
      vfs.writeFile(
        "/multi-alias.ts",
        [
          "export const foo = 1;",
          "export { foo as foo2 };",
          "export { rev as revAlias };",
          "export const rev = 2;",
        ].join("\n"),
      );

      // 3. Order-independence when local type is visited via reference before/after `export type { Hidden as Public }`
      vfs.writeFile(
        "/order-a.ts",
        [
          "interface Hidden { x: number }",
          "export interface User { h: Hidden }",
          "export type { Hidden as Public };",
        ].join("\n"),
      );
      vfs.writeFile(
        "/order-b.ts",
        [
          "export type { Hidden as Public };",
          "interface Hidden { x: number }",
          "export interface User { h: Hidden }",
        ].join("\n"),
      );

      // 4. `export = Foo` with merged `declare function Foo` + `declare namespace Foo` (zero null exportName in exports)
      vfs.writeFile(
        "/export-eq-ns.d.ts",
        [
          "declare function Foo(): void;",
          "declare namespace Foo {",
          "  const version: string;",
          "  interface Opts { debug?: boolean }",
          "}",
          "export = Foo;",
        ].join("\n"),
      );

      // 5. Bare `import ...; export { ... }` with `followReExports: false`
      vfs.writeFile(
        "/x.d.ts",
        [
          "export interface X { a: number }",
          "declare const defVal: string;",
          "export default defVal;",
        ].join("\n"),
      );
      vfs.writeFile(
        "/cjs-dep.d.ts",
        "declare const eqVal: boolean; export = eqVal;",
      );
      vfs.writeFile(
        "/b.d.ts",
        [
          "import { X } from './x';",
          "import * as ns from './x';",
          "import d from './x';",
          "import eq = require('./cjs-dep');",
          "export { X, ns, d as z, eq };",
          "export type Y = X;",
        ].join("\n"),
      );

      // 6. Instantiated checker signatures (`const f = mk<string>()` and `Pick<Box<string>, 'get' | 'value'>`)
      vfs.writeFile(
        "/instantiated.ts",
        [
          "export declare function mk<T>(): (x: T, opt?: T, ...rest: T[]) => T;",
          "export const f = mk<string>();",
          "export declare function mkHigher<T>(): <U extends T = T>(u: U) => [T, U];",
          "export const h = mkHigher<number>();",
          "export interface Box<T> { get(): T; value: T }",
          "export type P = Pick<Box<string>, 'get' | 'value'>;",
        ].join("\n"),
      );

      const allRoots = [
        "/renamed.ts",
        "/multi-alias.ts",
        "/order-a.ts",
        "/order-b.ts",
        "/export-eq-ns.d.ts",
        "/b.d.ts",
        "/instantiated.ts",
      ];
      const progRes = ts.createProgram(vfs, allRoots, {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      });
      assert.equal(progRes.ok, true);
      const program = progRes.value;

      try {
        // Test 1-4 & 6 with expandUtilityTypes: true
        const res = ts.extractModuleGraph(program, {
          rootFiles: [
            "/renamed.ts",
            "/multi-alias.ts",
            "/order-a.ts",
            "/order-b.ts",
            "/export-eq-ns.d.ts",
            "/instantiated.ts",
          ],
          followReExports: true,
          expandUtilityTypes: true,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(res.ok, true);
        const g = res.value;

        const getMod = (fp) => {
          const m = g.modules.find((mod) => g.str(mod.filePath) === fp);
          assert.ok(m, `Expected module ${fp}`);
          return m;
        };
        const getExportMap = (mod) => {
          const map = new Map();
          for (const id of mod.exports) {
            const d = g.decls[id];
            assert.notEqual(
              d.exportName,
              null,
              `Exported decl '${g.str(d.name)}' in ${g.str(mod.filePath)} must not have null exportName`,
            );
            map.set(g.str(d.exportName), d);
          }
          return map;
        };

        // Case 1: `/renamed.ts` -> exported under `visible` (NOT `hidden`), plus BOTH `aliasA` and `aliasB`
        const renamedExports = getExportMap(getMod("/renamed.ts"));
        assert.ok(renamedExports.has("visible"), "Expected 'visible' export");
        assert.ok(!renamedExports.has("hidden"), "Must NOT export 'hidden'");
        assert.equal(g.str(renamedExports.get("visible").name), "hidden");
        assert.ok(renamedExports.has("aliasA"), "Expected 'aliasA' export");
        assert.ok(renamedExports.has("aliasB"), "Expected 'aliasB' export");
        assert.ok(!renamedExports.has("base"), "Must NOT export 'base'");

        // Case 2: `/multi-alias.ts` -> BOTH `foo` & `foo2`, and BOTH `rev` & `revAlias`
        const multiExports = getExportMap(getMod("/multi-alias.ts"));
        assert.ok(multiExports.has("foo"), "Expected 'foo' export");
        assert.ok(multiExports.has("foo2"), "Expected 'foo2' export");
        assert.equal(multiExports.get("foo").kind.tag, "variable-decl");
        assert.equal(multiExports.get("foo2").kind.tag, "re-export-decl");
        assert.equal(multiExports.get("foo2").kind.val.targetDecl, multiExports.get("foo").id);
        assert.ok(multiExports.has("rev"), "Expected 'rev' export");
        assert.ok(multiExports.has("revAlias"), "Expected 'revAlias' export");
        assert.equal(multiExports.get("rev").kind.tag, "variable-decl");
        assert.equal(multiExports.get("revAlias").kind.tag, "re-export-decl");
        assert.equal(multiExports.get("revAlias").kind.val.targetDecl, multiExports.get("rev").id);

        // Case 3: `/order-a.ts` & `/order-b.ts` -> `User` and `Public` in both statement orders
        for (const fp of ["/order-a.ts", "/order-b.ts"]) {
          const ordExports = getExportMap(getMod(fp));
          assert.deepEqual(
            [...ordExports.keys()].sort(),
            ["Public", "User"],
            `Expected ['Public', 'User'] exports in ${fp}`,
          );
          const pubDecl = ordExports.get("Public");
          assert.equal(pubDecl.kind.tag, "interface-decl");
          assert.equal(g.str(pubDecl.name), "Hidden");
          const userDecl = ordExports.get("User");
          const hProp = g.properties[userDecl.kind.val.properties[0]];
          assert.equal(g.types[hProp.ty].kind.val.targetDecl, pubDecl.id);
        }

        // Case 4: `/export-eq-ns.d.ts` -> zero null `exportName` in module exports or namespace decls
        const eqMod = getMod("/export-eq-ns.d.ts");
        assert.notEqual(eqMod.exportEquals, null);
        const eqExports = getExportMap(eqMod);
        assert.ok(eqExports.has("version"), "Expected 'version' in export= namespace exports");
        assert.ok(eqExports.has("Opts"), "Expected 'Opts' in export= namespace exports");
        const fooNs = findDecl(g, "Foo", "namespace-decl", eqMod.id);
        assert.ok(fooNs);
        assert.equal(g.str(fooNs.exportName), "Foo");
        for (const childId of fooNs.kind.val) {
          assert.notEqual(g.decls[childId].exportName, null);
        }

        // Case 6: `/instantiated.ts` -> `f` is `(x: string, opt?: string, ...rest: string[]) => string`,
        //         `h` has instantiated `<U extends number = number>`, and `P` expands to `{ get(): string; value: string }`
        const instMod = getMod("/instantiated.ts");
        const fDecl = findDecl(g, "f", "variable-decl", instMod.id);
        assert.ok(fDecl);
        const fType = g.types[fDecl.kind.val];
        assert.equal(fType.kind.tag, "function-type");
        const fSig = g.signatures[fType.kind.val];
        assert.equal(fSig.typeParams.length, 0);
        assert.equal(fSig.params.length, 3);
        assert.equal(g.types[fSig.params[0].ty].kind.tag, "string-type");
        assert.equal(fSig.params[0].optional, false);
        assert.equal(g.types[fSig.params[1].ty].kind.tag, "string-type");
        assert.equal(fSig.params[1].optional, true);
        assert.equal(fSig.params[2].rest, true);
        assert.equal(g.types[fSig.params[2].ty].kind.tag, "array");
        assert.equal(g.types[g.types[fSig.params[2].ty].kind.val].kind.tag, "string-type");
        assert.equal(g.types[fSig.returnType].kind.tag, "string-type");

        const hDecl = findDecl(g, "h", "variable-decl", instMod.id);
        const hSig = g.signatures[g.types[hDecl.kind.val].kind.val];
        assert.equal(hSig.typeParams.length, 1);
        const uTp = g.typeParams[hSig.typeParams[0]];
        assert.equal(g.str(uTp.name), "U");
        assert.equal(g.types[uTp.constraint].kind.tag, "number-type");
        assert.equal(g.types[uTp.defaultType].kind.tag, "number-type");

        const pDecl = findDecl(g, "P", "type-alias-decl", instMod.id);
        assert.ok(pDecl);
        const pSurfType = g.types[pDecl.kind.val];
        assert.notEqual(pSurfType.resolvedType, null, "Expected Pick<Box<string>, ...> to expand");
        const pResolved = g.types[pSurfType.resolvedType];
        assert.equal(pResolved.kind.tag, "object-literal");
        const pProps = new Map(
          pResolved.kind.val.properties.map((pid) => [g.str(g.properties[pid].name), g.properties[pid]]),
        );
        assert.equal(g.types[pProps.get("value").ty].kind.tag, "string-type");
        const getFnType = g.types[pProps.get("get").ty];
        assert.equal(getFnType.kind.tag, "function-type");
        const getFnSig = g.signatures[getFnType.kind.val];
        assert.equal(g.types[getFnSig.returnType].kind.tag, "string-type");

        // Test 5: `/b.d.ts` with `followReExports: false`
        const noFollowRes = ts.extractModuleGraph(program, {
          rootFiles: ["/b.d.ts"],
          followReExports: false,
          expandUtilityTypes: false,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(noFollowRes.ok, true);
        const ng = noFollowRes.value;
        const bMod = ng.modules.find((m) => ng.str(m.filePath) === "/b.d.ts");
        assert.ok(bMod);
        const bExports = new Map(
          bMod.exports.map((id) => {
            const d = ng.decls[id];
            assert.notEqual(d.exportName, null);
            return [ng.str(d.exportName), d];
          }),
        );
        assert.deepEqual(
          [...bExports.keys()].sort(),
          ["X", "Y", "eq", "ns", "z"],
          "Expected X, ns, z, eq, and Y all exported from /b.d.ts when followReExports=false",
        );

        const xReExp = bExports.get("X");
        assert.equal(xReExp.kind.tag, "re-export-decl");
        assert.equal(ng.str(xReExp.kind.val.moduleSpecifier), "./x");
        assert.equal(ng.str(xReExp.kind.val.sourceName), "X");
        assert.equal(xReExp.kind.val.targetDecl, null);
        assert.notEqual(xReExp.kind.val.targetModule, null);

        const nsReExp = bExports.get("ns");
        assert.equal(nsReExp.kind.tag, "re-export-decl");
        assert.equal(nsReExp.kind.val.isNamespace, true);
        assert.equal(ng.str(nsReExp.kind.val.sourceName), "*");
        assert.equal(nsReExp.kind.val.targetDecl, null);

        const zReExp = bExports.get("z");
        assert.equal(zReExp.kind.tag, "re-export-decl");
        assert.equal(ng.str(zReExp.kind.val.sourceName), "default");
        assert.equal(ng.str(zReExp.kind.val.exportAlias), "z");
        assert.equal(zReExp.kind.val.targetDecl, null);

        const eqReExp = bExports.get("eq");
        assert.equal(eqReExp.kind.tag, "re-export-decl");
        assert.equal(ng.str(eqReExp.kind.val.moduleSpecifier), "./cjs-dep");
        assert.equal(eqReExp.kind.val.targetDecl, null);
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("handles star re-exports of bare import re-exports, Required/Mutable mapped modifier removal, and export default of imported bindings with followReExports=false", () => {
    const vfs = ts.createVfs(true);
    try {
      // 1. `/lib/c.ts` -> `/lib/b.ts` (`import { C } from './c'; export { C }`) -> `/a.ts` (`export * from './lib/b'`)
      vfs.writeFile("/lib/c.ts", "export interface C { a: number }\n");
      vfs.writeFile("/lib/b.ts", "import { C } from './c';\nexport { C };\n");
      vfs.writeFile("/a.ts", "export * from './lib/b';\n");

      // 2. `Required<S>` (`-?`) and `Mutable<S>` (`-readonly`) with `expandUtilityTypes: true`
      vfs.writeFile(
        "/mapped-mods.ts",
        [
          "export interface S { readonly ro?: string; readonly keepRo: number; opt?: boolean }",
          "export type Req = Required<S>;",
          "export type Mut = { -readonly [K in keyof S]: S[K] };",
          "export type MutReq = { -readonly [K in keyof S]-?: S[K] };",
        ].join("\n"),
      );

      // 3. `export default D` & `export default q` of imported bindings with `followReExports: false`
      vfs.writeFile(
        "/def-c.ts",
        [
          "export const q = 1;",
          "export default class K { id = 0 }",
        ].join("\n"),
      );
      vfs.writeFile(
        "/def-a1.ts",
        [
          "import D from './def-c';",
          "export default D;",
        ].join("\n"),
      );
      vfs.writeFile(
        "/def-a2.ts",
        [
          "import { q } from './def-c';",
          "export default q;",
        ].join("\n"),
      );

      const progRes = ts.createProgram(
        vfs,
        ["/a.ts", "/mapped-mods.ts", "/def-a1.ts", "/def-a2.ts"],
        {
          target: "es2024",
          module: "esnext",
          moduleResolution: "bundler",
          strict: true,
        },
      );
      assert.equal(progRes.ok, true);
      const program = progRes.value;

      try {
        // Test 1 & 2 (`followReExports: true`, `expandUtilityTypes: true`)
        const res = ts.extractModuleGraph(program, {
          rootFiles: ["/a.ts", "/mapped-mods.ts"],
          followReExports: true,
          expandUtilityTypes: true,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(res.ok, true);
        const g = res.value;

        // Case 1: `/a.ts` must NOT emit a bogus `re-export-decl` with `moduleSpecifier: "./c"`!
        const aMod = g.modules.find((m) => g.str(m.filePath) === "/a.ts");
        assert.ok(aMod);
        assert.equal(aMod.starReExports.length, 1);
        for (const expId of aMod.exports) {
          const d = g.decls[expId];
          if (d.kind.tag === "re-export-decl") {
            assert.notEqual(
              g.str(d.kind.val.moduleSpecifier),
              "./c",
              "/a.ts must never inherit /lib/b.ts's relative './c' moduleSpecifier",
            );
          }
        }
        const cMod = g.modules.find((m) => g.str(m.filePath) === "/lib/c.ts");
        assert.ok(cMod);
        const cIface = findDecl(g, "C", "interface-decl", cMod.id);
        assert.ok(cIface);
        assert.ok(
          aMod.exports.includes(cIface.id),
          "Expected flattened star re-export in /a.ts to point directly to /lib/c.ts interface C",
        );

        const bMod = g.modules.find((m) => g.str(m.filePath) === "/lib/b.ts");
        assert.ok(bMod);
        const bExp = g.decls[bMod.exports[0]];
        assert.equal(bExp.kind.tag, "re-export-decl");
        assert.equal(g.str(bExp.kind.val.moduleSpecifier), "./c");
        assert.equal(bExp.kind.val.targetDecl, cIface.id);

        // Case 2: `Required<S>`, `Mutable<S>`, and `MutReq` clear `OptionalMod` / `ReadonlyMod`
        const mappedMod = g.modules.find((m) => g.str(m.filePath) === "/mapped-mods.ts");
        assert.ok(mappedMod);
        const getResolvedProps = (aliasName) => {
          const aliasDecl = findDecl(g, aliasName, "type-alias-decl", mappedMod.id);
          assert.ok(aliasDecl);
          const surfTy = g.types[aliasDecl.kind.val];
          assert.notEqual(surfTy.resolvedType, null);
          const resolvedTy = g.types[surfTy.resolvedType];
          assert.equal(resolvedTy.kind.tag, "object-literal");
          return new Map(
            resolvedTy.kind.val.properties.map((pid) => [
              g.str(g.properties[pid].name),
              g.properties[pid],
            ]),
          );
        };

        const reqProps = getResolvedProps("Req");
        assert.equal(reqProps.get("ro").modifiers & MODIFIER_FLAGS.optionalMod, 0, "Req.ro must clear OptionalMod");
        assert.notEqual(reqProps.get("ro").modifiers & MODIFIER_FLAGS.readonlyMod, 0, "Req.ro must keep ReadonlyMod");
        assert.equal(g.types[reqProps.get("ro").ty].kind.tag, "string-type");
        assert.equal(reqProps.get("opt").modifiers & MODIFIER_FLAGS.optionalMod, 0, "Req.opt must clear OptionalMod");

        const mutProps = getResolvedProps("Mut");
        assert.equal(mutProps.get("ro").modifiers & MODIFIER_FLAGS.readonlyMod, 0, "Mut.ro must clear ReadonlyMod");
        assert.notEqual(mutProps.get("ro").modifiers & MODIFIER_FLAGS.optionalMod, 0, "Mut.ro must keep OptionalMod");
        assert.equal(mutProps.get("keepRo").modifiers & MODIFIER_FLAGS.readonlyMod, 0, "Mut.keepRo must clear ReadonlyMod");

        const mutReqProps = getResolvedProps("MutReq");
        assert.equal(mutReqProps.get("ro").modifiers & MODIFIER_FLAGS.readonlyMod, 0);
        assert.equal(mutReqProps.get("ro").modifiers & MODIFIER_FLAGS.optionalMod, 0);

        // Test 3: `export default D` and `export default q` with `followReExports: false`
        const defRes = ts.extractModuleGraph(program, {
          rootFiles: ["/def-a1.ts", "/def-a2.ts"],
          followReExports: false,
          expandUtilityTypes: false,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(defRes.ok, true);
        const dg = defRes.value;

        const a1Mod = dg.modules.find((m) => dg.str(m.filePath) === "/def-a1.ts");
        assert.ok(a1Mod);
        assert.notEqual(a1Mod.defaultExport, null);
        const a1Def = dg.decls[a1Mod.defaultExport];
        assert.equal(a1Def.module, a1Mod.id);
        assert.equal(a1Def.kind.tag, "re-export-decl");
        assert.equal(dg.str(a1Def.name), "default");
        assert.equal(dg.str(a1Def.exportName), "default");
        assert.equal(dg.str(a1Def.kind.val.moduleSpecifier), "./def-c");
        assert.equal(dg.str(a1Def.kind.val.sourceName), "default");
        assert.equal(a1Def.kind.val.targetDecl, null);

        const a2Mod = dg.modules.find((m) => dg.str(m.filePath) === "/def-a2.ts");
        assert.ok(a2Mod);
        assert.notEqual(a2Mod.defaultExport, null);
        const a2Def = dg.decls[a2Mod.defaultExport];
        assert.equal(a2Def.module, a2Mod.id);
        assert.equal(a2Def.kind.tag, "re-export-decl");
        assert.equal(dg.str(a2Def.name), "default");
        assert.equal(dg.str(a2Def.exportName), "default");
        assert.equal(dg.str(a2Def.kind.val.moduleSpecifier), "./def-c");
        assert.equal(dg.str(a2Def.kind.val.sourceName), "q");
        assert.equal(dg.str(a2Def.kind.val.exportAlias), "default");
        assert.equal(a2Def.kind.val.targetDecl, null);

        const defCMod = dg.modules.find((m) => dg.str(m.filePath) === "/def-c.ts");
        assert.ok(defCMod);
        assert.equal(
          defCMod.exports.length,
          0,
          "followReExports=false must not extract /def-c.ts exports",
        );
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("extracts named export default class/function/interface directly without bogus re-exports and handles dual default+named exports", () => {
    const vfs = ts.createVfs(true);
    try {
      vfs.writeFile(
        "/def-class.ts",
        [
          "export interface UsesK { k: K }",
          "export default class K { x: number = 1 }",
        ].join("\n"),
      );
      vfs.writeFile(
        "/def-fn.ts",
        "export default function f(): void {}\n",
      );
      vfs.writeFile(
        "/def-iface.ts",
        "export default interface I { y: string }\n",
      );
      vfs.writeFile(
        "/def-both.ts",
        [
          "export default class Both { z: boolean = true }",
          "export { Both };",
        ].join("\n"),
      );

      const roots = ["/def-class.ts", "/def-fn.ts", "/def-iface.ts", "/def-both.ts"];
      const progRes = ts.createProgram(vfs, roots, {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      });
      assert.equal(progRes.ok, true);
      const program = progRes.value;

      try {
        const res = ts.extractModuleGraph(program, {
          rootFiles: roots,
          followReExports: true,
          expandUtilityTypes: false,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(res.ok, true);
        const g = res.value;

        const getMod = (fp) => {
          const m = g.modules.find((mod) => g.str(mod.filePath) === fp);
          assert.ok(m, `Expected module ${fp}`);
          return m;
        };

        // 1. `export default class K` -> `defaultExport` points directly to `class-decl` (`name = "K"`, `exportName = "default"`), zero `re-export-decl`, `"K"` NOT in `exports`!
        const clsMod = getMod("/def-class.ts");
        assert.notEqual(clsMod.defaultExport, null);
        const kDecl = g.decls[clsMod.defaultExport];
        assert.equal(kDecl.kind.tag, "class-decl");
        assert.equal(g.str(kDecl.name), "K");
        assert.equal(g.str(kDecl.exportName), "default");
        assert.deepEqual(
          clsMod.exports.map((id) => g.str(g.decls[id].exportName)),
          ["UsesK"],
          "Must not leak 'K' into named exports or emit bogus re-export-decl",
        );
        assert.equal(
          g.decls.filter((d) => d.module === clsMod.id && d.kind.tag === "re-export-decl").length,
          0,
        );

        // 2. `export default function f` -> `defaultExport` points directly to `function-decl` (`name = "f"`, `exportName = "default"`)
        const fnMod = getMod("/def-fn.ts");
        assert.notEqual(fnMod.defaultExport, null);
        const fDecl = g.decls[fnMod.defaultExport];
        assert.equal(fDecl.kind.tag, "function-decl");
        assert.equal(g.str(fDecl.name), "f");
        assert.equal(g.str(fDecl.exportName), "default");
        assert.equal(fnMod.exports.length, 0);
        assert.equal(
          g.decls.filter((d) => d.module === fnMod.id && d.kind.tag === "re-export-decl").length,
          0,
        );

        // 3. `export default interface I` -> `defaultExport` points directly to `interface-decl` (`name = "I"`, `exportName = "default"`)
        const ifMod = getMod("/def-iface.ts");
        assert.notEqual(ifMod.defaultExport, null);
        const iDecl = g.decls[ifMod.defaultExport];
        assert.equal(iDecl.kind.tag, "interface-decl");
        assert.equal(g.str(iDecl.name), "I");
        assert.equal(g.str(iDecl.exportName), "default");
        assert.equal(ifMod.exports.length, 0);
        assert.equal(
          g.decls.filter((d) => d.module === ifMod.id && d.kind.tag === "re-export-decl").length,
          0,
        );

        // 4. `export default class Both {}; export { Both };` -> exports BOTH `default` (direct `class-decl`) and `"Both"` (in `exports` targeting `Both`)!
        const bothMod = getMod("/def-both.ts");
        assert.notEqual(bothMod.defaultExport, null);
        const bothDefDecl = g.decls[bothMod.defaultExport];
        assert.equal(bothDefDecl.kind.tag, "class-decl");
        assert.equal(g.str(bothDefDecl.name), "Both");
        assert.equal(g.str(bothDefDecl.exportName), "default");
        assert.equal(bothMod.exports.length, 1);
        const bothNamedDecl = g.decls[bothMod.exports[0]];
        assert.equal(g.str(bothNamedDecl.exportName), "Both");
        assert.equal(bothNamedDecl.kind.tag, "re-export-decl");
        assert.equal(bothNamedDecl.kind.val.targetDecl, bothDefDecl.id);
        assert.equal(g.str(bothNamedDecl.kind.val.sourceName), "Both");
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("handles Issue #45 M2.2c adversarial cases: H1 merged namespace self-export, H4 ambient export=/default, and M2 private constructors & brand", () => {
    const vfs = ts.createVfs(true);
    try {
      vfs.writeFile(
        "/h1-merged.d.ts",
        [
          "interface OuterUnexported { hidden: number }",
          "export declare class EventEmitter {",
          "  emit(event: string): boolean;",
          "}",
          "export declare namespace EventEmitter {",
          "  export { EventEmitter, EventEmitter as EEAlias, OuterUnexported as InnerExposed };",
          "  export interface Abortable { signal?: boolean }",
          "}",
          "export declare namespace OuterNs {",
          "  export const x: number;",
          "  export namespace InnerNs {",
          "    export { OuterNs };",
          "  }",
          "}",
          "export {};",
        ].join("\n"),
      );
      vfs.writeFile(
        "/h4-ambient.d.ts",
        [
          'declare module "node:events" {',
          "  class EventEmitter<T = any> { on(ev: string): this; }",
          "  interface EventEmitter<T = any> { emit(ev: string): boolean; }",
          "  namespace EventEmitter {",
          "    export { EventEmitter };",
          "    export function once(ee: EventEmitter): Promise<unknown[]>;",
          "  }",
          "  export = EventEmitter;",
          "}",
          'declare module "node:path" {',
          "  namespace path {",
          "    export function join(...p: string[]): string;",
          "    export const sep: string;",
          "  }",
          "  export = path;",
          "}",
          'declare module "virtual:def" {',
          "  export default class DefService { run(): void; }",
          "}",
        ].join("\n"),
      );
      vfs.writeFile(
        "/m2-private.ts",
        [
          "interface SecretHelper { key: string }",
          "export class Singleton {",
          "  private secret?: SecretHelper;",
          "  #brand: boolean = true;",
          "  private constructor(token: string) {}",
          '  static instance(): Singleton { return new Singleton("ok"); }',
          "}",
          "export class ProtectedBase {",
          "  protected constructor(id: number) {}",
          "}",
        ].join("\n"),
      );

      const roots = ["/h1-merged.d.ts", "/h4-ambient.d.ts", "/m2-private.ts"];
      const progRes = ts.createProgram(vfs, roots, {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      });
      assert.equal(progRes.ok, true);
      const program = progRes.value;

      try {
        const res = ts.extractModuleGraph(program, {
          rootFiles: roots,
          followReExports: true,
          expandUtilityTypes: false,
          includeJsdoc: false,
          includePrivateMembers: false,
        });
        assert.equal(res.ok, true);
        const g = res.value;

        const getMod = (fp) => {
          const m = g.modules.find((mod) => g.str(mod.filePath) === fp);
          assert.ok(m, `Expected module ${fp}`);
          return m;
        };

        // --- H1: Merged class+namespace re-exporting itself + outer unexported decl ---
        const h1Mod = getMod("/h1-merged.d.ts");
        const h1Decls = g.decls.filter((d) => d.module === h1Mod.id);
        const eeCls = h1Decls.find((d) => g.str(d.name) === "EventEmitter" && d.kind.tag === "class-decl");
        const eeNs = h1Decls.find((d) => g.str(d.name) === "EventEmitter" && d.kind.tag === "namespace-decl");
        const outerHidden = h1Decls.find((d) => g.str(d.name) === "OuterUnexported" && d.kind.tag === "interface-decl");
        assert.ok(eeCls && eeNs && outerHidden);

        const nsChildren = eeNs.kind.val;
        assert.ok(!nsChildren.includes(eeNs.id), "H1: namespace must never contain its own decl_id");
        assert.ok(!nsChildren.includes(eeCls.id), "H1: namespace must not contain merged peer class decl_id directly");
        assert.ok(!nsChildren.includes(outerHidden.id), "H1: namespace must not steal outer unexported decl_id directly");
        assert.equal(outerHidden.exportName, null, "H1: outer unexported decl must keep exportName === null");
        assert.equal(outerHidden.modifiers & MODIFIER_FLAGS.exportDecl, 0, "H1: outer unexported decl must not gain exportDecl");

        const selfReExport = nsChildren
          .map((id) => g.decls[id])
          .find((d) => d.kind.tag === "re-export-decl" && g.str(d.name) === "EventEmitter");
        assert.ok(selfReExport, "H1: expected namespace-scoped re-export-decl for EventEmitter");
        assert.equal(selfReExport.kind.val.targetDecl, eeCls.id);

        const outerNs = h1Decls.find((d) => g.str(d.name) === "OuterNs" && d.kind.tag === "namespace-decl");
        const innerNs = outerNs.kind.val
          .map((id) => g.decls[id])
          .find((d) => g.str(d.name) === "InnerNs" && d.kind.tag === "namespace-decl");
        assert.ok(outerNs && innerNs);
        assert.ok(!innerNs.kind.val.includes(outerNs.id), "H1: nested namespace must not create ancestor cycle");
        assert.ok(!innerNs.kind.val.includes(innerNs.id), "H1: nested namespace must not self-cycle");

        // --- H4: ambient-module-node exportEquals & defaultExport ---
        const h4Mod = getMod("/h4-ambient.d.ts");
        const getAmb = (name) => {
          const amb = h4Mod.ambientModules.find((a) => g.str(a.moduleName) === name);
          assert.ok(amb, `Expected ambient module ${name}`);
          return amb;
        };

        const ambEvents = getAmb("node:events");
        assert.notEqual(ambEvents.exportEquals, null, "H4: node:events must populate exportEquals");
        const ambEventsKinds = new Set(ambEvents.decls.map((id) => g.decls[id].kind.tag));
        assert.ok(ambEventsKinds.has("class-decl"), "H4: node:events decls must include merged class EventEmitter");
        assert.ok(ambEventsKinds.has("interface-decl"), "H4: node:events decls must include merged interface EventEmitter");
        assert.ok(ambEventsKinds.has("namespace-decl"), "H4: node:events decls must include merged namespace EventEmitter");

        const ambPath = getAmb("node:path");
        assert.notEqual(ambPath.exportEquals, null, "H4: node:path must populate exportEquals");
        assert.equal(g.decls[ambPath.exportEquals].kind.tag, "namespace-decl");

        const ambDef = getAmb("virtual:def");
        assert.notEqual(ambDef.defaultExport, null, "H4: virtual:def must populate defaultExport");
        assert.equal(g.decls[ambDef.defaultExport].kind.tag, "class-decl");

        // --- M2: private/protected constructors & #private brand marker ---
        const m2Mod = getMod("/m2-private.ts");
        const m2Decls = g.decls.filter((d) => d.module === m2Mod.id);
        const singletonCls = m2Decls.find((d) => g.str(d.name) === "Singleton" && d.kind.tag === "class-decl");
        const protectedCls = m2Decls.find((d) => g.str(d.name) === "ProtectedBase" && d.kind.tag === "class-decl");
        assert.ok(singletonCls && protectedCls);

        assert.equal(singletonCls.kind.val.constructors.length, 1, "M2: private constructor must be preserved");
        const privCtorSig = g.signatures[singletonCls.kind.val.constructors[0]];
        assert.notEqual(privCtorSig.modifiers & MODIFIER_FLAGS.privateMod, 0, "M2: privateMod must be set on private constructor");

        assert.equal(protectedCls.kind.val.constructors.length, 1, "M2: protected constructor must be preserved");
        const protCtorSig = g.signatures[protectedCls.kind.val.constructors[0]];
        assert.notEqual(protCtorSig.modifiers & MODIFIER_FLAGS.protectedMod, 0, "M2: protectedMod must be set on protected constructor");

        const brandProps = singletonCls.kind.val.properties
          .map((pid) => g.properties[pid])
          .filter((p) => (p.modifiers & MODIFIER_FLAGS.privateMod) !== 0);
        assert.equal(brandProps.length, 1, "M2: expected lightweight #private brand marker when includePrivateMembers=false");
        assert.equal(g.str(brandProps[0].name), "#private");
        assert.equal(g.types[brandProps[0].ty].kind.tag, "any-type", "M2: brand marker must use any-type without pulling private helper types");
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });
});
