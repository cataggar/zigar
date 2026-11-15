package export_zigar_typescript_compiler

import (
	"context"
	"fmt"
	"runtime"
	"slices"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/compiler"
	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/diagnostics"
	"github.com/microsoft/TypeScript/tsc/internal/tsoptions"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_compiler"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

// Program wraps a compiled TypeScript 7.1 `*compiler.Program` as an exported WIT resource.
type Program struct {
	pinner    runtime.Pinner
	handle    int32
	prog      *compiler.Program
	rootFiles []string
	baseDir   tspath.RootedDirectoryPath
}

func (self *Program) OnDrop() {
	if self == nil {
		return
	}
	self.prog = nil
	self.rootFiles = nil
}

// Inner returns the underlying `*compiler.Program` for cross-interface consumers
// such as `export_zigar_typescript_extractor`.
func (self *Program) Inner() *compiler.Program {
	if self == nil {
		return nil
	}
	return self.prog
}

// BaseDir returns the base directory used to resolve relative paths in this program.
func (self *Program) BaseDir() tspath.RootedDirectoryPath {
	if self == nil || self.baseDir == "" {
		return defaultRootDir
	}
	return self.baseDir
}

// RootFiles returns a copy of the normalized root file paths for this program.
func (self *Program) RootFiles() []string {
	if self == nil {
		return nil
	}
	return slices.Clone(self.rootFiles)
}

// ResolveSourceFile finds a source file in the program by rooted or relative path.
func (self *Program) ResolveSourceFile(fileName string) *ast.SourceFile {
	if self == nil || self.prog == nil {
		return nil
	}
	rooted, ok := normalizeFilePath(fileName, self.BaseDir())
	if !ok {
		return nil
	}
	if sf := self.prog.GetSourceFile(rooted); sf != nil {
		return sf
	}
	if self.BaseDir() != defaultRootDir {
		if alt, ok := normalizeFilePath(fileName, defaultRootDir); ok {
			if sf := self.prog.GetSourceFile(alt); sf != nil {
				return sf
			}
		}
	}
	return nil
}

func CreateProgram(
	fs *Vfs,
	rootFiles []string,
	options zigar_typescript_compiler.CompilerOptions,
) witTypes.Result[*Program, []zigar_typescript_types.Diagnostic] {
	if fs == nil || fs.FS() == nil {
		return witTypes.Err[*Program, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
			makeCustomErrorDiagnostic(18003, "Invalid VFS handle."),
		})
	}
	if len(rootFiles) == 0 {
		return witTypes.Err[*Program, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
			makeCustomErrorDiagnostic(18003, "No inputs were found in root-files."),
		})
	}

	coreOpts, baseDir := buildCoreCompilerOptions(options, fs.useBundledLibs)

	rootedFiles := make([]tspath.RootedFilePath, 0, len(rootFiles))
	normalizedStrings := make([]string, 0, len(rootFiles))
	var missingDiags []zigar_typescript_types.Diagnostic

	for _, rf := range rootFiles {
		rooted, ok := normalizeFilePath(rf, baseDir)
		if !ok {
			missingDiags = append(missingDiags, makeCustomErrorDiagnostic(6053, fmt.Sprintf("File '%s' not found.", rf)))
			continue
		}
		if !fs.FS().FileExists(rooted) {
			missingDiags = append(missingDiags, makeCustomErrorDiagnostic(6053, fmt.Sprintf("File '%s' not found.", rooted.AsString())))
			continue
		}
		rootedFiles = append(rootedFiles, rooted)
		normalizedStrings = append(normalizedStrings, rooted.AsString())
	}

	if len(missingDiags) > 0 {
		return witTypes.Err[*Program, []zigar_typescript_types.Diagnostic](missingDiags)
	}

	host := compiler.NewCompilerHost(fs.FS(), fs.DefaultLibraryPath(), nil, nil, nil)
	cmdLine := tsoptions.NewParsedCommandLine(
		coreOpts,
		rootedFiles,
		nil,
		baseDir,
		fs.FS().CaseSensitivity(),
	)

	prog, err := compiler.NewProgram(context.Background(), compiler.ProgramOptions{
		ProgramConfig: compiler.ProgramConfig{
			Config:         cmdLine,
			SingleThreaded: core.TSTrue,
		},
		ProgramHosts: compiler.ProgramHosts{
			Host: host,
		},
	})
	if err != nil || prog == nil {
		msg := "Failed to construct TypeScript program."
		if err != nil {
			msg = err.Error()
		}
		return witTypes.Err[*Program, []zigar_typescript_types.Diagnostic]([]zigar_typescript_types.Diagnostic{
			makeCustomErrorDiagnostic(18003, msg),
		})
	}

	optDiags := prog.GetOptionsDiagnostics()
	for _, d := range optDiags {
		if d != nil && d.Category() == diagnostics.CategoryError {
			return witTypes.Err[*Program, []zigar_typescript_types.Diagnostic](convertDiagnostics(optDiags))
		}
	}

	return witTypes.Ok[*Program, []zigar_typescript_types.Diagnostic](&Program{
		prog:      prog,
		rootFiles: normalizedStrings,
		baseDir:   baseDir,
	})
}

