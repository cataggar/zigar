package export_zigar_typescript_extractor

import (
	"context"
	"fmt"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/checker"
	"github.com/microsoft/TypeScript/tsc/internal/compiler"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/exports/export_zigar_typescript_compiler"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

// ExtractModuleGraph extracts a complete, arena-indexed semantic declaration graph
// (`zigar:typescript/extractor@7.1.0#extract-module-graph`) from a compiled TypeScript 7.1 program.
func ExtractModuleGraph(
	prog *export_zigar_typescript_compiler.Program,
	config zigar_typescript_types.ExtractConfig,
) witTypes.Result[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic] {
	if prog == nil || prog.Inner() == nil {
		return witTypes.Err[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
			makeErrorDiagnostic(18003, "Invalid program handle passed to extract-module-graph."),
		})
	}

	tsProg := prog.Inner()
	ctx := context.Background()
	tc, release := tsProg.GetTypeChecker(ctx)
	if release != nil {
		defer release()
	}
	if tc == nil {
		return witTypes.Err[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
			makeErrorDiagnostic(18003, "Failed to acquire TypeScript 7.1 Checker session."),
		})
	}

	b := newGraphBuilder(prog, tsProg, tc, config)

	requestedRoots := config.RootFiles
	if len(requestedRoots) == 0 {
		requestedRoots = prog.RootFiles()
	}

	entryFiles := make([]*ast.SourceFile, 0, len(requestedRoots))
	seenEntryMod := map[uint32]bool{}
	for _, rootPath := range requestedRoots {
		sf := prog.ResolveSourceFile(rootPath)
		if sf == nil {
			return witTypes.Err[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
				makeErrorDiagnostic(6053, fmt.Sprintf("File '%s' not found in program.", rootPath)),
			})
		}
		b.explicitRootFiles[sf.FileName().AsString()] = true
		entryFiles = append(entryFiles, sf)
		if b.sourceFileMatchesFilter(sf, rootPath) {
			modID := b.ensureModuleWithSpecifier(sf, rootPath, true)
			if !seenEntryMod[modID] {
				seenEntryMod[modID] = true
				b.entryModules = append(b.entryModules, modID)
			}
		}
	}

	// If module-specifiers filter is supplied, also seed any matching external or ambient modules.
	if len(config.ModuleSpecifiers) > 0 {
		b.seedConfiguredModuleSpecifiers(seenEntryMod)
	}

	// Drain module extraction queue (entry modules + transitive referenced/re-exported modules).
	b.drainModuleQueue()

	// Finalize cross-kind declaration merging (`merged-with` links).
	b.finalizeMergedDeclarations()

	// Collect diagnostics for entry files (syntactic for all entry files; semantic for non-.d.ts entry files).
	var rawDiags []*ast.Diagnostic
	seenDiagFiles := map[string]bool{}
	for _, sf := range entryFiles {
		if sf == nil {
			continue
		}
		fn := sf.FileName().AsString()
		if seenDiagFiles[fn] {
			continue
		}
		seenDiagFiles[fn] = true
		rawDiags = append(rawDiags, tsProg.GetSyntacticDiagnostics(ctx, sf)...)
		if !sf.IsDeclarationFile {
			rawDiags = append(rawDiags, tsProg.GetSemanticDiagnostics(ctx, sf)...)
		}
	}
	witDiags := export_zigar_typescript_compiler.ConvertDiagnostics(rawDiags)

	return witTypes.Ok[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic](
		zigar_typescript_types.DeclarationGraph{
			Strings:      b.strings.strings,
			Modules:      b.modules,
			EntryModules: b.entryModules,
			Decls:        b.decls,
			Types:        b.types,
			Signatures:   b.signatures,
			TypeParams:   b.typeParams,
			Properties:   b.properties,
			Diagnostics:  witDiags,
		},
	)
}

func makeErrorDiagnostic(code uint32, message string) zigar_typescript_types.Diagnostic {
	return zigar_typescript_types.Diagnostic{
		Code:         code,
		Category:     zigar_typescript_types.DiagnosticCategory_Error,
		Message:      message,
		Span:         witTypes.None[zigar_typescript_types.SourceSpan](),
		RelatedSpans: []zigar_typescript_types.SourceSpan{},
	}
}

