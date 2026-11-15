package export_zigar_typescript_compiler

import (
	"runtime"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/astnav"
	"github.com/microsoft/TypeScript/tsc/internal/checker"
	"github.com/microsoft/TypeScript/tsc/internal/core"
	"github.com/microsoft/TypeScript/tsc/internal/scanner"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_compiler"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

const defaultTypeFormatFlags = checker.TypeFormatFlagsNoTruncation |
	checker.TypeFormatFlagsUseAliasDefinedOutsideCurrentScope |
	checker.TypeFormatFlagsUseInstantiationExpressions

// Checker wraps a borrowed TypeScript 7.1 `*checker.Checker` session as an exported WIT resource.
type Checker struct {
	pinner  runtime.Pinner
	handle  int32
	program *Program
	tc      *checker.Checker
	release func()
}

func (self *Checker) OnDrop() {
	if self == nil {
		return
	}
	if self.release != nil {
		release := self.release
		self.release = nil
		release()
	}
	self.tc = nil
	self.program = nil
}

func (self *Checker) TypeToString(fileName string, offset uint32) witTypes.Option[string] {
	node, sym, t := self.resolveAtOffset(fileName, offset)
	if node == nil || t == nil {
		return witTypes.None[string]()
	}
	if t == self.tc.GetErrorType() && sym == nil {
		return witTypes.None[string]()
	}
	text := self.tc.TypeToStringEx(t, nil, defaultTypeFormatFlags, nil)
	if text == "" {
		return witTypes.None[string]()
	}
	return witTypes.Some[string](text)
}

func (self *Checker) InspectTypeAt(fileName string, offset uint32) witTypes.Option[zigar_typescript_compiler.TypeInfo] {
	node, sym, t := self.resolveAtOffset(fileName, offset)
	if node == nil || t == nil {
		return witTypes.None[zigar_typescript_compiler.TypeInfo]()
	}
	if t == self.tc.GetErrorType() && sym == nil {
		return witTypes.None[zigar_typescript_compiler.TypeInfo]()
	}
	typeText := self.tc.TypeToStringEx(t, nil, defaultTypeFormatFlags, nil)
	if typeText == "" {
		return witTypes.None[zigar_typescript_compiler.TypeInfo]()
	}
	flags := uint32(t.Flags())
	isUnion := t.IsUnion()
	isIntersection := t.IsIntersection()
	isNullable := isTypeNullable(t)

	spanOpt := witTypes.None[zigar_typescript_types.SourceSpan]()
	if tSym := t.Symbol(); tSym != nil {
		if declSpan, ok := primaryDeclarationSpan(tSym); ok {
			spanOpt = witTypes.Some[zigar_typescript_types.SourceSpan](declSpan)
		}
	}
	if spanOpt.Tag() == witTypes.OptionNone {
		if nodeSpan, ok := spanFromNode(node); ok {
			spanOpt = witTypes.Some[zigar_typescript_types.SourceSpan](nodeSpan)
		}
	}

	return witTypes.Some[zigar_typescript_compiler.TypeInfo](zigar_typescript_compiler.TypeInfo{
		TypeText:       typeText,
		TypeFlags:      flags,
		IsNullable:     isNullable,
		IsUnion:        isUnion,
		IsIntersection: isIntersection,
		Span:           spanOpt,
	})
}

func (self *Checker) InspectSymbolAt(fileName string, offset uint32) witTypes.Option[zigar_typescript_compiler.SymbolInfo] {
	node, sym, _ := self.resolveAtOffset(fileName, offset)
	if node == nil || sym == nil {
		return witTypes.None[zigar_typescript_compiler.SymbolInfo]()
	}
	return witTypes.Some[zigar_typescript_compiler.SymbolInfo](self.buildSymbolInfo(sym, node))
}

func (self *Checker) ResolveModuleExports(fileName string) []zigar_typescript_compiler.SymbolInfo {
	if self == nil || self.tc == nil || self.program == nil || self.program.prog == nil {
		return []zigar_typescript_compiler.SymbolInfo{}
	}

	modSym := self.findModuleSymbol(fileName)
	if modSym == nil {
		return []zigar_typescript_compiler.SymbolInfo{}
	}

	exports := self.tc.GetExportsOfModule(modSym)
	if len(exports) == 0 {
		return []zigar_typescript_compiler.SymbolInfo{}
	}

	out := make([]zigar_typescript_compiler.SymbolInfo, 0, len(exports))
	for _, expSym := range exports {
		if expSym == nil {
			continue
		}
		out = append(out, self.buildSymbolInfo(expSym, nil))
	}
	return out
}

func (self *Checker) findModuleSymbol(specifierOrPath string) *ast.Symbol {
	if sf := self.program.ResolveSourceFile(specifierOrPath); sf != nil {
		if sym := self.tc.GetSymbolOfNode(sf.AsNode()); sym != nil {
			return sym
		}
		if sym := sf.AsNode().Symbol(); sym != nil {
			return sym
		}
	}

	prog := self.program.prog
	modes := []core.ResolutionMode{
		core.ResolutionModeNone,
		core.ResolutionModeESM,
		core.ResolutionModeCommonJS,
	}
	for _, sf := range prog.GetSourceFiles() {
		for _, mode := range modes {
			if resolved := prog.GetResolvedModule(sf, specifierOrPath, mode); resolved != nil {
				if targetSF := prog.GetSourceFileForResolvedModule(resolved); targetSF != nil {
					if sym := self.tc.GetSymbolOfNode(targetSF.AsNode()); sym != nil {
						return sym
					}
				}
			}
		}
	}

	return self.tc.TryFindAmbientModule(specifierOrPath)
}

func (self *Checker) resolveAtOffset(fileName string, offset uint32) (*ast.Node, *ast.Symbol, *checker.Type) {
	if self == nil || self.tc == nil || self.program == nil {
		return nil, nil, nil
	}
	sf := self.program.ResolveSourceFile(fileName)
	if sf == nil {
		return nil, nil, nil
	}
	text := sf.Text()
	if int(offset) < 0 || int(offset) >= len(text) {
		return nil, nil, nil
	}

	node := astnav.GetTouchingToken(sf, int(offset))
	if node == nil ||
		node.Kind == ast.KindEndOfFile ||
		ast.IsSourceFile(node) ||
		!ast.IsTokenKind(node.Kind) ||
		node.Kind <= ast.KindLastTriviaToken ||
		node.Kind == ast.KindJSDocCommentTextToken ||
		ast.IsPunctuationKind(node.Kind) {
		return nil, nil, nil
	}
	if ast.IsKeywordKind(node.Kind) && !ast.IsKeywordExpressionKind(node.Kind) && !ast.IsKeywordTypeKind(node.Kind) {
		return nil, nil, nil
	}

	sym := self.tc.GetSymbolAtLocation(node)
	if sym == nil && node.Parent != nil && ast.IsDeclaration(node.Parent) && ast.GetNameOfDeclaration(node.Parent) == node {
		sym = self.tc.GetSymbolOfDeclaration(node.Parent)
	}

	targetSym := sym
	if targetSym != nil && targetSym.Flags()&ast.SymbolFlagsAlias != 0 {
		if aliased := self.tc.GetAliasedSymbol(targetSym); aliased != nil && aliased != self.tc.GetUnknownSymbol() {
			targetSym = aliased
		}
	}

	var t *checker.Type
	if targetSym != nil {
		if targetSym.Flags()&ast.SymbolFlagsValue != 0 {
			t = self.tc.GetTypeOfSymbolAtLocation(targetSym, node)
		} else if targetSym.Flags()&ast.SymbolFlagsType != 0 {
			t = self.tc.GetDeclaredTypeOfSymbol(targetSym)
		} else {
			t = self.tc.GetTypeOfSymbol(targetSym)
		}
	}
	if t == nil {
		typeNode := node
		if node.Parent != nil && (node.Parent.Kind == ast.KindLiteralType || node.Parent.Kind == ast.KindThisType) {
			typeNode = node.Parent
		}
		t = self.tc.GetTypeAtLocation(typeNode)
	}
	return node, sym, t
}

func (self *Checker) buildSymbolInfo(sym *ast.Symbol, location *ast.Node) zigar_typescript_compiler.SymbolInfo {
	resolvedSym := sym
	if resolvedSym.Flags()&ast.SymbolFlagsAlias != 0 {
		if aliased := self.tc.GetAliasedSymbol(resolvedSym); aliased != nil && aliased != self.tc.GetUnknownSymbol() {
			resolvedSym = aliased
		}
	}

	var symType *checker.Type
	if resolvedSym.Flags()&ast.SymbolFlagsValue != 0 {
		if location != nil {
			symType = self.tc.GetTypeOfSymbolAtLocation(resolvedSym, location)
		} else {
			symType = self.tc.GetTypeOfSymbol(resolvedSym)
		}
	} else if resolvedSym.Flags()&ast.SymbolFlagsType != 0 {
		symType = self.tc.GetDeclaredTypeOfSymbol(resolvedSym)
	} else {
		symType = self.tc.GetTypeOfSymbol(resolvedSym)
	}

	var typeText string
	if symType != nil {
		typeText = self.tc.TypeToStringEx(symType, nil, defaultTypeFormatFlags, nil)
	}

	docOpt := witTypes.None[string]()
	if doc := extractSymbolJSDoc(resolvedSym); doc != "" {
		docOpt = witTypes.Some[string](doc)
	}

	declSpanOpt := witTypes.None[zigar_typescript_types.SourceSpan]()
	if ds, ok := primaryDeclarationSpan(resolvedSym); ok {
		declSpanOpt = witTypes.Some[zigar_typescript_types.SourceSpan](ds)
	} else if ds, ok := primaryDeclarationSpan(sym); ok {
		declSpanOpt = witTypes.Some[zigar_typescript_types.SourceSpan](ds)
	}

	return zigar_typescript_compiler.SymbolInfo{
		Name:            sym.Name(),
		QualifiedName:   self.tc.GetFullyQualifiedName(resolvedSym),
		SymbolFlags:     uint32(resolvedSym.Flags()),
		TypeText:        typeText,
		Documentation:   docOpt,
		DeclarationSpan: declSpanOpt,
	}
}

func isTypeNullable(t *checker.Type) bool {
	const nullableMask = checker.TypeFlagsNull | checker.TypeFlagsUndefined
	if t.Flags()&nullableMask != 0 {
		return true
	}
	if t.IsUnion() {
		for _, member := range t.Types() {
			if member != nil && member.Flags()&nullableMask != 0 {
				return true
			}
		}
	}
	return false
}

func primaryDeclarationSpan(sym *ast.Symbol) (zigar_typescript_types.SourceSpan, bool) {
	if sym == nil {
		return zigar_typescript_types.SourceSpan{}, false
	}
	decl := sym.ValueDeclaration()
	if decl == nil {
		decls := sym.Declarations()
		if len(decls) > 0 {
			decl = decls[0]
		}
	}
	return spanFromNode(decl)
}

func extractSymbolJSDoc(sym *ast.Symbol) string {
	if sym == nil {
		return ""
	}
	var candidates []*ast.Node
	if vd := sym.ValueDeclaration(); vd != nil {
		candidates = append(candidates, vd)
	}
	for _, d := range sym.Declarations() {
		if d != nil && d != sym.ValueDeclaration() {
			candidates = append(candidates, d)
		}
	}
	for _, decl := range candidates {
		if text := extractDeclarationJSDoc(decl); text != "" {
			return text
		}
		for cur := decl; cur != nil; cur = ast.GetNextJSDocCommentLocation(cur) {
			if text := extractDeclarationJSDoc(cur); text != "" {
				return text
			}
		}
	}
	return ""
}

func extractDeclarationJSDoc(decl *ast.Node) string {
	if decl == nil {
		return ""
	}
	sf := ast.GetSourceFileOfNode(decl)
	if sf == nil {
		return ""
	}
	jsdocs := decl.JSDoc(sf)
	if len(jsdocs) == 0 {
		return ""
	}
	var parts []string
	for _, jd := range jsdocs {
		if jd == nil {
			continue
		}
		txt := strings.TrimSpace(scanner.GetTextOfJSDocComment(jd.CommentList()))
		if txt != "" {
			parts = append(parts, txt)
		}
	}
	return strings.Join(parts, "\n\n")
}
