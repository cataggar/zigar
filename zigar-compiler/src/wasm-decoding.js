export const MagicNumber = 0x6d736100;
export const Version = 1;
export const SectionType = {
  Custom: 0,
  Type: 1,
  Import: 2,
  Function: 3,
  Table: 4,
  Memory: 5,
  Global: 6,
  Export: 7,
  Start: 8,
  Element: 9,
  Code: 10,
  Data: 11,
  DataCount: 12
};
export const ObjectType = {
  Function: 0,
  Table: 1,
  Memory: 2,
  Global: 3,
};
export const PURE_SYNC_WASI_IMPORTS = new Set([
  'clock_res_get',
  'clock_time_get',
  'environ_get',
  'environ_sizes_get',
  'random_get',
  'fd_fdstat_get',
  'fd_prestat_get',
  'fd_prestat_dir_name',
]);

export function stripUnused(binary, options = {}) {
  const {
    keepNames = false,
  } = options;
  const { sections, size } = parseBinary(binary);
  const blacklist = [
    /^getFactoryThunk$/,
    /^getModuleAttributes$/,
    /^export(?:er)?\.getFactoryThunk/,
  ];

  function getSection(type) {
    return sections.find(s => s.type === type);
  }

  const nameSection = sections.find(s => s.type === SectionType.Custom && s.name === 'name');
  const { moduleName, functionNames, localNames } = parseNames(nameSection);
  const functions = [];
  // allocate indices for imported functions first
  const importSection = sections.find(s => s.type === SectionType.Import);
  if (importSection) {
    for (const object of importSection.imports) {
      if (object.type === ObjectType.Function) {
        const index = functions.length;
        functions[index] = {
          type: 'imported',
          name: functionNames[index],
          descriptor: object,
          typeIndex: object.type,
          using: undefined,
          index,
          newIndex: -1,
        };
      }
    }
  }
  // allocate indices for internal functions
  const funcSection = getSection(SectionType.Function);
  const codeSection = getSection(SectionType.Code);
  if (funcSection && codeSection) {
    for (const [ i, typeIndex ] of funcSection.types.entries()) {
      const code = codeSection.functions[i];
      const index = functions.length;
      let parsed = null;
      const fn = {
        type: 'internal',
        name: functionNames[index],
        typeIndex,
        code,
        using: undefined,
        index,
        newIndex: -1,

        get instructions() {
          if (!parsed) {
            parsed = parseFunction(this.code);
          }
          return parsed.instructions;
        },
        get size() {
          return parsed.size;
        },
        get locals() {
          return parsed.locals;
        },
      };
      functions.push(fn);
    }
  }

  if (functionNames.length === 0) {
    // get the names from the export and import section if they're missing
    const exportSection = getSection(SectionType.Export);
    if (exportSection) {
      for (const object of exportSection.exports) {
        if (object.type === ObjectType.Function) {
          const fn = functions[object.index];
          fn.name = object.name;
        }
      }
    }
    const importSection = getSection(SectionType.Import);
    if (importSection) {
      for (const object of importSection.imports) {
        if (object.type === ObjectType.Function) {
          const fn = functions[object.index];
          fn.name = object.name;
        }
      }
    }
  }

  // mark blacklisted functions as unused
  for (const fn of functions) {
    if (fn.name && blacklist.some(re => re.test(fn.name))) {
      fn.using = false;
      if (fn.name === 'getFactoryThunk') {
        // when compiled for ReleaseSmall, we don't get the name section
        // therefore unable to remove the factory function by name
        // we know that getFactoryThunk loads its address, however
        // and that a function pointer is just an index into table 0
        const ops = fn.instructions;
        const isConstEnd = (ops.length === 2 && ops[0].opcode === 0x41 && ops[1].opcode === 0x0B)
          || (ops.length === 3 && ops[0].opcode === 0x41 && ops[1].opcode === 0x0F && ops[2].opcode === 0x0B);
        if (isConstEnd) {
          // 0x41 is i32.const
          // 0x0F is return
          // 0x0B is end
          const elemIndex = ops[0].operand;
          const elemSection = getSection(SectionType.Element);
          for (const segment of elemSection.segments) {
            if (segment.indices) {
              const funcIndex = segment.indices[elemIndex - 1];
              const fn = functions[funcIndex];
              fn.using = false;
            }
          }
        }
      }
    }
  }

  function useFunction(index) {
    const fn = functions[index];
    /* c8 ignore next 3 */
    if (!fn) {
      throw new Error(`Function #${index} does not exist`);
    }
    if (fn.using === undefined) {
      fn.using = true;
      if (fn.type === 'internal') {
        // mark all functions called by this one as being in-use as well
        for (const { opcode, operand } of fn.instructions) {
          switch (opcode) {
            case 0x10:    // function call
            case 0x12:    // return call
            case 0xD2: {  // function reference
              useFunction(operand);
            } break;
          }
        }
      }
    }
  }

  // mark functions in table elements as used
  const elemSection = getSection(SectionType.Element);
  if (elemSection) {
    for (const segment of elemSection.segments) {
      if (segment.indices) {
        for (const index of segment.indices) {
          useFunction(index);
        }
      }
    }
  }

  // mark exported functions as being in-use
  const exportSection = getSection(SectionType.Export);
  if (exportSection) {
    for (const object of exportSection.exports) {
      if (object.type === ObjectType.Function) {
        useFunction(object.index);
      }
    }
  }

  // mark start function as being in-use
  const startSection = getSection(SectionType.Start);
  if (startSection) {
    useFunction(startSection.funcidx);
  }

  // assign new indices to functions
  const newFunctions = [];
  for (const fn of functions) {
    if (fn.using) {
      fn.newIndex = newFunctions.length;
      newFunctions.push(fn);
    }
  }

  // update call instructions with new indices
  for (const fn of newFunctions) {
    if (fn.type === 'internal') {
      for (const op of fn.instructions) {
        switch (op.opcode) {
          case 0x10:    // function call
          case 0x12:    // return call
          case 0xD2: {  // function reference
            const target = functions[op.operand];
            op.operand = target.newIndex;
          } break;
        }
      }
      fn.code = repackFunction(fn);
    }
  }

  // create new code and function section
  const newCodeSection = { type: SectionType.Code, functions: [] };
  const newFuncSection = { type: SectionType.Function, types: [] };
  for (const fn of newFunctions) {
    if (fn.type === 'internal') {
      newCodeSection.functions.push(fn.code);
      newFuncSection.types.push(fn.typeIndex);
    }
  }

  // create new element section
  let newElementSection = null;
  if (elemSection) {
    newElementSection = { type: SectionType.Element, segments: [] };
    for (const segment of elemSection.segments) {
      if (segment.indices) {
        const indices = segment.indices.map((index) => {
          const fn = functions[index];
          return (fn.using) ? fn.newIndex : 0;
        });
        newElementSection.segments.push({ ...segment, indices });
        /* c8 ignore next 3 */
      } else {
        newElementSection.segments.push(segment);
      }
    }
  }
  // create new export section
  let newExportSection = null;
  if (exportSection) {
    newExportSection = { type: SectionType.Export, exports: [] };
    for (const object of exportSection.exports) {
      if (object.type === ObjectType.Function) {
        const fn = functions[object.index];
        if (fn.using) {
          const { name, type } = object;
          const index = fn.newIndex;
          newExportSection.exports.push({ name, type, index });
        }
      } else {
        newExportSection.exports.push(object);
      }
    }
    const globalSection = getSection(SectionType.Global);
    const hasImportedGlobal = importSection?.imports.some(o => o.type === ObjectType.Global);
    if (
      globalSection?.data?.byteLength >= 3 &&
      !hasImportedGlobal &&
      globalSection.data.getUint8(0) >= 1 &&
      globalSection.data.getUint8(1) === 0x7f &&
      globalSection.data.getUint8(2) === 0x01 &&
      !newExportSection.exports.some(e => e.name === '__stack_pointer')
    ) {
      newExportSection.exports.push({ name: '__stack_pointer', type: ObjectType.Global, index: 0 });
    }
  }
  // create new import section
  let newImportSection = null;
  if (importSection) {
    newImportSection = { type: SectionType.Import, imports: [] };
    let fnIndex = 0;
    for (const object of importSection.imports) {
      if (object.type === ObjectType.Function) {
        const fn = functions[fnIndex++];
        if (fn.using) {
          newImportSection.imports.push(object);
        }
        /* c8 ignore next 3 */
      } else {
        newImportSection.imports.push(object);
      }
    }
  }
  // create new start section
  let newStartSection = null;
  if (startSection) {
    const fn = functions[startSection.funcidx];
    newStartSection = { type: SectionType.Start, funcidx: fn.newIndex };
  }
  // create new name section
  let newNameSection = null;
  if (nameSection && keepNames) {
    const newFunctionNames = [];
    const newLocalNames = [];
    for (const fn of newFunctions) {
      newFunctionNames.push(fn.name);
      /* c8 ignore next 3 -- can't find a file with local names */
      if (localNames.length > 0) {
        newLocalNames.push(localNames[fn.index]);
      }
    }
    const data = repackNames({
      moduleName,
      functionNames: newFunctionNames,
      localNames: newLocalNames,
      size: nameSection.data.byteLength,
    });
    newNameSection = { type: SectionType.Custom, name: 'name', data };
  }

  // create new module sections
  const newSections = [];
  for (const section of sections) {
    switch (section.type) {
      case SectionType.Code:
        newSections.push(newCodeSection);
        break;
      case SectionType.Function:
        newSections.push(newFuncSection);
        break;
      case SectionType.Element:
        newSections.push(newElementSection);
        break;
      case SectionType.Export:
        newSections.push(newExportSection);
        break;
      case SectionType.Import:
        newSections.push(newImportSection);
        break;
      case SectionType.Start:
        newSections.push(newStartSection);
        break;
      case SectionType.Custom:
        if (section.name === 'name') {
          if (newNameSection) {
            newSections.push(newNameSection);
          }
        } else if (section.name === 'zigar:abi' || section.name.startsWith('component-type')) {
          newSections.push(section);
        }
        break;
      default:
        newSections.push(section);
        break;
    }
  }
  return repackBinary({ sections: newSections, size: size + 24 });
}