func (self *Program) GetRootFiles() []string {
	if self == nil {
		return []string{}
	}
	return slices.Clone(self.rootFiles)
}

func (self *Program) GetSyntacticDiagnostics(fileName witTypes.Option[string]) []zigar_typescript_types.Diagnostic {
	if self == nil || self.prog == nil {
		return []zigar_typescript_types.Diagnostic{}
	}
	ctx := context.Background()
	if fileName.Tag() == witTypes.OptionSome {
		sf := self.ResolveSourceFile(fileName.Some())
		if sf == nil {
			return []zigar_typescript_types.Diagnostic{
				makeCustomErrorDiagnostic(6053, fmt.Sprintf("File '%s' not found in program.", fileName.Some())),
			}
		}
		return convertDiagnostics(self.prog.GetSyntacticDiagnostics(ctx, sf))
	}
	return convertDiagnostics(self.prog.GetSyntacticDiagnostics(ctx, nil))
}

func (self *Program) GetSemanticDiagnostics(fileName witTypes.Option[string]) []zigar_typescript_types.Diagnostic {
	if self == nil || self.prog == nil {
		return []zigar_typescript_types.Diagnostic{}
	}
	ctx := context.Background()
	if fileName.Tag() == witTypes.OptionSome {
		sf := self.ResolveSourceFile(fileName.Some())
		if sf == nil {
			return []zigar_typescript_types.Diagnostic{
				makeCustomErrorDiagnostic(6053, fmt.Sprintf("File '%s' not found in program.", fileName.Some())),
			}
		}
		return convertDiagnostics(self.prog.GetSemanticDiagnostics(ctx, sf))
	}
	return convertDiagnostics(self.prog.GetSemanticDiagnostics(ctx, nil))
}

func (self *Program) GetGlobalDiagnostics() []zigar_typescript_types.Diagnostic {
	if self == nil || self.prog == nil {
		return []zigar_typescript_types.Diagnostic{}
	}
	ctx := context.Background()
	combined := slices.Concat(
		self.prog.GetOptionsDiagnostics(),
		self.prog.GetProgramDiagnostics(),
		self.prog.GetGlobalDiagnostics(ctx),
	)
	return convertDiagnostics(combined)
}

func (self *Program) EmitDeclarations(fileName witTypes.Option[string]) zigar_typescript_compiler.EmitOutput {
	if self == nil || self.prog == nil {
		return zigar_typescript_compiler.EmitOutput{
			OutputFiles: []zigar_typescript_compiler.EmitFile{},
			Diagnostics: []zigar_typescript_types.Diagnostic{},
			EmitSkipped: true,
		}
	}

	var targets []*ast.SourceFile
	if fileName.Tag() == witTypes.OptionSome {
		sf := self.ResolveSourceFile(fileName.Some())
		if sf == nil {
			return zigar_typescript_compiler.EmitOutput{
				OutputFiles: []zigar_typescript_compiler.EmitFile{},
				Diagnostics: []zigar_typescript_types.Diagnostic{
					makeCustomErrorDiagnostic(6053, fmt.Sprintf("File '%s' not found in program.", fileName.Some())),
				},
				EmitSkipped: true,
			}
		}
		targets = []*ast.SourceFile{sf}
	}

	var emitted []zigar_typescript_compiler.EmitFile
	forceEmit := !self.prog.Options().GetEmitDeclarations()
	ctx := context.Background()
	res := self.prog.Emit(ctx, compiler.EmitOptions{
		TargetSourceFiles: targets,
		EmitOnly:          compiler.EmitOnlyDts,
		ForceEmit:         forceEmit,
		WriteFile: func(outName tspath.RootedFilePath, text string, _ *compiler.WriteFileData) error {
			if forceEmit && !self.prog.Options().DeclarationMap.IsTrue() && strings.HasSuffix(outName.AsString(), ".map") {
				return nil
			}
			emitted = append(emitted, zigar_typescript_compiler.EmitFile{
				FileName: outName.AsString(),
				Contents: text,
			})
			return nil
		},
	})

	if res == nil {
		return zigar_typescript_compiler.EmitOutput{
			OutputFiles: []zigar_typescript_compiler.EmitFile{},
			Diagnostics: []zigar_typescript_types.Diagnostic{},
			EmitSkipped: true,
		}
	}

	if emitted == nil {
		emitted = []zigar_typescript_compiler.EmitFile{}
	}
	return zigar_typescript_compiler.EmitOutput{
		OutputFiles: emitted,
		Diagnostics: convertDiagnostics(res.Diagnostics),
		EmitSkipped: res.EmitSkipped,
	}
}

func (self *Program) GetChecker() *Checker {
	if self == nil || self.prog == nil {
		return &Checker{}
	}
	tc, release := self.prog.GetTypeChecker(context.Background())
	return &Checker{
		program: self,
		tc:      tc,
		release: release,
	}
}
