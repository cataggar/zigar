package export_zigar_typescript_extractor

import (
	"fmt"

	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/exports/export_zigar_typescript_compiler"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

// ExtractModuleGraph implements the M2.1b (#41) structural entry-module stub for
// `zigar:typescript/extractor@7.1.0#extract-module-graph`. Full AST/Checker
// declaration-graph lowering is implemented in Issue #42 on top of `Program.Inner()`.
func ExtractModuleGraph(
	prog *export_zigar_typescript_compiler.Program,
	config zigar_typescript_types.ExtractConfig,
) witTypes.Result[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic] {
	if prog == nil || prog.Inner() == nil {
		return witTypes.Err[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
			{
				Code:         18003,
				Category:     zigar_typescript_types.DiagnosticCategory_Error,
				Message:      "Invalid program handle passed to extract-module-graph.",
				Span:         witTypes.None[zigar_typescript_types.SourceSpan](),
				RelatedSpans: []zigar_typescript_types.SourceSpan{},
			},
		})
	}

	requestedRoots := config.RootFiles
	if len(requestedRoots) == 0 {
		requestedRoots = prog.RootFiles()
	}

	pool := &stringInterner{index: map[string]uint32{}}
	modules := make([]zigar_typescript_types.ModuleNode, 0, len(requestedRoots))
	entryModules := make([]uint32, 0, len(requestedRoots))

	for _, rootPath := range requestedRoots {
		sf := prog.ResolveSourceFile(rootPath)
		if sf == nil {
			return witTypes.Err[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
				{
					Code:         6053,
					Category:     zigar_typescript_types.DiagnosticCategory_Error,
					Message:      fmt.Sprintf("File '%s' not found in program.", rootPath),
					Span:         witTypes.None[zigar_typescript_types.SourceSpan](),
					RelatedSpans: []zigar_typescript_types.SourceSpan{},
				},
			})
		}

		modID := uint32(len(modules))
		filePath := sf.FileName().AsString()
		specID := pool.intern(rootPath)
		pathID := pool.intern(filePath)

		modules = append(modules, zigar_typescript_types.ModuleNode{
			Id:                  modID,
			Specifier:           specID,
			FilePath:            pathID,
			Exports:             []uint32{},
			DefaultExport:       witTypes.None[uint32](),
			ExportEquals:        witTypes.None[uint32](),
			UmdNamespace:        witTypes.None[uint32](),
			StarReExports:       []uint32{},
			AmbientModules:      []zigar_typescript_types.AmbientModuleNode{},
			GlobalAugmentations: []uint32{},
			TripleSlashTypes:    []uint32{},
			TripleSlashPaths:    []uint32{},
			TripleSlashLibs:     []uint32{},
		})
		entryModules = append(entryModules, modID)
	}

	return witTypes.Ok[zigar_typescript_types.DeclarationGraph, []zigar_typescript_types.Diagnostic](
		zigar_typescript_types.DeclarationGraph{
			Strings:      pool.strings,
			Modules:      modules,
			EntryModules: entryModules,
			Decls:        []zigar_typescript_types.DeclNode{},
			Types:        []zigar_typescript_types.TypeNode{},
			Signatures:   []zigar_typescript_types.SignatureNode{},
			TypeParams:   []zigar_typescript_types.TypeParamNode{},
			Properties:   []zigar_typescript_types.PropNode{},
			Diagnostics:  []zigar_typescript_types.Diagnostic{},
		},
	)
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