export function ensureStackPointerExport(binary) {
  const { sections, size } = parseBinary(binary);
  const importSection = sections.find(s => s.type === SectionType.Import);
  const globalSection = sections.find(s => s.type === SectionType.Global);
  const exportSection = sections.find(s => s.type === SectionType.Export);
  const hasImportedGlobal = importSection?.imports.some(o => o.type === ObjectType.Global);
  if (
    exportSection &&
    globalSection?.data?.byteLength >= 3 &&
    !hasImportedGlobal &&
    globalSection.data.getUint8(0) >= 1 &&
    globalSection.data.getUint8(1) === 0x7f &&
    globalSection.data.getUint8(2) === 0x01 &&
    !exportSection.exports.some(e => e.name === '__stack_pointer')
  ) {
    exportSection.exports.push({ name: '__stack_pointer', type: ObjectType.Global, index: 0 });
    return repackBinary({ sections, size: size + 24 });
  }
  return binary;
}

export function parseBinary(binary) {
  const {
    eof,
    readBytes,
    readU8,
    readU32,
    readString,
    readArray,
    readU32Leb128,
    readExpression,
    readLimits,
    readCustom,
  } = createReader(binary);
  const magic = readU32();
  if (magic !== MagicNumber) {
    throw new Error(`Incorrect magic number: ${magic.toString(16)}`);
  }
  const version = readU32();
  if (version !== Version) {
    throw new Error(`Incorrect version: ${version}`);
  }
  const sections = [];
  while(!eof()) {
    sections.push(readSection());
  }
  const size = binary.byteLength;
  return { sections, size };

  function readSection() {
    const type = readU8();
    const len = readU32Leb128();
    switch(type) {
      case SectionType.Custom:
        const { name, data } = readCustom(len);
        return { type, name, data };
      case SectionType.Import: {
        const imports = readArray(() => {
          const module = readString();
          const name = readString();
          const type = readU8();
          switch (type) {
            case ObjectType.Function: {
              const index = readU32Leb128();
              return { module, name, type, index };
            }
            case ObjectType.Table: {
              const reftype = readU8();
              const limits = readLimits();
              return { module, name, type, reftype, limits };
            }
            case ObjectType.Memory: {
              const limits = readLimits();
              return { module, name, type, limits };
            }
            case ObjectType.Global: {
              const valtype = readU8();
              const mut = readU8();
              return { module, name, type, valtype, mut };
            }
            /* c8 ignore next 3 */
            default: {
              throw new Error(`Unknown object type: ${type}`);
            }
          }
        });
        return { type, imports };
      }
      case SectionType.Export: {
        const exports = readArray(() => {
          const name = readString();
          const type = readU8();
          const index = readU32Leb128();
          return { name, type, index };
        });
        return { type, exports };
      }
      case SectionType.Function: {
        const types = readArray(readU32Leb128);
        return { type, types };
      }
      case SectionType.Code: {
        const functions = readArray(() => {
          const len = readU32Leb128();
          return readBytes(len);
        });
        return { type, functions };
      }
      case SectionType.Element: {
        const segments = readArray(() => {
          const type = readU32Leb128();
          switch (type) {
            case 0: {
              const expr = readExpression();
              const indices = readArray(readU32Leb128);
              return { type, expr, indices };
            }
            case 1: {
              const kind = readU8();
              const indices = readArray(readU32Leb128);
              return { type, kind, indices };
            }
            case 2: {
              const tableidx = readU32Leb128();
              const expr = readExpression();
              const kind = readU8();
              const indices = readArray(readU32Leb128);
              return { type, tableidx, expr, kind, indices };
            }
            case 3: {
              const kind = readU8();
              const indices = readArray(readU32Leb128);
              return { type, kind, indices };
            }
            case 4: {
              const expr = readExpression();
              const entries = readArray(readExpression);
              return { type, expr, entries };
            }
            case 5: {
              const reftype = readU8();
              const entries = readArray(readExpression);
              return { type, reftype, entries };
            }
            case 6: {
              const tableidx = readU32Leb128();
              const expr = readExpression();
              const reftype = readU8();
              const entries = readArray(readExpression);
              return { type, tableidx, expr, reftype, entries };
            }
            case 7: {
              const reftype = readU8();
              const entries = readArray(readExpression);
              return { type, reftype, entries };
            }
          }
        });
        return { type, segments };
      }
      case SectionType.Start: {
        const funcidx = readU32Leb128()
        return { type, funcidx };
      }
      default: {
        const data = readBytes(len);
        return { type, data };
      }
    }
    /* c8 ignore next -- unreachable */
  }
}