type stringInterner struct {
	strings []string
	index   map[string]uint32
}

func (s *stringInterner) intern(val string) uint32 {
	if id, ok := s.index[val]; ok {
		return id
	}
	id := uint32(len(s.strings))
	s.strings = append(s.strings, val)
	s.index[val] = id
	return id
}

type declCategory uint8

const (
	declCatNone declCategory = iota
	declCatFunction
	declCatVariable
	declCatInterface
	declCatClass
	declCatTypeAlias
	declCatEnum
	declCatNamespace
	declCatImportEquals
	declCatReExport
)

type symCatKey struct {
	sym *ast.Symbol
	cat declCategory
}

type graphBuilder struct {
	prog   *export_zigar_typescript_compiler.Program
	tsProg *compiler.Program
	tc     *checker.Checker
	cfg    zigar_typescript_types.ExtractConfig

	strings      stringInterner
	modules      []zigar_typescript_types.ModuleNode
	entryModules []uint32
	decls        []zigar_typescript_types.DeclNode
	types        []zigar_typescript_types.TypeNode
	signatures   []zigar_typescript_types.SignatureNode
	typeParams   []zigar_typescript_types.TypeParamNode
	properties   []zigar_typescript_types.PropNode

	explicitRootFiles map[string]bool
	modFilter         map[string]bool

	moduleByFile     map[string]uint32
	sfByModule       map[uint32]*ast.SourceFile
	extractedModules map[uint32]bool
	moduleQueue      []uint32

	declBySymCat    map[symCatKey]uint32
	declByNode      map[*ast.Node]uint32
	allDeclsForSym  map[*ast.Symbol][]uint32
	extractedSymSet map[*ast.Symbol]bool

	astTypeMemo      map[*ast.Node]uint32
	checkerTypeMemo  map[*checker.Type]uint32
	expandedTypeMemo map[*checker.Type]uint32
	inInferExtends   map[*ast.Symbol]bool

	tpByNode map[*ast.Node]uint32
	tpBySym  map[*ast.Symbol]uint32

	sigByNode       map[*ast.Node]uint32
	sigByCheckerSig map[*checker.Signature]uint32
}

func newGraphBuilder(
	prog *export_zigar_typescript_compiler.Program,
	tsProg *compiler.Program,
	tc *checker.Checker,
	cfg zigar_typescript_types.ExtractConfig,
) *graphBuilder {
	var modFilter map[string]bool
	if len(cfg.ModuleSpecifiers) > 0 {
		modFilter = make(map[string]bool, len(cfg.ModuleSpecifiers)*2)
		for _, spec := range cfg.ModuleSpecifiers {
			modFilter[spec] = true
			if trimmed, ok := strings.CutPrefix(spec, "node:"); ok {
				modFilter[trimmed] = true
			}
		}
	}

	return &graphBuilder{
		prog:              prog,
		tsProg:            tsProg,
		tc:                tc,
		cfg:               cfg,
		strings:           stringInterner{strings: []string{}, index: map[string]uint32{}},
		modules:           []zigar_typescript_types.ModuleNode{},
		entryModules:      []uint32{},
		decls:             []zigar_typescript_types.DeclNode{},
		types:             []zigar_typescript_types.TypeNode{},
		signatures:        []zigar_typescript_types.SignatureNode{},
		typeParams:        []zigar_typescript_types.TypeParamNode{},
		properties:        []zigar_typescript_types.PropNode{},
		explicitRootFiles: map[string]bool{},
		modFilter:         modFilter,
		moduleByFile:      map[string]uint32{},
		sfByModule:        map[uint32]*ast.SourceFile{},
		extractedModules:  map[uint32]bool{},
		declBySymCat:      map[symCatKey]uint32{},
		declByNode:        map[*ast.Node]uint32{},
		allDeclsForSym:    map[*ast.Symbol][]uint32{},
		extractedSymSet:   map[*ast.Symbol]bool{},
		astTypeMemo:       map[*ast.Node]uint32{},
		checkerTypeMemo:   map[*checker.Type]uint32{},
		expandedTypeMemo:  map[*checker.Type]uint32{},
		inInferExtends:    map[*ast.Symbol]bool{},
		tpByNode:          map[*ast.Node]uint32{},
		tpBySym:           map[*ast.Symbol]uint32{},
		sigByNode:         map[*ast.Node]uint32{},
		sigByCheckerSig:   map[*checker.Signature]uint32{},
	}
}

