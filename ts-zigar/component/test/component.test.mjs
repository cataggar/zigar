import assert from "node:assert/strict";
import path from "node:path";
import { describe, it, before } from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

import {
  instantiateTypeScriptComponent,
  sliceMemoryU8,
  toUnsignedPtr,
  wrapWasiImportsUnsigned,
} from "./wasi-component-runner.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const defaultWasmPath = path.resolve(
  __dirname,
  "..",
  "dist",
  "typescript-compiler.component.wasm",
);
const wasmPath = process.env.TS_ZIGAR_COMPONENT_WASM
  ? path.resolve(process.env.TS_ZIGAR_COMPONENT_WASM)
  : defaultWasmPath;

describe("WASI & Canonical ABI >= 2 GiB (0x8000_0000) unsigned pointer safety", () => {
  it("converts negative signed i32 pointers (>= 2 GiB) via >>> 0 without RangeError", () => {
    // 0x8000_0000 as signed i32 is -2147483648
    const signedTwoGiB = 0x8000_0000 | 0;
    assert.equal(signedTwoGiB, -2147483648);
    assert.equal(toUnsignedPtr(signedTwoGiB), 0x8000_0000);
    assert.equal(toUnsignedPtr(signedTwoGiB), 2147483648);

    // 0xffff_fff0 as signed i32 is -16
    const signedNearFourGiB = 0xffff_fff0 | 0;
    assert.equal(signedNearFourGiB, -16);
    assert.equal(toUnsignedPtr(signedNearFourGiB), 0xffff_fff0);
    assert.equal(toUnsignedPtr(-1), 0xffff_ffff);
  });

  it("wraps WASI preview1 syscalls so >= 2 GiB pointer args arrive as unsigned u32", () => {
    const capturedCalls = [];
    const mockRawWasi = {
      fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
        capturedCalls.push({ fn: "fd_write", fd, iovsPtr, iovsLen, nwrittenPtr });
        assert.ok(iovsPtr >= 0, "iovsPtr must not be negative");
        assert.ok(nwrittenPtr >= 0, "nwrittenPtr must not be negative");
        return 0;
      },
      clock_time_get(clockId, precisionBigInt, timePtr) {
        capturedCalls.push({ fn: "clock_time_get", clockId, precisionBigInt, timePtr });
        assert.equal(typeof precisionBigInt, "bigint");
        assert.ok(timePtr >= 0, "timePtr must not be negative");
        return 0;
      },
    };

    const wrapped = wrapWasiImportsUnsigned(mockRawWasi);
    assert.equal(typeof wrapped["fd_write [v2]"], "function");
    assert.equal(typeof wrapped.adapter_monotonic_clock_set_paused, "function");

    // Simulate Wasm passing i32 pointers at 0x8000_0000 (-2147483648) and 0x8000_0030 (-2147483600)
    wrapped.fd_write(1, 0x8000_0000 | 0, 2, 0x8000_0030 | 0);
    wrapped["fd_write [v2]"](2, 0x9000_1000 | 0, 1, 0x9000_1010 | 0);
    wrapped.clock_time_get(1, 1000n, 0xa000_0000 | 0);

    assert.equal(capturedCalls.length, 3);
    assert.deepEqual(capturedCalls[0], {
      fn: "fd_write",
      fd: 1,
      iovsPtr: 0x8000_0000,
      iovsLen: 2,
      nwrittenPtr: 0x8000_0030,
    });
    assert.deepEqual(capturedCalls[1], {
      fn: "fd_write",
      fd: 2,
      iovsPtr: 0x9000_1000,
      iovsLen: 1,
      nwrittenPtr: 0x9000_1010,
    });
    assert.deepEqual(capturedCalls[2], {
      fn: "clock_time_get",
      clockId: 1,
      precisionBigInt: 1000n,
      timePtr: 0xa000_0000,
    });
  });

  it("slices a > 2 GiB WebAssembly.Memory at signed i32 offset -2147483648 (0x8000_0000)", () => {
    // 32,769 pages * 64 KiB = 2 GiB + 64 KiB
    const largeMem = new WebAssembly.Memory({ initial: 32769, maximum: 32770 });
    const signedOffset = 0x8000_0000 | 0; // -2147483648 as signed i32
    assert.equal(signedOffset, -2147483648);

    // Direct `new Uint8Array(largeMem.buffer, signedOffset, 5)` throws RangeError in JS,
    // whereas `sliceMemoryU8` converts via `>>> 0` and succeeds cleanly.
    assert.throws(() => new Uint8Array(largeMem.buffer, signedOffset, 5), RangeError);

    const payload = new TextEncoder().encode("zigar-2gib-ok");
    const writeSlice = sliceMemoryU8(largeMem.buffer, signedOffset, payload.byteLength);
    writeSlice.set(payload);

    const readBack = new TextDecoder().decode(
      sliceMemoryU8(largeMem.buffer, signedOffset, payload.byteLength),
    );
    assert.equal(readBack, "zigar-2gib-ok");
  });
});