export function extractLimits(binary) {
  const {
    eof,
    skip,
    readBytes,
    readU8,
    readU32,
    readString,
    readU32Leb128,
    readLimits,
  } = createReader(binary);
  const magic = readU32();
  /* c8 ignore next 3 */
  if (magic !== MagicNumber) {
    throw new Error(`Incorrect magic number: ${magic.toString(16)}`);
  }
  const version = readU32();
  /* c8 ignore next 3 */
  if (version !== Version) {
    throw new Error(`Incorrect version: ${version}`);
  }
  let memoryInitial, memoryMax, tableInitial;
  let definedMemoryInitial, definedMemoryMax;
  let memory64 = false, table64 = false;
  while (!eof()) {
    const type = readU8();
    const len = readU32Leb128();
    if (type === SectionType.Import) {
      const sub = createReader(readBytes(len));
      const count = sub.readU32Leb128();
      for (let i = 0; i < count; i++) {
        const module = sub.readString();
        const name = sub.readString();
        const objType = sub.readU8();
        switch (objType) {
          /* c8 ignore next 3 */
          case ObjectType.Function: {
            sub.readU32Leb128();
          } break;
          case ObjectType.Table: {
            sub.readU8();
            const { flags, min } = sub.readLimits();
            if (module === 'env' && name === '__indirect_function_table') {
              tableInitial = min;
              if (flags & 0x04) {
                table64 = true;
              }
            }
          } break;
          case ObjectType.Memory: {
            const { flags, min, max } = sub.readLimits();
            if (module === 'env' && name === 'memory') {
              memoryInitial = min;
              memoryMax = max;
              if (flags & 0x04) {
                memory64 = true;
              }
            }
          } break;
          /* c8 ignore next 4 */
          case ObjectType.Global: {
            sub.readU8();
            sub.readU8();
          } break;
          /* c8 ignore next 3 */
          default: {
            throw new Error(`Unknown object type: ${objType}`);
          }
        }
      }
    } else if (type === SectionType.Table) {
      const sub = createReader(readBytes(len));
      const count = sub.readU32Leb128();
      if (count > 0) {
        const b0 = sub.readU8();
        if (b0 === 0x40) {
          sub.readU8();
          sub.readU8();
        }
        const { flags } = sub.readLimits();
        if (flags & 0x04) {
          table64 = true;
        }
      }
    } else if (type === SectionType.Memory) {
      const sub = createReader(readBytes(len));
      const count = sub.readU32Leb128();
      if (count > 0) {
        const { flags, min, max } = sub.readLimits();
        definedMemoryInitial = min;
        definedMemoryMax = max;
        if (flags & 0x04) {
          memory64 = true;
        }
      }
      break;
    } else {
      skip(len);
      if (type > SectionType.Memory && type !== SectionType.Custom) {
        break;
      }
    }
  }
  return {
    memoryMax,
    memoryInitial,
    tableInitial,
    definedMemoryInitial,
    definedMemoryMax,
    memory64,
    table64,
  };
}

