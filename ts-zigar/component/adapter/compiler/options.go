package export_zigar_typescript_compiler

import (
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_compiler"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

func buildCoreCompilerOptions(
	opts zigar_typescript_compiler.CompilerOptions,
	useBundledLibs bool,
) (*core.CompilerOptions, tspath.RootedDirectoryPath) {
	baseDir := defaultRootDir
	if opts.BaseUrl.Tag() == witTypes.OptionSome {
		baseDir = normalizeDirPath(opts.BaseUrl.Some(), defaultRootDir)
	}

	coreOpts := &core.CompilerOptions{
		Target:                     mapScriptTarget(opts.Target),
		Module:                     mapModuleKind(opts.Module),
		ModuleResolution:           mapModuleResolution(opts.ModuleResolution),
		Strict:                     boolToTristate(opts.Strict),
		ExactOptionalPropertyTypes: trueOrUnknown(opts.ExactOptionalPropertyTypes),
		NoUncheckedIndexedAccess:   trueOrUnknown(opts.NoUncheckedIndexedAccess),
		Declaration:                trueOrUnknown(opts.Declaration),
		EmitDeclarationOnly:        trueOrUnknown(opts.EmitDeclarationOnly),
		AllowJs:                    trueOrUnknown(opts.AllowJs),
		SkipLibCheck:               boolToTristate(opts.SkipLibCheck),
		NewLine:                    core.NewLineKindLF,
	}

	if !useBundledLibs {
		coreOpts.NoLib = core.TSTrue
	}

	if len(opts.TypeRoots) > 0 {
		roots := make([]tspath.RootedDirectoryPath, 0, len(opts.TypeRoots))
		for _, tr := range opts.TypeRoots {
			if strings.TrimSpace(tr) == "" {
				continue
			}
			roots = append(roots, normalizeDirPath(tr, baseDir))
		}
		if len(roots) > 0 {
			coreOpts.TypeRoots = roots
		}
	}

	if len(opts.Types) > 0 {
		types := make([]string, 0, len(opts.Types))
		for _, t := range opts.Types {
			if trimmed := strings.TrimSpace(t); trimmed != "" {
				types = append(types, strings.Clone(trimmed))
			}
		}
		coreOpts.Types = types
	}

	return coreOpts, baseDir
}

func mapScriptTarget(t zigar_typescript_compiler.ScriptTarget) core.ScriptTarget {
	switch t {
	case zigar_typescript_compiler.ScriptTarget_Es2020:
		return core.ScriptTargetES2020
	case zigar_typescript_compiler.ScriptTarget_Es2022:
		return core.ScriptTargetES2022
	case zigar_typescript_compiler.ScriptTarget_Es2024:
		return core.ScriptTargetES2024
	case zigar_typescript_compiler.ScriptTarget_Esnext:
		return core.ScriptTargetESNext
	default:
		return core.ScriptTargetESNext
	}
}

func mapModuleKind(m zigar_typescript_compiler.ModuleKind) core.ModuleKind {
	switch m {
	case zigar_typescript_compiler.ModuleKind_Commonjs:
		return core.ModuleKindCommonJS
	case zigar_typescript_compiler.ModuleKind_Es2020:
		return core.ModuleKindES2020
	case zigar_typescript_compiler.ModuleKind_Es2022:
		return core.ModuleKindES2022
	case zigar_typescript_compiler.ModuleKind_Esnext:
		return core.ModuleKindESNext
	case zigar_typescript_compiler.ModuleKind_Node16:
		return core.ModuleKindNode16
	case zigar_typescript_compiler.ModuleKind_Nodenext:
		return core.ModuleKindNodeNext
	case zigar_typescript_compiler.ModuleKind_Preserve:
		return core.ModuleKindPreserve
	default:
		return core.ModuleKindESNext
	}
}

func mapModuleResolution(mr zigar_typescript_compiler.ModuleResolutionKind) core.ModuleResolutionKind {
	switch mr {
	case zigar_typescript_compiler.ModuleResolutionKind_Bundler:
		return core.ModuleResolutionKindBundler
	case zigar_typescript_compiler.ModuleResolutionKind_Node16:
		return core.ModuleResolutionKindNode16
	case zigar_typescript_compiler.ModuleResolutionKind_Nodenext:
		return core.ModuleResolutionKindNodeNext
	default:
		return core.ModuleResolutionKindBundler
	}
}

func boolToTristate(v bool) core.Tristate {
	if v {
		return core.TSTrue
	}
	return core.TSFalse
}

func trueOrUnknown(v bool) core.Tristate {
	if v {
		return core.TSTrue
	}
	return core.TSUnknown
}
