package export_zigar_typescript_compiler

import (
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/diagnostics"
	"github.com/microsoft/TypeScript/tsc/internal/locale"
	"github.com/microsoft/TypeScript/tsc/internal/scanner"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

// ConvertDiagnostics converts TypeScript AST diagnostics into WIT Diagnostic records.
func ConvertDiagnostics(diags []*ast.Diagnostic) []zigar_typescript_types.Diagnostic {
	return convertDiagnostics(diags)
}

func convertDiagnostics(diags []*ast.Diagnostic) []zigar_typescript_types.Diagnostic {
	if len(diags) == 0 {
		return []zigar_typescript_types.Diagnostic{}
	}
	out := make([]zigar_typescript_types.Diagnostic, 0, len(diags))
	for _, d := range diags {
		if d == nil {
			continue
		}
		out = append(out, convertDiagnostic(d))
	}
	return out
}

func convertDiagnostic(d *ast.Diagnostic) zigar_typescript_types.Diagnostic {
	var code uint32
	if d.Code() > 0 {
		code = uint32(d.Code())
	}

	cat := convertDiagnosticCategory(d.Category())
	msg := formatDiagnosticMessage(d)

	span := witTypes.None[zigar_typescript_types.SourceSpan]()
	if s, ok := spanFromDiagnostic(d); ok {
		span = witTypes.Some[zigar_typescript_types.SourceSpan](s)
	}

	related := make([]zigar_typescript_types.SourceSpan, 0, len(d.RelatedInformation()))
	for _, rel := range d.RelatedInformation() {
		if rel == nil {
			continue
		}
		if rs, ok := spanFromDiagnostic(rel); ok {
			related = append(related, rs)
		}
	}

	return zigar_typescript_types.Diagnostic{
		Code:         code,
		Category:     cat,
		Message:      msg,
		Span:         span,
		RelatedSpans: related,
	}
}

func convertDiagnosticCategory(c diagnostics.Category) zigar_typescript_types.DiagnosticCategory {
	switch c {
	case diagnostics.CategoryWarning:
		return zigar_typescript_types.DiagnosticCategory_Warning
	case diagnostics.CategoryError:
		return zigar_typescript_types.DiagnosticCategory_Error
	case diagnostics.CategorySuggestion:
		return zigar_typescript_types.DiagnosticCategory_Suggestion
	case diagnostics.CategoryMessage:
		return zigar_typescript_types.DiagnosticCategory_Message
	default:
		return zigar_typescript_types.DiagnosticCategory_Error
	}
}

func formatDiagnosticMessage(d *ast.Diagnostic) string {
	head := d.Localize(locale.Default)
	chain := d.MessageChain()
	if len(chain) == 0 {
		return head
	}
	var b strings.Builder
	b.WriteString(head)
	writeDiagnosticChain(&b, chain, 1)
	return b.String()
}

func writeDiagnosticChain(b *strings.Builder, chain []*ast.Diagnostic, indent int) {
	for _, item := range chain {
		if item == nil {
			continue
		}
		b.WriteByte('\n')
		for range indent {
			b.WriteString("  ")
		}
		b.WriteString(item.Localize(locale.Default))
		if len(item.MessageChain()) > 0 {
			writeDiagnosticChain(b, item.MessageChain(), indent+1)
		}
	}
}

func spanFromDiagnostic(d *ast.Diagnostic) (zigar_typescript_types.SourceSpan, bool) {
	file := d.File()
	if file == nil {
		return zigar_typescript_types.SourceSpan{}, false
	}
	pos := d.Pos()
	length := d.Len()
	if pos < 0 {
		pos = 0
	}
	if length < 0 {
		length = 0
	}
	textLen := len(file.Text())
	if pos > textLen {
		pos = textLen
	}
	if pos+length > textLen {
		length = textLen - pos
	}
	line, col := scanner.GetECMALineAndUTF16CharacterOfPosition(file, pos)
	return zigar_typescript_types.SourceSpan{
		FileName: file.FileName().AsString(),
		Start:    uint32(pos),
		Length:   uint32(length),
		Line:     uint32(line + 1),
		Column:   uint32(col + 1),
	}, true
}

func spanFromNode(node *ast.Node) (zigar_typescript_types.SourceSpan, bool) {
	if node == nil {
		return zigar_typescript_types.SourceSpan{}, false
	}
	file := ast.GetSourceFileOfNode(node)
	if file == nil {
		return zigar_typescript_types.SourceSpan{}, false
	}
	start := scanner.GetTokenPosOfNode(node, file, false /*includeJSDoc*/)
	end := node.End()
	if start < 0 {
		start = 0
	}
	if end < start {
		end = start
	}
	textLen := len(file.Text())
	if start > textLen {
		start = textLen
	}
	if end > textLen {
		end = textLen
	}
	line, col := scanner.GetECMALineAndUTF16CharacterOfPosition(file, start)
	return zigar_typescript_types.SourceSpan{
		FileName: file.FileName().AsString(),
		Start:    uint32(start),
		Length:   uint32(end - start),
		Line:     uint32(line + 1),
		Column:   uint32(col + 1),
	}, true
}

func makeCustomErrorDiagnostic(code uint32, message string) zigar_typescript_types.Diagnostic {
	return zigar_typescript_types.Diagnostic{
		Code:         code,
		Category:     zigar_typescript_types.DiagnosticCategory_Error,
		Message:      message,
		Span:         witTypes.None[zigar_typescript_types.SourceSpan](),
		RelatedSpans: []zigar_typescript_types.SourceSpan{},
	}
}