func (b *graphBuilder) intern(s string) uint32 {
	return b.strings.intern(s)
}

func (b *graphBuilder) canonicalSymbol(sym *ast.Symbol) *ast.Symbol {
	if sym == nil {
		return nil
	}
	if merged := b.tc.GetMergedSymbol(sym); merged != nil {
		return merged
	}
	return sym
}

func (b *graphBuilder) resolveAliasSymbol(sym *ast.Symbol) *ast.Symbol {
	if sym == nil {
		return nil
	}
	if sym.Flags()&ast.SymbolFlagsAlias != 0 {
		if aliased := b.tc.GetAliasedSymbol(sym); aliased != nil && aliased != b.tc.GetUnknownSymbol() {
			return aliased
		}
	}
	return sym
}

func isSome[T any](opt witTypes.Option[T]) bool {
	return opt.Tag() == witTypes.OptionSome
}

func isNone[T any](opt witTypes.Option[T]) bool {
	return opt.Tag() == witTypes.OptionNone
}

func (b *graphBuilder) isExtractableSourceFile(sf *ast.SourceFile) bool {
	if sf == nil {
		return false
	}
	if b.explicitRootFiles[sf.FileName().AsString()] {
		return true
	}
	return !b.tsProg.IsSourceFileDefaultLibrary(sf.PathKey())
}

func (b *graphBuilder) allocDecl(placeholder zigar_typescript_types.DeclNode) uint32 {
	id := uint32(len(b.decls))
	placeholder.Id = id
	if placeholder.TypeParams == nil {
		placeholder.TypeParams = []uint32{}
	}
	if placeholder.MergedWith == nil {
		placeholder.MergedWith = []uint32{}
	}
	b.decls = append(b.decls, placeholder)
	return id
}

func (b *graphBuilder) allocType(kind zigar_typescript_types.TypeKind) uint32 {
	id := uint32(len(b.types))
	b.types = append(b.types, zigar_typescript_types.TypeNode{
		Id:           id,
		Kind:         kind,
		ResolvedType: witTypes.None[uint32](),
	})
	return id
}

func (b *graphBuilder) allocSig() uint32 {
	id := uint32(len(b.signatures))
	b.signatures = append(b.signatures, zigar_typescript_types.SignatureNode{
		Id:            id,
		TypeParams:    []uint32{},
		ThisParam:     witTypes.None[uint32](),
		Params:        []zigar_typescript_types.ParamNode{},
		ReturnType:    0,
		TypePredicate: witTypes.None[zigar_typescript_types.TypePredicateData](),
		IsAbstract:    false,
		Jsdoc:         witTypes.None[zigar_typescript_types.JsdocInfo](),
	})
	return id
}

func (b *graphBuilder) allocTypeParam(nameID uint32) uint32 {
	id := uint32(len(b.typeParams))
	b.typeParams = append(b.typeParams, zigar_typescript_types.TypeParamNode{
		Id:          id,
		Name:        nameID,
		Constraint:  witTypes.None[uint32](),
		DefaultType: witTypes.None[uint32](),
	})
	return id
}

func (b *graphBuilder) allocProp(prop zigar_typescript_types.PropNode) uint32 {
	id := uint32(len(b.properties))
	prop.Id = id
	b.properties = append(b.properties, prop)
	return id
}

func (b *graphBuilder) registerSymDecl(sym *ast.Symbol, declID uint32) {
	if sym == nil {
		return
	}
	list := b.allDeclsForSym[sym]
	for _, existing := range list {
		if existing == declID {
			return
		}
	}
	b.allDeclsForSym[sym] = append(list, declID)
}

func (b *graphBuilder) finalizeMergedDeclarations() {
	for _, ids := range b.allDeclsForSym {
		if len(ids) <= 1 {
			continue
		}
		for _, id := range ids {
			peers := make([]uint32, 0, len(ids)-1)
			for _, other := range ids {
				if other != id {
					peers = append(peers, other)
				}
			}
			b.decls[id].MergedWith = peers
		}
	}
}