describe("TypeScript 7.1-next Go WASM Component (zigar:typescript@7.1.0)", () => {
  let ts;

  before(() => {
    ts = instantiateTypeScriptComponent(wasmPath);
  });

  it("exposes expected component interfaces and reports TypeScript 7.1 compiler-version()", () => {
    assert.ok(ts.componentExports.includes("zigar:typescript/types@7.1.0"));
    assert.ok(ts.componentExports.includes("zigar:typescript/compiler@7.1.0"));
    assert.ok(ts.componentExports.includes("zigar:typescript/extractor@7.1.0"));

    const version = ts.compilerVersion();
    assert.match(version, /^7\.1\./);
  });

  it("supports resource vfs CRUD operations and bundled lib.*.d.ts mounting", () => {
    const vfsNoLibs = ts.createVfs(false);
    try {
      assert.equal(vfsNoLibs.fileExists("/index.ts"), false);
      assert.equal(vfsNoLibs.readFile("/index.ts"), null);

      vfsNoLibs.writeFile("/src/a.ts", "export const a = 1;\n");
      vfsNoLibs.writeFile("/src/b.ts", "export const b = 2;\n");

      assert.equal(vfsNoLibs.fileExists("/src/a.ts"), true);
      assert.equal(vfsNoLibs.readFile("/src/a.ts"), "export const a = 1;\n");
      assert.deepEqual(vfsNoLibs.listFiles("/src"), ["/src/a.ts", "/src/b.ts"]);

      assert.equal(vfsNoLibs.deleteFile("/src/a.ts"), true);
      assert.equal(vfsNoLibs.deleteFile("/src/a.ts"), false);
      assert.equal(vfsNoLibs.fileExists("/src/a.ts"), false);
      assert.deepEqual(vfsNoLibs.listFiles("/src"), ["/src/b.ts"]);
    } finally {
      vfsNoLibs.drop();
    }
  });

  it("reports semantic diagnostics with accurate source spans using bundled libs", () => {
    const vfs = ts.createVfs(true);
    try {
      const brokenSource = [
        "export interface User { id: number; name: string; }",
        'export function greet(u: User) { return "hi " + u.name; }',
        'const bad: number = "oops";',
        "",
      ].join("\n");

      vfs.writeFile("/index.ts", brokenSource);
      const progRes = ts.createProgram(vfs, ["/index.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        assert.deepEqual(program.getRootFiles(), ["/index.ts"]);
        assert.deepEqual(program.getSyntacticDiagnostics(), []);

        const semDiags = program.getSemanticDiagnostics("/index.ts");
        assert.equal(semDiags.length, 1);
        const [diag] = semDiags;
        assert.equal(diag.code, 2322);
        assert.equal(diag.category, "error");
        assert.match(diag.message, /Type 'string' is not assignable to type 'number'/);
        assert.ok(diag.span);
        assert.equal(diag.span.fileName, "/index.ts");
        assert.equal(diag.span.line, 3);
        assert.ok(diag.span.column >= 1);
        assert.equal(
          brokenSource.slice(diag.span.start, diag.span.start + diag.span.length),
          "bad",
        );
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("resolves types, symbols, module exports, and emits .d.ts declarations on a clean program", () => {
    const vfs = ts.createVfs(true);
    try {
      const cleanSource = [
        "export interface User {",
        "  id: number;",
        "  name: string;",
        "}",
        "",
        "/** Greets a user by name. */",
        "export function greet(u: User) {",
        '  return "hi " + u.name;',
        "}",
        "",
      ].join("\n");

      vfs.writeFile("/index.ts", cleanSource);
      const progRes = ts.createProgram(vfs, ["/index.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
        declaration: true,
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        assert.deepEqual(program.getSyntacticDiagnostics(), []);
        assert.deepEqual(program.getSemanticDiagnostics(), []);
        assert.deepEqual(program.getGlobalDiagnostics(), []);

        const greetOffset = Buffer.byteLength(
          cleanSource.slice(0, cleanSource.indexOf("greet(")),
          "utf8",
        );

        const checker = program.getChecker();
        try {
          const typeStr = checker.typeToString("/index.ts", greetOffset);
          assert.equal(typeStr, "(u: User) => string");

          const typeInfo = checker.inspectTypeAt("/index.ts", greetOffset);
          assert.ok(typeInfo);
          assert.equal(typeInfo.typeText, "(u: User) => string");
          assert.ok(typeInfo.typeFlags > 0);
          assert.equal(typeInfo.isUnion, false);

          const symInfo = checker.inspectSymbolAt("/index.ts", greetOffset);
          assert.ok(symInfo);
          assert.equal(symInfo.name, "greet");
          assert.equal(symInfo.typeText, "(u: User) => string");
          assert.match(symInfo.documentation ?? "", /Greets a user by name/);
          assert.ok(symInfo.declarationSpan);
          assert.equal(symInfo.declarationSpan.fileName, "/index.ts");

          const exportsList = checker.resolveModuleExports("/index.ts");
          const exportNames = exportsList.map((s) => s.name).sort();
          assert.deepEqual(exportNames, ["User", "greet"]);
        } finally {
          checker.drop();
        }

        // Verify .d.ts declaration emit in memory
        const emitRes = program.emitDeclarations();
        assert.equal(emitRes.emitSkipped, false);
        assert.deepEqual(emitRes.diagnostics, []);
        const dtsFile = emitRes.outputFiles.find((f) => f.fileName === "/index.d.ts");
        assert.ok(dtsFile, "Expected /index.d.ts in emit output");
        assert.match(dtsFile.contents, /export interface User/);
        assert.match(dtsFile.contents, /export declare function greet\(u: User\): string;/);

        // Verify modular extractor interface wiring
        const graphRes = ts.extractModuleGraph(program, { rootFiles: ["/index.ts"] });
        assert.equal(graphRes.ok, true);
        assert.equal(graphRes.value.modulesLen, 1);
        assert.equal(graphRes.value.entryModules.length, 1);
        assert.ok(graphRes.value.strings.includes("/index.ts"));
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("transpiles single-file TypeScript modules to executable JavaScript via transpile-module", () => {
    const tsCode = [
      "interface Point { x: number; y: number }",
      "export function normSq(p: Point): number {",
      "  return p.x * p.x + p.y * p.y;",
      "}",
    ].join("\n");

    const res = ts.transpileModule(tsCode, "/point.ts");
    assert.equal(res.emitSkipped, false);
    assert.deepEqual(res.diagnostics, []);
    const jsFile = res.outputFiles.find((f) => f.fileName.endsWith(".js"));
    assert.ok(jsFile, "Expected emitted .js file");
    assert.ok(!jsFile.contents.includes("interface Point"));

    // Strip `export ` to evaluate function body directly in Node VM
    const runnable = `${jsFile.contents.replace(/^export\s+/gm, "")}\nnormSq({ x: 3, y: 4 });`;
    const result = vm.runInNewContext(runnable);
    assert.equal(result, 25);
  });

  it("supports multi-file imports, ES2024 bundled lib globals, and syntactic/error edge cases", () => {
    const vfs = ts.createVfs(true);
    try {
      vfs.writeFile(
        "/models.ts",
        "export interface Item { readonly sku: string; price: number }\n",
      );
      const serviceSource = [
        'import type { Item } from "./models";',
        "export async function indexBySku(items: Item[]): Promise<Map<string, Item>> {",
        "  return new Map(items.map((it) => [it.sku, it]));",
        "}",
        "",
      ].join("\n");
      vfs.writeFile("/service.ts", serviceSource);

      const progRes = ts.createProgram(vfs, ["/service.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
        declaration: true,
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        assert.deepEqual(program.getSemanticDiagnostics(), []);
        assert.deepEqual(program.getGlobalDiagnostics(), []);

        const checker = program.getChecker();
        try {
          const fnOffset = Buffer.byteLength(
            serviceSource.slice(0, serviceSource.indexOf("indexBySku(")),
            "utf8",
          );
          assert.equal(
            checker.typeToString("/service.ts", fnOffset),
            "(items: Item[]) => Promise<Map<string, Item>>",
          );
          // Relative specifier resolution via program resolved modules
          const modelExports = checker.resolveModuleExports("./models");
          assert.deepEqual(modelExports.map((e) => e.name), ["Item"]);
        } finally {
          checker.drop();
        }

        const singleEmit = program.emitDeclarations("/service.ts");
        assert.equal(singleEmit.emitSkipped, false);
        assert.equal(singleEmit.outputFiles.length, 1);
        assert.equal(singleEmit.outputFiles[0].fileName, "/service.d.ts");
        assert.match(
          singleEmit.outputFiles[0].contents,
          /export declare function indexBySku\(items: Item\[\]\): Promise<Map<string, Item>>;/,
        );

        // Missing entry module in extractor returns structured diagnostic error
        const badGraph = ts.extractModuleGraph(program, { rootFiles: ["/does-not-exist.ts"] });
        assert.equal(badGraph.ok, false);
        assert.ok(badGraph.error.length >= 1);
      } finally {
        program.drop();
      }

      // Syntactic error reporting + empty root-files rejection
      vfs.writeFile("/broken-syntax.ts", "export const x: = ;\n");
      const synProgRes = ts.createProgram(vfs, ["/broken-syntax.ts"], { strict: true });
      assert.equal(synProgRes.ok, true);
      try {
        const synDiags = synProgRes.value.getSyntacticDiagnostics("/broken-syntax.ts");
        assert.ok(synDiags.length >= 1);
        assert.equal(synDiags[0].category, "error");
        assert.equal(synDiags[0].span?.fileName, "/broken-syntax.ts");
      } finally {
        synProgRes.value.drop();
      }

      const emptyRootsRes = ts.createProgram(vfs, [], { strict: true });
      assert.equal(emptyRootsRes.ok, false);
      assert.ok(emptyRootsRes.error.length >= 1);
    } finally {
      vfs.drop();
    }
  });

  it("returns null on keywords, punctuation, trivia, and EOF while preserving literal types without leaking enclosing symbols", () => {
    const vfs = ts.createVfs(true);
    try {
      const source = [
        "// leading comment",
        "export function greet(u: { name: string }) {",
        '  return "hi " + u.name;',
        "}",
        "const z = 5;",
      ].join("\n");

      vfs.writeFile("/offsets.ts", source);
      const progRes = ts.createProgram(vfs, ["/offsets.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        const checker = program.getChecker();
        try {
          const byteOffsetOf = (needle) => {
            const idx = source.indexOf(needle);
            assert.notEqual(idx, -1, `missing needle: ${needle}`);
            return Buffer.byteLength(source.slice(0, idx), "utf8");
          };

          // Keywords, punctuation, trivia, EOF, and out-of-bounds must return null across all 3 methods
          const nonSemanticPositions = [
            ["comment trivia", byteOffsetOf("// leading")],
            ["export keyword", byteOffsetOf("export function")],
            ["space trivia", byteOffsetOf(" function greet")],
            ["function keyword", byteOffsetOf("function greet")],
            ["open paren right after greet", byteOffsetOf("(u:")],
            ["function body open brace", byteOffsetOf("{\n  return")],
            ["return keyword", byteOffsetOf("return ")],
            ["EOF (offset == source.length)", Buffer.byteLength(source, "utf8")],
            ["past EOF", Buffer.byteLength(source, "utf8") + 16],
          ];

          for (const [label, offset] of nonSemanticPositions) {
            assert.equal(
              checker.typeToString("/offsets.ts", offset),
              null,
              `typeToString should be null at ${label} (offset ${offset})`,
            );
            assert.equal(
              checker.inspectTypeAt("/offsets.ts", offset),
              null,
              `inspectTypeAt should be null at ${label} (offset ${offset})`,
            );
            assert.equal(
              checker.inspectSymbolAt("/offsets.ts", offset),
              null,
              `inspectSymbolAt should be null at ${label} (offset ${offset})`,
            );
          }

          // Initializer literal `5` in `const z = 5;`:
          // - `typeToString` and `inspectTypeAt` report literal/number type `5`
          // - `inspectSymbolAt` returns `null` (must NOT leak enclosing declaration `z`)
          const fiveOffset = byteOffsetOf("5;");
          assert.equal(checker.typeToString("/offsets.ts", fiveOffset), "5");
          const fiveType = checker.inspectTypeAt("/offsets.ts", fiveOffset);
          assert.ok(fiveType, "inspectTypeAt on literal 5 should return type-info");
          assert.equal(fiveType.typeText, "5");
          assert.ok(fiveType.typeFlags > 0);
          assert.equal(checker.inspectSymbolAt("/offsets.ts", fiveOffset), null);

          // Declaration name `z` itself still resolves both symbol `z` and literal type `5`
          const zOffset = byteOffsetOf("z = 5;");
          assert.equal(checker.typeToString("/offsets.ts", zOffset), "5");
          const zSym = checker.inspectSymbolAt("/offsets.ts", zOffset);
          assert.ok(zSym, "inspectSymbolAt on declaration name z should return symbol-info");
          assert.equal(zSym.name, "z");
        } finally {
          checker.drop();
        }
      } finally {
        program.drop();
      }
    } finally {
      vfs.drop();
    }
  });

  it("resolves `this` type annotations, instance/static `this` expressions, and `super` expressions accurately", () => {
    const vfs = ts.createVfs(true);
    try {
      const source = [
        "export interface Bar { tag: string }",
        "export class Foo {",
        "  n: number = 1;",
        "  static sn: string = 'ok';",
        "  m(): this {",
        "    return this;",
        "  }",
        "  mt(): typeof this {",
        "    return this;",
        "  }",
        "  mn(): typeof this.n {",
        "    return this.n;",
        "  }",
        "  static s() {",
        "    return this;",
        "  }",
        "  static smt(): typeof this {",
        "    return this;",
        "  }",
        "  static smn(): typeof this.sn {",
        "    return this.sn;",
        "  }",
        "  static p(this: Bar): typeof this {",
        "    return this;",
        "  }",
        "}",
        "export class B extends Foo {",
        "  q() {",
        "    return super.m();",
        "  }",
        "}",
        "export const typedObj: { a: number; m(): unknown } = {",
        "  a: 1,",
        "  m() {",
        "    let y: typeof this = this;",
        "    return y;",
        "  },",
        "};",
        "",
      ].join("\n");

      vfs.writeFile("/this-super.ts", source);
      const progRes = ts.createProgram(vfs, ["/this-super.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: true,
      });
      assert.equal(progRes.ok, true);

      const program = progRes.value;
      try {
        assert.deepEqual(program.getSemanticDiagnostics(), []);

        const checker = program.getChecker();
        try {
          const byteOffsetOf = (needle, tokenWithinNeedle = "") => {
            const baseIdx = source.indexOf(needle);
            assert.notEqual(baseIdx, -1, `missing needle: ${needle}`);
            const subIdx = tokenWithinNeedle ? needle.indexOf(tokenWithinNeedle) : 0;
            assert.notEqual(subIdx, -1, `missing token ${tokenWithinNeedle} in ${needle}`);
            return Buffer.byteLength(source.slice(0, baseIdx + subIdx), "utf8");
          };

          // 1. `: this` return type annotation in `m(): this` -> `"this"` (NOT `"typeof Foo"`)
          const thisTypeOffset = byteOffsetOf("m(): this", "this");
          assert.equal(checker.typeToString("/this-super.ts", thisTypeOffset), "this");
          assert.equal(checker.inspectTypeAt("/this-super.ts", thisTypeOffset)?.typeText, "this");
          assert.equal(checker.inspectSymbolAt("/this-super.ts", thisTypeOffset)?.typeText, "this");

          // 2. `return this;` in instance method `m()` -> `"this"`
          const instThisOffset = byteOffsetOf("m(): this {\n    return this;", "return this;") + "return ".length;
          assert.equal(checker.typeToString("/this-super.ts", instThisOffset), "this");
          assert.equal(checker.inspectTypeAt("/this-super.ts", instThisOffset)?.typeText, "this");
          assert.equal(checker.inspectSymbolAt("/this-super.ts", instThisOffset)?.typeText, "this");

          // 3. `typeof this` and `typeof this.n` in instance methods -> `"this"` on `this` (and `"number"` on `n`)
          const instTypeofThisOffset = byteOffsetOf("mt(): typeof this", "this");
          assert.equal(checker.typeToString("/this-super.ts", instTypeofThisOffset), "this");
          assert.equal(checker.inspectTypeAt("/this-super.ts", instTypeofThisOffset)?.typeText, "this");
          assert.equal(checker.inspectSymbolAt("/this-super.ts", instTypeofThisOffset)?.typeText, "this");

          const instTypeofThisPropOffset = byteOffsetOf("mn(): typeof this.n", "this");
          assert.equal(checker.typeToString("/this-super.ts", instTypeofThisPropOffset), "this");
          assert.equal(checker.inspectTypeAt("/this-super.ts", instTypeofThisPropOffset)?.typeText, "this");
          assert.equal(checker.inspectSymbolAt("/this-super.ts", instTypeofThisPropOffset)?.typeText, "this");

          const instPropInQueryOffset = byteOffsetOf("mn(): typeof this.n", ".n") + 1;
          assert.equal(checker.typeToString("/this-super.ts", instPropInQueryOffset), "number");

          // 4. `return this;`, `typeof this`, and `typeof this.sn` in static methods -> `"typeof Foo"` on `this`
          const staticThisOffset = byteOffsetOf("static s() {\n    return this;", "return this;") + "return ".length;
          assert.equal(checker.typeToString("/this-super.ts", staticThisOffset), "typeof Foo");
          assert.equal(checker.inspectTypeAt("/this-super.ts", staticThisOffset)?.typeText, "typeof Foo");
          assert.equal(checker.inspectSymbolAt("/this-super.ts", staticThisOffset)?.typeText, "typeof Foo");

          const staticTypeofThisOffset = byteOffsetOf("static smt(): typeof this", "this");
          assert.equal(checker.typeToString("/this-super.ts", staticTypeofThisOffset), "typeof Foo");
          assert.equal(checker.inspectTypeAt("/this-super.ts", staticTypeofThisOffset)?.typeText, "typeof Foo");
          assert.equal(checker.inspectSymbolAt("/this-super.ts", staticTypeofThisOffset)?.typeText, "typeof Foo");

          const staticTypeofThisPropOffset = byteOffsetOf("static smn(): typeof this.sn", "this");
          assert.equal(checker.typeToString("/this-super.ts", staticTypeofThisPropOffset), "typeof Foo");
          assert.equal(checker.inspectTypeAt("/this-super.ts", staticTypeofThisPropOffset)?.typeText, "typeof Foo");
          assert.equal(checker.inspectSymbolAt("/this-super.ts", staticTypeofThisPropOffset)?.typeText, "typeof Foo");

          const staticPropInQueryOffset = byteOffsetOf("static smn(): typeof this.sn", "sn");
          assert.equal(checker.typeToString("/this-super.ts", staticPropInQueryOffset), "string");

          // 5. `static p(this: Bar): typeof this` -> explicit `this` parameter symbol `{"name":"this","typeText":"Bar"}`
          const staticExplicitThisQueryOffset = byteOffsetOf("static p(this: Bar): typeof this", "typeof this") + "typeof ".length;
          assert.equal(checker.typeToString("/this-super.ts", staticExplicitThisQueryOffset), "Bar");
          assert.equal(checker.inspectTypeAt("/this-super.ts", staticExplicitThisQueryOffset)?.typeText, "Bar");
          const explicitThisSym = checker.inspectSymbolAt("/this-super.ts", staticExplicitThisQueryOffset);
          assert.ok(explicitThisSym);
          assert.equal(explicitThisSym.name, "this");
          assert.equal(explicitThisSym.typeText, "Bar");

          // 6. Object literal method `let y: typeof this = this;` -> no spurious `this`-type diagnostic
          const objTypeofThisOffset = byteOffsetOf("let y: typeof this", "typeof this") + "typeof ".length;
          assert.ok(checker.typeToString("/this-super.ts", objTypeofThisOffset));
          assert.ok(checker.inspectTypeAt("/this-super.ts", objTypeofThisOffset));
          checker.inspectSymbolAt("/this-super.ts", objTypeofThisOffset);

          // 7. `super` in derived instance method `q() { return super.m(); }` -> `"Foo"`
          const superOffset = byteOffsetOf("super.m()", "super");
          assert.equal(checker.typeToString("/this-super.ts", superOffset), "Foo");
          assert.equal(checker.inspectTypeAt("/this-super.ts", superOffset)?.typeText, "Foo");
          const superSym = checker.inspectSymbolAt("/this-super.ts", superOffset);
          assert.ok(superSym);
          assert.equal(superSym.name, "Foo");
          assert.equal(superSym.typeText, "Foo");

          // Ensure no spurious diagnostics were mutated onto the program during inspection
          assert.deepEqual(program.getSemanticDiagnostics(), []);
        } finally {
          checker.drop();
        }
      } finally {
        program.drop();
      }

      // Also verify unannotated `const o = { m() { let y: typeof this = this; return y; } };` under strict: false
      const objSource = "const o = { m() { let y: typeof this = this; return y; } };\n";
      vfs.writeFile("/obj-typeof-this.ts", objSource);
      const objProgRes = ts.createProgram(vfs, ["/obj-typeof-this.ts"], {
        target: "es2024",
        module: "esnext",
        moduleResolution: "bundler",
        strict: false,
      });
      assert.equal(objProgRes.ok, true);
      try {
        assert.deepEqual(objProgRes.value.getSemanticDiagnostics(), []);
        const objChecker = objProgRes.value.getChecker();
        try {
          const offset = objSource.indexOf("typeof this") + "typeof ".length;
          assert.equal(objChecker.typeToString("/obj-typeof-this.ts", offset), "any");
          assert.equal(objChecker.inspectTypeAt("/obj-typeof-this.ts", offset)?.typeText, "any");
          assert.equal(objChecker.inspectSymbolAt("/obj-typeof-this.ts", offset), null);
          assert.deepEqual(objProgRes.value.getSemanticDiagnostics(), []);
        } finally {
          objChecker.drop();
        }
      } finally {
        objProgRes.value.drop();
      }
    } finally {
      vfs.drop();
    }
  });
});
