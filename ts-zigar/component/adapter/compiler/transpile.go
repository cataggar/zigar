package export_zigar_typescript_compiler

import (
	"context"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/transpile"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_compiler"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
)

func TranspileModule(source string, fileName string) zigar_typescript_compiler.EmitOutput {
	effectiveName := strings.TrimSpace(fileName)
	if effectiveName == "" {
		effectiveName = "/module.ts"
	}

	out := transpile.TranspileModule(context.Background(), source, transpile.Options{
		CompilerOptions: &core.CompilerOptions{
			Target:  core.ScriptTargetESNext,
			Module:  core.ModuleKindESNext,
			NewLine: core.NewLineKindLF,
		},
		FileName:          effectiveName,
		ReportDiagnostics: true,
	})
	if out == nil {
		return zigar_typescript_compiler.EmitOutput{
			OutputFiles: []zigar_typescript_compiler.EmitFile{},
			Diagnostics: []zigar_typescript_types.Diagnostic{},
			EmitSkipped: true,
		}
	}

	outFileName := outputJSFileName(effectiveName)
	files := []zigar_typescript_compiler.EmitFile{
		{
			FileName: outFileName,
			Contents: out.OutputText,
		},
	}

	return zigar_typescript_compiler.EmitOutput{
		OutputFiles: files,
		Diagnostics: convertDiagnostics(out.Diagnostics),
		EmitSkipped: false,
	}
}

func CompilerVersion() string {
	return core.Version()
}

func outputJSFileName(inputName string) string {
	rooted, ok := normalizeFilePath(inputName, defaultRootDir)
	if !ok {
		return "/module.js"
	}
	p := rooted.AsString()
	switch {
	case tspath.FileExtensionIs(p, tspath.ExtensionMts):
		return tspath.ChangeAnyExtension(p, tspath.ExtensionMjs, []string{tspath.ExtensionMts}, tspath.CaseSensitive)
	case tspath.FileExtensionIs(p, tspath.ExtensionCts):
		return tspath.ChangeAnyExtension(p, tspath.ExtensionCjs, []string{tspath.ExtensionCts}, tspath.CaseSensitive)
	case tspath.FileExtensionIsOneOf(p, []string{tspath.ExtensionTs, tspath.ExtensionTsx, tspath.ExtensionJsx, tspath.ExtensionJs}):
		return tspath.ChangeAnyExtension(
			p,
			tspath.ExtensionJs,
			[]string{tspath.ExtensionTs, tspath.ExtensionTsx, tspath.ExtensionJsx, tspath.ExtensionJs},
			tspath.CaseSensitive,
		)
	default:
		return p + ".js"
	}
}