function isSuspendingImport(module, name) {
  if (module === 'wasi_snapshot_preview1' && (name === 'proc_exit' || PURE_SYNC_WASI_IMPORTS.has(name))) {
    return false;
  }
  if (module === 'env' && name !== '_handleJscall' && name !== '_futexWaitAsync') {
    return false;
  }
  return true;
}

function evalConstOffsetExpr(expr) {
  const { decodeNext } = createDecoder(createReader(expr));
  const op1 = decodeNext();
  const op2 = decodeNext();
  if (op1 && op2 && op2.opcode === 0x0B) {
    if (op1.opcode === 0x41 || op1.opcode === 0x42) {
      return Number(op1.operand);
    }
  }
  return null;
}

function evalElemFuncExpr(expr) {
  const { decodeNext } = createDecoder(createReader(expr));
  let op;
  while (op = decodeNext()) {
    if (op.opcode === 0xD2) {
      return op.operand;
    }
    if (op.opcode === 0x0B) {
      break;
    }
  }
  return undefined;
}

export function analyzeJspiSyncFunctions(binary) {
  const { sections } = parseBinary(binary);
  const importSection = sections.find(s => s.type === SectionType.Import);
  const funcSection = sections.find(s => s.type === SectionType.Function);
  const exportSection = sections.find(s => s.type === SectionType.Export);
  const elemSection = sections.find(s => s.type === SectionType.Element);
  const codeSection = sections.find(s => s.type === SectionType.Code);

  const funcTypeIndex = [];
  const importedSuspending = [];
  if (importSection) {
    for (const imp of importSection.imports) {
      if (imp.type === ObjectType.Function) {
        funcTypeIndex.push(imp.index);
        importedSuspending.push(isSuspendingImport(imp.module, imp.name));
      }
    }
  }
  const importFuncCount = funcTypeIndex.length;
  const internalCount = funcSection ? funcSection.types.length : 0;
  if (funcSection) {
    for (const typeIndex of funcSection.types) {
      funcTypeIndex.push(typeIndex);
    }
  }
  const totalFuncs = funcTypeIndex.length;

  let runThunkIdx = null;
  let runVariadicThunkIdx = null;
  if (exportSection) {
    for (const exp of exportSection.exports) {
      if (exp.type === ObjectType.Function) {
        if (exp.name === 'runThunk') {
          runThunkIdx = exp.index;
        } else if (exp.name === 'runVariadicThunk') {
          runVariadicThunkIdx = exp.index;
        }
      }
    }
  }

  const tableSlotToFuncIndex = new Map();
  const indirectFuncIndices = new Set();
  if (elemSection) {
    for (const seg of elemSection.segments) {
      const isActiveTable0 = seg.type === 0 || seg.type === 4
        || ((seg.type === 2 || seg.type === 6) && seg.tableidx === 0);
      const offset = isActiveTable0 ? evalConstOffsetExpr(seg.expr) : null;
      if (seg.indices) {
        for (let i = 0; i < seg.indices.length; i++) {
          const funcIdx = seg.indices[i];
          indirectFuncIndices.add(funcIdx);
          if (offset !== null) {
            tableSlotToFuncIndex.set(offset + i, funcIdx);
          }
        }
      } else if (seg.entries) {
        for (let i = 0; i < seg.entries.length; i++) {
          const funcIdx = evalElemFuncExpr(seg.entries[i]);
          if (funcIdx !== undefined) {
            indirectFuncIndices.add(funcIdx);
            if (offset !== null) {
              tableSlotToFuncIndex.set(offset + i, funcIdx);
            }
          }
        }
      }
    }
  }

  const directCalls = Array.from({ length: totalFuncs }, () => []);
  const indirectTypes = Array.from({ length: totalFuncs }, () => []);
  if (codeSection) {
    for (let i = 0; i < internalCount; i++) {
      const funcIdx = importFuncCount + i;
      const code = codeSection.functions[i];
      if (!code) continue;
      const { instructions } = parseFunction(code);
      const callsSet = new Set();
      const typesSet = new Set();
      for (const op of instructions) {
        switch (op.opcode) {
          case 0x10:
          case 0x12:
            callsSet.add(op.operand);
            break;
          case 0x11:
          case 0x13:
            typesSet.add(op.operand[0]);
            break;
          case 0x14:
          case 0x15:
            typesSet.add(op.operand);
            break;
          case 0xD2:
            indirectFuncIndices.add(op.operand);
            break;
        }
      }
      directCalls[funcIdx] = [ ...callsSet ];
      indirectTypes[funcIdx] = [ ...typesSet ];
    }
  }

  const canSuspend = new Uint8Array(totalFuncs);
  const typeCanSuspend = new Set();
  for (let f = 0; f < importFuncCount; f++) {
    if (importedSuspending[f]) {
      canSuspend[f] = 1;
      if (indirectFuncIndices.has(f)) {
        typeCanSuspend.add(funcTypeIndex[f]);
      }
    }
  }

  let changed = true;
  while (changed) {
    changed = false;
    for (let f = importFuncCount; f < totalFuncs; f++) {
      if (canSuspend[f]) continue;
      let suspends = false;
      for (const callee of directCalls[f]) {
        if (canSuspend[callee]) {
          suspends = true;
          break;
        }
      }
      if (!suspends) {
        for (const t of indirectTypes[f]) {
          if (typeCanSuspend.has(t)) {
            suspends = true;
            break;
          }
        }
      }
      if (suspends) {
        canSuspend[f] = 1;
        changed = true;
        if (indirectFuncIndices.has(f)) {
          typeCanSuspend.add(funcTypeIndex[f]);
        }
      }
    }
  }

  const overheadSuspends = (idx) => {
    if (idx === null) return false;
    if (idx < importFuncCount) return !!canSuspend[idx];
    return directCalls[idx].some(callee => canSuspend[callee]);
  };
  if (overheadSuspends(runThunkIdx) || overheadSuspends(runVariadicThunkIdx)) {
    return [];
  }

  const syncTableIndices = [];
  for (const [ slotIdx, funcIdx ] of tableSlotToFuncIndex) {
    if (!canSuspend[funcIdx]) {
      syncTableIndices.push(Number(slotIdx));
    }
  }
  syncTableIndices.sort((a, b) => a - b);
  return syncTableIndices;
}

export function repackBinary(module) {
  const {
    finalize,
    writeBytes,
    writeU8,
    writeU32,
    writeLength,
    writeString,
    writeArray,
    writeU32Leb128,
    writeExpression,
    writeLimits,
    writeCustom,
  } = createWriter(module.size);
  writeU32(MagicNumber);
  writeU32(Version);
  for (const section of module.sections) {
    writeSection(section);
  }
  return finalize();

  function writeSection(section) {
    writeU8(section.type);
    writeLength(() => {
      switch(section.type) {
        case SectionType.Custom: {
          writeCustom(section);
        } break;
        case SectionType.Import: {
          writeArray(section.imports, (object) => {
            writeString(object.module);
            writeString(object.name);
            writeU8(object.type);
            switch (object.type) {
              case ObjectType.Function: {
                writeU32Leb128(object.index);
              } break;
              case ObjectType.Table: {
                writeU8(object.reftype);
                writeLimits(object.limits);
              } break;
              case ObjectType.Memory: {
                writeLimits(object.limits);
              } break;
              case ObjectType.Global: {
                writeU8(object.valtype);
                writeU8(object.mut);
              } break;
            }
          });
        } break;
        case SectionType.Export: {
          writeArray(section.exports, (object) => {
            writeString(object.name);
            writeU8(object.type);
            writeU32Leb128(object.index);
          });
        } break;
        case SectionType.Function: {
          writeArray(section.types, writeU32Leb128);
        } break;
        case SectionType.Code: {
          writeArray(section.functions, (code) => {
            writeU32Leb128(code.byteLength);
            writeBytes(code);
          });
        } break;
        case SectionType.Element: {
          writeArray(section.segments, (segment) => {
            writeU32Leb128(segment.type);
            switch (segment.type) {
              case 0: {
                writeExpression(segment.expr);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 1: {
                writeU8(segment.kind);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 2: {
                writeU32Leb128(segment.tableidx);
                writeExpression(segment.expr);
                writeU8(segment.kind);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 3: {
                writeU8(segment.kind);
                writeArray(segment.indices, writeU32Leb128);
              } break;
              case 4: {
                writeExpression(segment.expr);
                writeArray(segment.entries, writeExpression);
              } break;
              case 5: {
                writeU8(segment.reftype);
                writeArray(segment.entries, writeExpression);
              } break;
              case 6: {
                writeU32Leb128(segment.tableidx);
                writeExpression(segment.expr);
                writeU8(segment.reftype);
                writeArray(segment.entries, writeExpression);
              } break;
              case 7: {
                writeU8(segment.reftype);
                writeArray(segment.entries, writeExpression);
              } break;
            }
          });
        } break;
        case SectionType.Start: {
          writeU32Leb128(section.funcidx);
        } break;
        default: {
          writeBytes(section.data);
        }
      }
    });
  }
}

function createReader(dv) {
  const decoder = new TextDecoder('utf-8', { ignoreBOM: true });
  let offset = 0;

  function eof() {
    return (offset >= dv.byteLength);
  }

  function skip(len) {
    offset += len;
  }

  function readBytes(len) {
    const bytes = new DataView(dv.buffer, dv.byteOffset + offset, len);
    offset += len;
    return bytes;
  }

  function readU8() {
    return dv.getUint8(offset++);
  }

  function readU32() {
    const value = dv.getUint32(offset, true);
    offset += 4;
    return value;
  }

  function readF64() {
    const value = dv.getFloat64(offset, true);
    offset += 8;
    return value;
  }

  function readString() {
    const len = readU32Leb128();
    const bytes = new Uint8Array(dv.buffer, dv.byteOffset + offset, len);
    offset += len;
    return decoder.decode(bytes);
  }

  function readArray(cb) {
    const len = readU32Leb128();
    const array = [];
    for (let i = 0; i < len; i++) {
      array.push(cb());
    }
    return array;
  }

  function readU32Leb128() {
    let value = 0;
    let shift = 0;
    while (true) {
      const byte = readU8();
      value |= (byte & 0x7f) << shift;
      shift += 7;
      if ((0x80 & byte) === 0) {
        if (value < 0) {
          value += 2 ** 32;
        }
        return value;
      }
    }
  }

  function readU64Leb128() {
    let value = 0n;
    let shift = 0n;
    while (true) {
      const byte = readU8();
      value |= BigInt(byte & 0x7f) << shift;
      shift += 7n;
      if ((0x80 & byte) === 0) {
        return (value > 0xFFFFFFFFn) ? value : Number(value);
      }
    }
  }

  function readI32Leb128() {
    let value = 0;
    let shift = 0;
    while (true) {
      const byte = dv.getUint8(offset++);
      value |= (byte & 0x7f) << shift;
      shift += 7;
      if ((0x80 & byte) === 0) {
        if (shift < 32 && (byte & 0x40) !== 0) {
          return value | (~0 << shift);
        }
        return value;
      }
    }
  }

  function readI64Leb128() {
    let value = 0n;
    let shift = 0n;
    while (true) {
      const byte = dv.getUint8(offset++);
      value |= BigInt(byte & 0x7f) << shift;
      shift += 7n;
      if ((0x80 & byte) === 0) {
        if ((byte & 0x40) !== 0) {
          return value | (~0n << shift);
        }
        return value;
      }
    }
  }

  function readExpression() {
    const start = offset;
    const { decodeNext } = createDecoder(self);
    let op;
    while (op = decodeNext()) {
      if (op.opcode === 0x0B) {
        break;
      }
    }
    const len = offset - start;
    return new DataView(dv.buffer, dv.byteOffset + start, len);
  }

  function readLimits() {
    const flags = readU8();
    const is64 = !!(flags & 0x04);
    const min = is64 ? Number(readU64Leb128()) : readU32Leb128();
    let max = undefined;
    let shared = undefined;
    if (flags & 0x01) {
      max = is64 ? Number(readU64Leb128()) : readU32Leb128();
    }
    if (flags & 0x02) {
      shared = true;
    }
    return is64 ? { flags, min, max, shared, is64 } : { flags, min, max, shared };
  }

  function readCustom(len) {
    const offsetBefore = offset;
    const name = readString();
    const nameLen = offset - offsetBefore;
    const data = readBytes(len - nameLen);
    return { name, data };
  }

  const self = {
    eof,
    skip,
    readBytes,
    readU8,
    readU32,
    readF64,
    readString,
    readArray,
    readU32Leb128,
    readU64Leb128,
    readI32Leb128,
    readI64Leb128,
    readExpression,
    readLimits,
    readCustom,
  };
  return self;
}

function createWriter(maxSize) {
  const dv = new DataView(new ArrayBuffer(maxSize));
  const encoder = new TextEncoder();
  let offset = 0, lengthChecking = false;

  function finalize() {
    return new DataView(dv.buffer, 0, offset);
  }

  function writeBytes(bytes) {
    for (let i = 0; i < bytes.byteLength; i++) {
      writeU8(bytes.getUint8(i));
    }
  }

  function writeU8(value) {
    if (!lengthChecking) {
      dv.setUint8(offset, value);
    }
    offset++;
  }

  function writeU32(value) {
    if (!lengthChecking) {
      dv.setUint32(offset, value, true);
    }
    offset += 4;
  }

  function writeF64(value) {
    if (!lengthChecking) {
      dv.setFloat64(offset, value, true);
    }
    offset += 8;
  }

  function writeString(string) {
    const bytes = encoder.encode(string);
    writeU32Leb128(bytes.length);
    for (const byte of bytes) {
      writeU8(byte);
    }
  }

  function writeArray(values, cb) {
    writeU32Leb128(values.length);
    for (const value of values) {
      cb(value);
    }
  }

  function writeU32Leb128(value) {
    while (true) {
      const byte = value & 0x7f;
      value >>>= 7;
      if (value === 0) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeU64Leb128(value) {
    let v = (typeof value === 'bigint') ? value : BigInt(value);
    while (true) {
      const byte = Number(v & 0x7fn);
      v >>= 7n;
      if (v === 0n) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeI32Leb128(value) {
    while (true) {
      const byte = value & 0x7f;
      value >>= 7;
      if ((value === 0 && (byte & 0x40) === 0) || (value === -1 && (byte & 0x40) !== 0)) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeI64Leb128(value) {
    while (true) {
      const byte = Number(value & 0x7fn);
      value >>= 7n;
      if ((value === 0n && (byte & 0x40) === 0) || (value === -1n && (byte & 0x40) !== 0)) {
        writeU8(byte);
        return;
      }
      writeU8(byte | 0x80);
    }
  }

  function writeLength(cb) {
    const saved = offset;
    lengthChecking = true;
    cb();
    const length = offset - saved;
    offset = saved;
    lengthChecking = false;
    writeU32Leb128(length);
    cb();
  }

  function writeExpression(code) {
    writeBytes(code);
  }

  function writeLimits(limits) {
    writeU8(limits.flags);
    const writeVal = (limits.flags & 0x04) ? writeU64Leb128 : writeU32Leb128;
    writeVal(limits.min);
    if (limits.max !== undefined) {
      writeVal(limits.max);
    }
  }

  function writeCustom({ name, data }) {
    writeString(name);
    writeBytes(data);
  }

  return {
    finalize,
    writeBytes,
    writeU8,
    writeU32,
    writeF64,
    writeString,
    writeArray,
    writeU32Leb128,
    writeU64Leb128,
    writeI32Leb128,
    writeI64Leb128,
    writeExpression,
    writeLimits,
    writeCustom,
    writeLength,
  };
}

export function parseFunction(dv) {
  const reader = createReader(dv);
  const {
    readU8,
    readArray,
    readU32Leb128,
  } = reader;
  // read locals first
  const locals = readArray(() => {
    const number = readU32Leb128();
    const type = readU8();
    return { number, type };
  });
  // decode the expression
  const { decodeNext } = createDecoder(reader);
  const instructions = [];
  let op;
  while (op = decodeNext()) {
    instructions.push(op);
  }
  const size = dv.byteLength;
  return { locals, instructions, size };
}

function createDecoder(reader) {
  const {
    eof,
    readBytes,
    readU8,
    readArray,
    readU32Leb128,
    readU64Leb128,
    readI32Leb128,
    readI64Leb128,
    readU32,
    readF64,
  } = reader;
  const readOne = readU32Leb128;
  const readTwo = () => [ readOne(), readU64Leb128() ];
  const readMultiple = (count) => {
    const indices = [];
    for (let i = 0; i < count; i++) {
      indices.push(readOne());
    }
    return indices;
  };
  const operandReaders = {
    0x02: readI32Leb128,
    0x03: readI32Leb128,
    0x04: readI32Leb128,
    0x0C: readOne,
    0x0D: readOne,
    0x0E: () => [ readArray(readOne), readU32Leb128() ],

    0x10: readOne,
    0x11: readTwo,
    0x12: readOne,
    0x13: readTwo,
    0x14: readOne,
    0x15: readOne,

    0x1C: () => readArray(readU8),

    0x20: readOne,
    0x21: readOne,
    0x22: readOne,
    0x23: readOne,
    0x24: readOne,
    0x25: readOne,
    0x26: readOne,
    0x28: readTwo,
    0x29: readTwo,
    0x2A: readTwo,
    0x2B: readTwo,
    0x2C: readTwo,
    0x2D: readTwo,
    0x2E: readTwo,
    0x2F: readTwo,

    0x30: readTwo,
    0x31: readTwo,
    0x32: readTwo,
    0x33: readTwo,
    0x34: readTwo,
    0x35: readTwo,
    0x36: readTwo,
    0x37: readTwo,
    0x38: readTwo,
    0x39: readTwo,
    0x3A: readTwo,
    0x3B: readTwo,
    0x3C: readTwo,
    0x3D: readTwo,
    0x3E: readTwo,
    0x3F: readOne,

    0x40: readOne,
    0x41: readI32Leb128,
    0x42: readI64Leb128,
    0x43: readU32,  // avoid precision loss due to float-to-double conversion
    0x44: readF64,

    0xD0: readU8,
    0xD2: readOne,

    0xFC: () => {
      const op1 = readOne();
      switch (op1) {
        case 9:
        case 11:
        case 13:
        case 15:
        case 16:
        case 17:
          return [ op1, readOne() ];
        case 8:
        case 10:
        case 12:
        case 14:
          return [ op1, readOne(), readOne() ];
        default:
          return op1;
      }
    },
    0xFD: () => {
      const op1 = readOne();
      switch (op1) {
        case 21:
        case 22:
        case 23:
        case 24:
        case 25:
        case 26:
        case 27:
        case 28:
        case 29:
        case 30:
        case 31:
        case 32:
        case 33:
        case 34:
          return [ op1, readOne() ];
        case 0:
        case 1:
        case 2:
        case 3:
        case 5:
        case 6:
        case 7:
        case 8:
        case 9:
        case 10:
        case 11:
        case 92:
        case 93:
          return [ op1, readOne(), readU64Leb128() ];
        case 84:
        case 85:
        case 86:
        case 87:
        case 88:
        case 89:
        case 90:
        case 91:
          return [ op1, readOne(), readU64Leb128(), readOne() ];
        case 12:
          return [ op1, readBytes(16) ];
        case 13:
          return [ op1, ...readMultiple(16) ];
        default:
          return op1;
      }
    },
    0xFE: () => {
      const op1 = readOne();
      switch (op1) {
        /* c8 ignore next 2 */
        case 3:
          return [ op1, readU8() ];
        default:
          return [ op1, readOne(), readU64Leb128() ];
      }
    },
  }

  function decodeNext() {
    if (eof()) {
      return null;
    }
    const opcode = readU8();
    const f = operandReaders[opcode];
    const operand = f?.();
    return { opcode, operand };
  }

  return { decodeNext };
}

export function repackFunction({ locals, instructions, size }) {
  const writer = createWriter(size);
  const {
    finalize,
    writeU8,
    writeArray,
    writeU32Leb128,
  } = writer;
  writeArray(locals, ({ number, type }) => {
    writeU32Leb128(number);
    writeU8(type);
  });
  const { encodeNext } = createEncoder(writer);
  for (const op of instructions) {
    encodeNext(op);
  }
  return finalize();
}

function createEncoder(writer) {
  const {
    writeBytes,
    writeU8,
    writeArray,
    writeU32Leb128,
    writeU64Leb128,
    writeI32Leb128,
    writeI64Leb128,
    writeU32,
    writeF64,
  } = writer;
  const writeOne = writeU32Leb128;
  const writeTwo = (op) => {
    writeOne(op[0]);
    writeU64Leb128(op[1]);
  };
  const writeMultiple = (indices) => {
    for (const index of indices) {
      writeU64Leb128(index);
    }
  };
  const operandWriters = {
    0x02: writeI32Leb128,
    0x03: writeI32Leb128,
    0x04: writeI32Leb128,
    0x0C: writeOne,
    0x0D: writeOne,
    0x0E: (op) => [ writeArray(op[0], writeOne), writeOne(op[1]) ],

    0x10: writeOne,
    0x11: writeTwo,
    0x12: writeOne,
    0x13: writeTwo,
    0x14: writeOne,
    0x15: writeOne,
    0x1C: (op) => writeArray(op, writeU8),

    0x20: writeOne,
    0x21: writeOne,
    0x22: writeOne,
    0x23: writeOne,
    0x24: writeOne,
    0x25: writeOne,
    0x26: writeOne,
    0x28: writeTwo,
    0x29: writeTwo,
    0x2A: writeTwo,
    0x2B: writeTwo,
    0x2C: writeTwo,
    0x2D: writeTwo,
    0x2E: writeTwo,
    0x2F: writeTwo,

    0x30: writeTwo,
    0x31: writeTwo,
    0x32: writeTwo,
    0x33: writeTwo,
    0x34: writeTwo,
    0x35: writeTwo,
    0x36: writeTwo,
    0x37: writeTwo,
    0x38: writeTwo,
    0x39: writeTwo,
    0x3A: writeTwo,
    0x3B: writeTwo,
    0x3C: writeTwo,
    0x3D: writeTwo,
    0x3E: writeTwo,
    0x3F: writeOne,

    0x40: writeOne,
    0x41: writeI32Leb128,
    0x42: writeI64Leb128,
    0x43: writeU32,   // avoid precision loss due to float-to-double conversion
    0x44: writeF64,

    0xD0: writeU8,
    0xD2: writeOne,

    0xFC: (op) => {
      if (op instanceof Array) {
        writeMultiple(op);
      } else {
        writeOne(op);
      }
    },
    0xFD: (op) => {
      if (op instanceof Array) {
        if (op[0] === 12) {
          writeOne(op[0]);
          writeBytes(op[1]);
        } else {
          writeMultiple(op);
        }
      } else {
        writeOne(op);
      }
    },
    0xFE: (op) => {
      writeMultiple(op);
    },
  }

  function encodeNext({ opcode, operand }) {
    writeU8(opcode);
    const f = operandWriters[opcode];
    f?.(operand);
  }

  return { encodeNext };
}

export function parseNames(section) {
  let moduleName = '';
  const functionNames = [];
  const localNames = [];
  if (section) {
    const {
      eof,
      readString,
      readU8,
      readU32Leb128,
      readArray,
      readBytes,
    } = createReader(section.data);
    const readMap = () => readArray(() => {
      const index = readU32Leb128();
      const name = readString();
      return { index, name };
    });
    while(!eof()) {
      const id = readU8();
      const size = readU32Leb128();
      switch (id) {
        case 0: {
          moduleName = readString();
        } break;
        case 1: {
          const map = readMap();
          for (const { index, name } of map) {
            functionNames[index] = name;
          }
        } break;
        case 2:
          const map = readArray(() => {
            const index = readU8();
            const locals = readMap();
            return { index, locals };
          });
          for (const { index, locals } of map) {
            localNames[index] = locals;
          }
          break;
        default: {
          readBytes(size);
        }
      }
    }
  }
  return { moduleName, functionNames, localNames };
}

export function repackNames({ moduleName, functionNames, localNames, size }) {
  const {
    finalize,
    writeString,
    writeU8,
    writeU32Leb128,
    writeArray,
    writeLength,
  } = createWriter(size);
  const writeMap = (entries) => writeArray(entries, ({ index, name }) => {
    writeU32Leb128(index);
    writeString(name);
  });
  if (moduleName) {
    writeU8(0);
    writeLength(() => {
      writeString(moduleName);
    });
  }
  if (functionNames.length > 0) {
    writeU8(1);
    writeLength(() => {
      const map = [];
      for (const [ index, name ] of functionNames.entries()) {
        map.push({ index, name });
      }
      writeMap(map);
    });
  }
  if (localNames.length > 0) {
    writeU8(2);
    writeLength(() => {
      const imap = [];
      for (const [ index, locals ] of localNames.entries()) {
        imap.push({ index, locals });
      }
      writeArray(imap, ({ index, locals }) => {
        writeU32Leb128(index);
        writeMap(locals);
      });
    });
  }
  return finalize();
}