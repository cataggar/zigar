package export_zigar_typescript_extractor

import (
	"fmt"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/jsnum"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

func (b *graphBuilder) extractExportAssignmentTarget(
	sf *ast.SourceFile,
	modID uint32,
	stmt *ast.Node,
	expr *ast.Node,
	fallbackName string,
) witTypes.Option[uint32] {
	if expr == nil {
		return witTypes.None[uint32]()
	}
	if sym := b.resolveExpressionSymbol(expr); sym != nil {
		ids := b.extractSymbolAllCategories(sym, modID, true)
		if len(ids) > 0 {
			return witTypes.Some(ids[0])
		}
	}
	// Anonymous expression export (`export default 42`, `export default { ... }`, `export = () => ...`).
	if existing, ok := b.declByNode[stmt]; ok {
		return witTypes.Some(existing)
	}
	exprType := b.tc.GetTypeAtLocation(expr)
	tyID := b.extractCheckerType(exprType)
	mods := b.extractNodeModifiers(stmt, true) | zigar_typescript_types.ModifierFlags_ConstMod
	declID := b.allocDecl(zigar_typescript_types.DeclNode{
		Name:       b.intern(fallbackName),
		ExportName: witTypes.Some(b.intern(fallbackName)),
		Module:     modID,
		Modifiers:  mods,
		Kind:       zigar_typescript_types.MakeDeclKindVariableDecl(tyID),
		Jsdoc:      b.extractJsdocForNode(stmt),
	})
	b.declByNode[stmt] = declID
	return witTypes.Some(declID)
}

func (b *graphBuilder) resolveExpressionSymbol(expr *ast.Node) *ast.Symbol {
	if expr == nil {
		return nil
	}
	sym := b.tc.GetSymbolAtLocation(expr)
	if sym == nil {
		sym = expr.Symbol()
	}
	if sym == nil {
		return nil
	}
	sym = b.resolveAliasSymbol(sym)
	return b.canonicalSymbol(sym)
}

func (b *graphBuilder) resolveExportSpecifierTarget(specNode *ast.Node) witTypes.Option[uint32] {
	if specNode == nil {
		return witTypes.None[uint32]()
	}
	sym := b.tc.GetExportSpecifierLocalTargetSymbol(specNode)
	if sym == nil && specNode.Name() != nil {
		sym = b.tc.GetSymbolAtLocation(specNode.Name())
	}
	sym = b.resolveAliasSymbol(sym)
	sym = b.canonicalSymbol(sym)
	if sym == nil {
		return witTypes.None[uint32]()
	}
	ids := b.extractSymbolIfExtractable(sym)
	if len(ids) == 0 {
		return witTypes.None[uint32]()
	}
	return witTypes.Some(ids[0])
}

func (b *graphBuilder) makeReExportDecl(
	sf *ast.SourceFile,
	modID uint32,
	node *ast.Node,
	exportName string,
	originalName string,
	sourceSpec string,
	sourceMod witTypes.Option[uint32],
	targetDecl witTypes.Option[uint32],
	isTypeOnly bool,
) uint32 {
	if node != nil {
		if existing, ok := b.declByNode[node]; ok {
			return existing
		}
	}
	var mods zigar_typescript_types.ModifierFlags = zigar_typescript_types.ModifierFlags_ExportDecl
	isNamespace := originalName == "*"
	aliasOpt := witTypes.None[uint32]()
	if exportName != "" && exportName != originalName {
		aliasOpt = witTypes.Some(b.intern(exportName))
	}
	exportNameOpt := witTypes.None[uint32]()
	if exportName != "" && exportName != "*" {
		exportNameOpt = witTypes.Some(b.intern(exportName))
	}
	declID := b.allocDecl(zigar_typescript_types.DeclNode{
		Name:       b.intern(exportName),
		ExportName: exportNameOpt,
		Module:     modID,
		Modifiers:  mods,
		Kind: zigar_typescript_types.MakeDeclKindReExportDecl(zigar_typescript_types.ReExportData{
			ModuleSpecifier: b.intern(sourceSpec),
			SourceName:      b.intern(originalName),
			ExportAlias:     aliasOpt,
			TargetDecl:      targetDecl,
			TargetModule:    sourceMod,
			IsNamespace:     isNamespace,
			IsTypeOnly:      isTypeOnly,
		}),
		Jsdoc: b.extractJsdocForNode(node),
	})
	if node != nil {
		b.declByNode[node] = declID
	}
	return declID
}

func (b *graphBuilder) extractExportedSymbol(sf *ast.SourceFile, modID uint32, expSym *ast.Symbol, markExported bool) []uint32 {
	if expSym == nil {
		return nil
	}
	// Check for `export import X = ...`
	for _, d := range expSym.Declarations() {
		if d != nil && d.Kind == ast.KindImportEqualsDeclaration {
			if idOpt := b.extractImportEqualsNode(sf, modID, d); isSome(idOpt) {
				return []uint32{idOpt.Some()}
			}
		}
	}

	exportAliasName := expSym.Name()
	target := expSym
	if target.Flags()&ast.SymbolFlagsAlias != 0 {
		if b.cfg.FollowReExports {
			target = b.resolveAliasSymbol(target)
		} else {
			if resolved := b.resolveAliasSymbol(target); resolved != nil && b.isSymbolDeclaredInFile(resolved, sf) {
				target = resolved
			}
		}
	}
	target = b.canonicalSymbol(target)
	ids := b.extractSymbolAllCategories(target, modID, markExported)
	if exportAliasName != "" && target != nil && exportAliasName != target.Name() {
		aliasID := b.intern(exportAliasName)
		for _, id := range ids {
			if isNone(b.decls[id].ExportName) {
				b.decls[id].ExportName = witTypes.Some(aliasID)
			}
		}
	}
	return ids
}

func (b *graphBuilder) extractSymbolIfExtractable(sym *ast.Symbol) []uint32 {
	sym = b.canonicalSymbol(sym)
	if sym == nil || len(sym.Declarations()) == 0 {
		return nil
	}
	var primarySF *ast.SourceFile
	for _, d := range sym.Declarations() {
		if d == nil {
			continue
		}
		sf := ast.GetSourceFileOfNode(d)
		if sf != nil && b.isExtractableSourceFile(sf) {
			primarySF = sf
			break
		}
	}
	if primarySF == nil {
		return nil
	}
	modID := b.ensureModule(primarySF, false)
	return b.extractSymbolAllCategories(sym, modID, false)
}

type categorizedDecls struct {
	cat   declCategory
	nodes []*ast.Node
}

func classifyDeclNode(d *ast.Node) declCategory {
	if d == nil {
		return declCatNone
	}
	switch d.Kind {
	case ast.KindFunctionDeclaration:
		return declCatFunction
	case ast.KindVariableDeclaration, ast.KindBindingElement:
		return declCatVariable
	case ast.KindInterfaceDeclaration:
		return declCatInterface
	case ast.KindClassDeclaration, ast.KindClassExpression:
		return declCatClass
	case ast.KindTypeAliasDeclaration:
		return declCatTypeAlias
	case ast.KindEnumDeclaration:
		return declCatEnum
	case ast.KindModuleDeclaration:
		if !ast.IsAmbientModule(d) && !ast.IsGlobalScopeAugmentation(d) {
			return declCatNamespace
		}
	case ast.KindImportEqualsDeclaration:
		return declCatImportEquals
	}
	return declCatNone
}

func (b *graphBuilder) groupSymbolCategories(sym *ast.Symbol) []categorizedDecls {
	order := []declCategory{}
	byCat := map[declCategory][]*ast.Node{}

	for _, d := range sym.Declarations() {
		if d == nil {
			continue
		}
		sf := ast.GetSourceFileOfNode(d)
		if sf != nil && !b.isExtractableSourceFile(sf) {
			continue
		}
		cat := classifyDeclNode(d)
		if cat == declCatNone {
			continue
		}
		if _, exists := byCat[cat]; !exists {
			order = append(order, cat)
		}
		byCat[cat] = append(byCat[cat], d)
	}

	result := make([]categorizedDecls, 0, len(order))
	for _, cat := range order {
		result = append(result, categorizedDecls{cat: cat, nodes: byCat[cat]})
	}
	return result
}

func (b *graphBuilder) symbolOwnerModule(nodes []*ast.Node, fallbackMod uint32) uint32 {
	for _, d := range nodes {
		if d == nil {
			continue
		}
		if sf := ast.GetSourceFileOfNode(d); sf != nil && b.isExtractableSourceFile(sf) {
			return b.ensureModule(sf, false)
		}
	}
	return fallbackMod
}

// extractSymbolAllCategories pre-allocates `decl-id`s for every distinct declaration category
// of `sym` BEFORE populating their bodies so recursive self-references and merged declarations
// (`interface Buffer` + `var Buffer`, `class Foo` + `namespace Foo`, `function fn` + `namespace fn`)
// resolve cleanly without infinite recursion.
func (b *graphBuilder) extractSymbolAllCategories(sym *ast.Symbol, fallbackMod uint32, forceExportFlag bool) []uint32 {
	sym = b.canonicalSymbol(sym)
	if sym == nil {
		return nil
	}

	groups := b.groupSymbolCategories(sym)
	if len(groups) == 0 {
		return nil
	}

	type pendingFill struct {
		id    uint32
		cat   declCategory
		nodes []*ast.Node
		modID uint32
	}

	ids := make([]uint32, 0, len(groups))
	pending := make([]pendingFill, 0, len(groups))

	// Phase 1: Pre-allocate DeclNode slots in `b.decls` and memoize `(sym, cat) -> declID`.
	for _, g := range groups {
		key := symCatKey{sym: sym, cat: g.cat}
		if existingID, ok := b.declBySymCat[key]; ok {
			if forceExportFlag {
				b.decls[existingID].Modifiers |= zigar_typescript_types.ModifierFlags_ExportDecl
			}
			ids = append(ids, existingID)
			continue
		}

		ownerMod := b.symbolOwnerModule(g.nodes, fallbackMod)
		declName := sym.Name()
		if len(g.nodes) > 0 && g.nodes[0].Name() != nil && g.nodes[0].Name().Text() != "" {
			declName = g.nodes[0].Name().Text()
		}
		mods := b.combineNodesModifiers(g.nodes, forceExportFlag)
		if g.cat == declCatVariable && len(g.nodes) > 0 && ast.IsVarConst(g.nodes[0]) {
			mods |= zigar_typescript_types.ModifierFlags_ConstMod
		}
		if g.cat == declCatEnum && len(g.nodes) > 0 && ast.GetCombinedModifierFlags(g.nodes[0])&ast.ModifierFlagsConst != 0 {
			mods |= zigar_typescript_types.ModifierFlags_ConstMod
		}

		exportNameOpt := witTypes.None[uint32]()
		if mods&zigar_typescript_types.ModifierFlags_ExportDecl != 0 {
			exportNameOpt = witTypes.Some(b.intern(declName))
		}

		placeholder := zigar_typescript_types.DeclNode{
			Name:       b.intern(declName),
			ExportName: exportNameOpt,
			Module:     ownerMod,
			Modifiers:  mods,
			TypeParams: []uint32{},
			Kind:       defaultPlaceholderDeclKind(g.cat),
			MergedWith: []uint32{},
			Jsdoc:      b.extractJsdocForNodes(g.nodes),
		}
		id := b.allocDecl(placeholder)
		b.declBySymCat[key] = id
		for _, n := range g.nodes {
			b.declByNode[n] = id
		}
		b.registerSymDecl(sym, id)
		ids = append(ids, id)
		pending = append(pending, pendingFill{id: id, cat: g.cat, nodes: g.nodes, modID: ownerMod})
	}

	// Phase 2: Populate declaration bodies/members/signatures now that all IDs exist.
	for _, item := range pending {
		b.populateDeclCategory(item.id, sym, item.cat, item.nodes, item.modID)
	}

	return ids
}

func defaultPlaceholderDeclKind(cat declCategory) zigar_typescript_types.DeclKind {
	switch cat {
	case declCatFunction:
		return zigar_typescript_types.MakeDeclKindFunctionDecl([]uint32{})
	case declCatInterface:
		return zigar_typescript_types.MakeDeclKindInterfaceDecl(zigar_typescript_types.InterfaceData{
			ExtendsClauses:      []zigar_typescript_types.HeritageClause{},
			Properties:          []uint32{},
			Methods:             []zigar_typescript_types.MethodNode{},
			CallSignatures:      []uint32{},
			ConstructSignatures: []uint32{},
			IndexSignatures:     []zigar_typescript_types.IndexSigNode{},
		})
	case declCatClass:
		return zigar_typescript_types.MakeDeclKindClassDecl(zigar_typescript_types.ClassData{
			ExtendsClause:     witTypes.None[zigar_typescript_types.HeritageClause](),
			ImplementsClauses: []zigar_typescript_types.HeritageClause{},
			Constructors:      []uint32{},
			Properties:        []uint32{},
			Methods:           []zigar_typescript_types.MethodNode{},
			IndexSignatures:   []zigar_typescript_types.IndexSigNode{},
		})
	case declCatTypeAlias:
		return zigar_typescript_types.MakeDeclKindTypeAliasDecl(0)
	case declCatEnum:
		return zigar_typescript_types.MakeDeclKindEnumDecl(zigar_typescript_types.EnumData{
			IsConst: false,
			Members: []zigar_typescript_types.EnumMemberNode{},
		})
	case declCatNamespace:
		return zigar_typescript_types.MakeDeclKindNamespaceDecl([]uint32{})
	default:
		return zigar_typescript_types.MakeDeclKindVariableDecl(0)
	}
}

func (b *graphBuilder) populateDeclCategory(declID uint32, sym *ast.Symbol, cat declCategory, nodes []*ast.Node, modID uint32) {
	switch cat {
	case declCatFunction:
		sigs := b.extractFunctionOverloadSigs(nodes)
		tpIDs := []uint32{}
		if len(sigs) > 0 {
			tpIDs = b.signatures[sigs[0]].TypeParams
		}
		b.decls[declID].TypeParams = tpIDs
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindFunctionDecl(sigs)

	case declCatVariable:
		d := nodes[0]
		tyID := b.extractVariableDeclType(d, sym)
		if ast.IsVarConst(d) {
			b.decls[declID].Modifiers |= zigar_typescript_types.ModifierFlags_ConstMod
		}
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindVariableDecl(tyID)

	case declCatInterface:
		tpIDs, ifaceData := b.extractMergedInterfaceDecls(nodes)
		b.decls[declID].TypeParams = tpIDs
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindInterfaceDecl(ifaceData)

	case declCatClass:
		tpIDs, classData := b.extractClassDecl(nodes[0])
		b.decls[declID].TypeParams = tpIDs
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindClassDecl(classData)

	case declCatTypeAlias:
		d := nodes[0]
		ta := d.AsTypeAliasDeclaration()
		tpIDs := b.extractTypeParamList(d.TypeParameters())
		var targetTyID uint32
		if ta != nil && ta.Type != nil {
			targetTyID = b.extractTypeNode(ta.Type)
			if b.cfg.ExpandUtilityTypes {
				b.populateExpandedResolvedType(targetTyID, b.tc.GetDeclaredTypeOfSymbol(sym))
			}
		} else {
			targetTyID = b.extractCheckerType(b.tc.GetDeclaredTypeOfSymbol(sym))
		}
		b.decls[declID].TypeParams = tpIDs
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindTypeAliasDecl(targetTyID)

	case declCatEnum:
		enumData := b.extractMergedEnumDecls(nodes)
		if enumData.IsConst {
			b.decls[declID].Modifiers |= zigar_typescript_types.ModifierFlags_ConstMod
		}
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindEnumDecl(enumData)

	case declCatNamespace:
		nsDecls := b.extractMergedNamespaceDecls(nodes, sym, modID)
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindNamespaceDecl(nsDecls)

	case declCatImportEquals:
		ieData := b.buildImportEqualsData(ast.GetSourceFileOfNode(nodes[0]), nodes[0])
		b.decls[declID].Kind = zigar_typescript_types.MakeDeclKindImportEqualsDecl(ieData)
	}
}

func (b *graphBuilder) extractVariableDeclType(d *ast.Node, sym *ast.Symbol) uint32 {
	if d != nil && d.Kind == ast.KindVariableDeclaration {
		vd := d.AsVariableDeclaration()
		if vd != nil && vd.Type != nil {
			tyID := b.extractTypeNode(vd.Type)
			// Preserve unique symbol identity (`declare const sym: unique symbol`) so `[sym]` links back cleanly.
			if b.types[tyID].Kind.Tag() == zigar_typescript_types.TypeKind_UniqueSymbol && sym != nil {
				b.types[tyID].Kind = zigar_typescript_types.MakeTypeKindUniqueSymbol(b.intern(sym.Name()))
			}
			return tyID
		}
	}
	if d != nil {
		return b.extractCheckerType(b.tc.GetTypeAtLocation(d))
	}
	if sym != nil {
		return b.extractCheckerType(b.tc.GetTypeOfSymbol(sym))
	}
	return b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
}

func (b *graphBuilder) extractFunctionOverloadSigs(nodes []*ast.Node) []uint32 {
	hasBodyless := false
	for _, n := range nodes {
		if n != nil && n.Body() == nil {
			hasBodyless = true
			break
		}
	}
	sigs := make([]uint32, 0, len(nodes))
	for _, n := range nodes {
		if n == nil {
			continue
		}
		if hasBodyless && n.Body() != nil {
			continue
		}
		sigs = append(sigs, b.extractSignatureFromDecl(n))
	}
	return sigs
}

func (b *graphBuilder) extractMergedEnumDecls(nodes []*ast.Node) zigar_typescript_types.EnumData {
	isConst := false
	members := []zigar_typescript_types.EnumMemberNode{}
	for _, n := range nodes {
		if n == nil || n.Kind != ast.KindEnumDeclaration {
			continue
		}
		if ast.GetCombinedModifierFlags(n)&ast.ModifierFlagsConst != 0 {
			isConst = true
		}
		ed := n.AsEnumDeclaration()
		if ed == nil || ed.Members == nil {
			continue
		}
		for _, m := range ed.Members.Nodes {
			if m == nil || m.Kind != ast.KindEnumMember {
				continue
			}
			em := m.AsEnumMember()
			if em == nil || em.Name() == nil {
				continue
			}
			memberName := b.propertyNameText(em.Name())
			valOpt := witTypes.None[zigar_typescript_types.LiteralValue]()
			cv := b.tc.GetConstantValue(m)
			switch v := cv.(type) {
			case string:
				valOpt = witTypes.Some(zigar_typescript_types.MakeLiteralValueStr(b.intern(v)))
			case jsnum.Number:
				valOpt = witTypes.Some(zigar_typescript_types.MakeLiteralValueNum(float64(v)))
			case float64:
				valOpt = witTypes.Some(zigar_typescript_types.MakeLiteralValueNum(v))
			case int:
				valOpt = witTypes.Some(zigar_typescript_types.MakeLiteralValueNum(float64(v)))
			}
			members = append(members, zigar_typescript_types.EnumMemberNode{
				Name:  b.intern(memberName),
				Value: valOpt,
				Jsdoc: b.extractJsdocForNode(m),
			})
		}
	}
	return zigar_typescript_types.EnumData{
		IsConst: isConst,
		Members: members,
	}
}

func (b *graphBuilder) extractMergedNamespaceDecls(nodes []*ast.Node, sym *ast.Symbol, modID uint32) []uint32 {
	out := []uint32{}
	seen := map[uint32]bool{}
	add := func(id uint32) {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}

	for _, n := range nodes {
		if n == nil || n.Kind != ast.KindModuleDeclaration {
			continue
		}
		sf := ast.GetSourceFileOfNode(n)
		body := n.Body()
		if body != nil && body.Kind == ast.KindModuleDeclaration {
			if bodySym := b.canonicalSymbol(body.Symbol()); bodySym != nil {
				for _, id := range b.extractSymbolAllCategories(bodySym, modID, true) {
					add(id)
				}
				continue
			}
		}
		if body != nil && body.Kind == ast.KindModuleBlock {
			isAmbientCtx := ast.GetCombinedModifierFlags(n)&ast.ModifierFlagsAmbient != 0 || (sf != nil && sf.IsDeclarationFile)
			for _, id := range b.extractStatementBlockDecls(sf, modID, body, !isAmbientCtx) {
				add(id)
			}
		}
	}

	if sym != nil {
		for _, expSym := range b.tc.GetExportsOfModule(sym) {
			if expSym == nil || expSym.Name() == "export=" {
				continue
			}
			sf := b.sfByModule[modID]
			for _, id := range b.extractExportedSymbol(sf, modID, expSym, true) {
				add(id)
			}
		}
	}

	return out
}

func (b *graphBuilder) extractImportEqualsNode(sf *ast.SourceFile, modID uint32, node *ast.Node) witTypes.Option[uint32] {
	if node == nil || node.Kind != ast.KindImportEqualsDeclaration {
		return witTypes.None[uint32]()
	}
	if sym := b.canonicalSymbol(node.Symbol()); sym != nil && classifyDeclNode(node) == declCatImportEquals {
		key := symCatKey{sym: sym, cat: declCatImportEquals}
		if existing, ok := b.declBySymCat[key]; ok {
			return witTypes.Some(existing)
		}
	}
	if existing, ok := b.declByNode[node]; ok {
		return witTypes.Some(existing)
	}
	name := ""
	if node.Name() != nil {
		name = node.Name().Text()
	}
	mods := b.extractNodeModifiers(node, false)
	exportNameOpt := witTypes.None[uint32]()
	if mods&zigar_typescript_types.ModifierFlags_ExportDecl != 0 && name != "" {
		exportNameOpt = witTypes.Some(b.intern(name))
	}
	ieData := b.buildImportEqualsData(sf, node)
	declID := b.allocDecl(zigar_typescript_types.DeclNode{
		Name:       b.intern(name),
		ExportName: exportNameOpt,
		Module:     modID,
		Modifiers:  mods,
		Kind:       zigar_typescript_types.MakeDeclKindImportEqualsDecl(ieData),
		Jsdoc:      b.extractJsdocForNode(node),
	})
	b.declByNode[node] = declID
	return witTypes.Some(declID)
}

func (b *graphBuilder) buildImportEqualsData(sf *ast.SourceFile, node *ast.Node) zigar_typescript_types.ImportEqualsData {
	if node == nil || node.Kind != ast.KindImportEqualsDeclaration {
		return zigar_typescript_types.ImportEqualsData{
			ModuleSpecifier: witTypes.None[uint32](),
			EntityPath:      []uint32{},
			TargetDecl:      witTypes.None[uint32](),
			IsTypeOnly:      false,
		}
	}
	ie := node.AsImportEqualsDeclaration()
	if ie == nil || ie.ModuleReference == nil {
		return zigar_typescript_types.ImportEqualsData{
			ModuleSpecifier: witTypes.None[uint32](),
			EntityPath:      []uint32{},
			TargetDecl:      witTypes.None[uint32](),
			IsTypeOnly:      false,
		}
	}
	if ie.ModuleReference.Kind == ast.KindExternalModuleReference {
		emr := ie.ModuleReference.AsExternalModuleReference()
		specOpt := witTypes.None[uint32]()
		targetDecl := witTypes.None[uint32]()
		if emr != nil && emr.Expression != nil && ast.IsStringLiteralLike(emr.Expression) {
			specText := emr.Expression.Text()
			specOpt = witTypes.Some(b.intern(specText))
			if targetSF := b.resolveModuleSpecifierNode(sf, emr.Expression); targetSF != nil && b.isExtractableSourceFile(targetSF) {
				targetModID := b.ensureModuleWithSpecifier(targetSF, specText, b.cfg.FollowReExports)
				if b.cfg.FollowReExports {
					if resolvedSym := b.resolveExpressionSymbol(ie.ModuleReference); resolvedSym != nil {
						ids := b.extractSymbolAllCategories(resolvedSym, targetModID, false)
						if len(ids) > 0 {
							targetDecl = witTypes.Some(ids[0])
						}
					}
				}
			}
		}
		return zigar_typescript_types.ImportEqualsData{
			ModuleSpecifier: specOpt,
			EntityPath:      []uint32{},
			TargetDecl:      targetDecl,
			IsTypeOnly:      ie.IsTypeOnly,
		}
	}

	// EntityName (`import X = Ns.Y`)
	entityParts := b.entityNameParts(ie.ModuleReference)
	targetDecl := witTypes.None[uint32]()
	if sym := b.resolveExpressionSymbol(ie.ModuleReference); sym != nil {
		ids := b.extractSymbolIfExtractable(sym)
		if len(ids) > 0 {
			targetDecl = witTypes.Some(ids[0])
		}
	}
	return zigar_typescript_types.ImportEqualsData{
		ModuleSpecifier: witTypes.None[uint32](),
		EntityPath:      entityParts,
		TargetDecl:      targetDecl,
		IsTypeOnly:      ie.IsTypeOnly,
	}
}

func (b *graphBuilder) extractStatementBlockDecls(sf *ast.SourceFile, modID uint32, body *ast.Node, requireExportMod bool) []uint32 {
	if body == nil {
		return []uint32{}
	}
	if body.Kind == ast.KindModuleDeclaration {
		if sym := b.canonicalSymbol(body.Symbol()); sym != nil {
			return b.extractSymbolAllCategories(sym, modID, true)
		}
	}
	if body.Kind != ast.KindModuleBlock {
		return []uint32{}
	}
	mb := body.AsModuleBlock()
	if mb == nil || mb.Statements == nil {
		return []uint32{}
	}
	return b.extractStatementsList(sf, modID, mb.Statements.Nodes, requireExportMod, false)
}

func (b *graphBuilder) extractTopLevelGlobalStatements(sf *ast.SourceFile, modID uint32, stmts []*ast.Node) []uint32 {
	return b.extractStatementsList(sf, modID, stmts, false, true)
}

func (b *graphBuilder) extractStatementsList(
	sf *ast.SourceFile,
	modID uint32,
	stmts []*ast.Node,
	requireExportMod bool,
	skipAmbientAndGlobalBlocks bool,
) []uint32 {
	out := []uint32{}
	seen := map[uint32]bool{}
	add := func(id uint32) {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}

	for _, stmt := range stmts {
		if stmt == nil {
			continue
		}
		if requireExportMod && ast.GetCombinedModifierFlags(stmt)&ast.ModifierFlagsExport == 0 &&
			stmt.Kind != ast.KindExportDeclaration && stmt.Kind != ast.KindExportAssignment {
			continue
		}

		switch stmt.Kind {
		case ast.KindFunctionDeclaration,
			ast.KindInterfaceDeclaration,
			ast.KindClassDeclaration,
			ast.KindTypeAliasDeclaration,
			ast.KindEnumDeclaration:
			if sym := b.canonicalSymbol(stmt.Symbol()); sym != nil {
				for _, id := range b.extractSymbolAllCategories(sym, modID, requireExportMod) {
					add(id)
				}
			}

		case ast.KindVariableStatement:
			vs := stmt.AsVariableStatement()
			if vs != nil && vs.DeclarationList != nil && vs.DeclarationList.Kind == ast.KindVariableDeclarationList {
				vdl := vs.DeclarationList.AsVariableDeclarationList()
				if vdl != nil && vdl.Declarations != nil {
					for _, vd := range vdl.Declarations.Nodes {
						for _, sym := range b.collectBindingSymbols(vd) {
							for _, id := range b.extractSymbolAllCategories(sym, modID, requireExportMod) {
								add(id)
							}
						}
					}
				}
			}

		case ast.KindModuleDeclaration:
			if skipAmbientAndGlobalBlocks && (ast.IsAmbientModule(stmt) || ast.IsGlobalScopeAugmentation(stmt)) {
				continue
			}
			if ast.IsGlobalScopeAugmentation(stmt) {
				for _, id := range b.extractStatementBlockDecls(sf, modID, stmt.Body(), false) {
					add(id)
				}
				continue
			}
			if sym := b.canonicalSymbol(stmt.Symbol()); sym != nil {
				for _, id := range b.extractSymbolAllCategories(sym, modID, requireExportMod) {
					add(id)
				}
			}

		case ast.KindImportEqualsDeclaration:
			if idOpt := b.extractImportEqualsNode(sf, modID, stmt); isSome(idOpt) {
				add(idOpt.Some())
			}
		}
	}

	return out
}

func (b *graphBuilder) collectBindingSymbols(decl *ast.Node) []*ast.Symbol {
	if decl == nil {
		return nil
	}
	nameNode := decl.Name()
	if nameNode == nil {
		return nil
	}
	if nameNode.Kind == ast.KindIdentifier {
		if sym := b.canonicalSymbol(decl.Symbol()); sym != nil {
			return []*ast.Symbol{sym}
		}
		return nil
	}
	var out []*ast.Symbol
	var walk func(n *ast.Node)
	walk = func(n *ast.Node) {
		if n == nil {
			return
		}
		if n.Kind == ast.KindObjectBindingPattern || n.Kind == ast.KindArrayBindingPattern {
			bp := n.AsBindingPattern()
			if bp != nil && bp.Elements != nil {
				for _, el := range bp.Elements.Nodes {
					if el == nil || el.Kind != ast.KindBindingElement {
						continue
					}
					elName := el.Name()
					if elName == nil {
						continue
					}
					if elName.Kind == ast.KindIdentifier {
						if sym := b.canonicalSymbol(el.Symbol()); sym != nil {
							out = append(out, sym)
						}
					} else {
						walk(elName)
					}
				}
			}
		}
	}
	walk(nameNode)
	return out
}

func (b *graphBuilder) combineNodesModifiers(nodes []*ast.Node, forceExport bool) zigar_typescript_types.ModifierFlags {
	var out zigar_typescript_types.ModifierFlags
	if forceExport {
		out |= zigar_typescript_types.ModifierFlags_ExportDecl
	}
	for _, n := range nodes {
		out |= b.extractNodeModifiers(n, false)
	}
	return out
}

func (b *graphBuilder) extractNodeModifiers(node *ast.Node, forceExport bool) zigar_typescript_types.ModifierFlags {
	var out zigar_typescript_types.ModifierFlags
	if forceExport {
		out |= zigar_typescript_types.ModifierFlags_ExportDecl
	}
	if node == nil {
		return out
	}
	flags := ast.GetCombinedModifierFlags(node)
	if flags&ast.ModifierFlagsExport != 0 {
		out |= zigar_typescript_types.ModifierFlags_ExportDecl
	}
	if flags&ast.ModifierFlagsDefault != 0 {
		out |= zigar_typescript_types.ModifierFlags_DefaultExport
	}
	if flags&ast.ModifierFlagsAmbient != 0 {
		out |= zigar_typescript_types.ModifierFlags_DeclareAmbient
	}
	if flags&ast.ModifierFlagsAbstract != 0 {
		out |= zigar_typescript_types.ModifierFlags_AbstractMod
	}
	if flags&ast.ModifierFlagsReadonly != 0 {
		out |= zigar_typescript_types.ModifierFlags_ReadonlyMod
	}
	if flags&ast.ModifierFlagsStatic != 0 {
		out |= zigar_typescript_types.ModifierFlags_StaticMod
	}
	if flags&ast.ModifierFlagsAsync != 0 {
		out |= zigar_typescript_types.ModifierFlags_AsyncMod
	}
	if flags&ast.ModifierFlagsConst != 0 {
		out |= zigar_typescript_types.ModifierFlags_ConstMod
	}
	if flags&ast.ModifierFlagsPublic != 0 {
		out |= zigar_typescript_types.ModifierFlags_PublicMod
	}
	if flags&ast.ModifierFlagsPrivate != 0 || (node.Name() != nil && node.Name().Kind == ast.KindPrivateIdentifier) {
		out |= zigar_typescript_types.ModifierFlags_PrivateMod
	}
	if flags&ast.ModifierFlagsProtected != 0 {
		out |= zigar_typescript_types.ModifierFlags_ProtectedMod
	}
	if flags&ast.ModifierFlagsOverride != 0 {
		out |= zigar_typescript_types.ModifierFlags_OverrideMod
	}
	if flags&ast.ModifierFlagsAccessor != 0 {
		out |= zigar_typescript_types.ModifierFlags_AccessorMod
	}
	if ast.HasQuestionToken(node) {
		out |= zigar_typescript_types.ModifierFlags_OptionalMod
	}
	return out
}

func (b *graphBuilder) entityNameParts(node *ast.Node) []uint32 {
	raw := entityNameRawParts(node)
	out := make([]uint32, 0, len(raw))
	for _, s := range raw {
		if s != "" {
			out = append(out, b.intern(s))
		}
	}
	return out
}

func entityNameRawParts(node *ast.Node) []string {
	if node == nil {
		return nil
	}
	switch node.Kind {
	case ast.KindIdentifier, ast.KindPrivateIdentifier:
		return []string{node.Text()}
	case ast.KindThisKeyword:
		return []string{"this"}
	case ast.KindQualifiedName:
		qn := node.AsQualifiedName()
		if qn != nil {
			return append(entityNameRawParts(qn.Left), entityNameRawParts(qn.Right)...)
		}
	case ast.KindPropertyAccessExpression:
		pae := node.AsPropertyAccessExpression()
		if pae != nil {
			return append(entityNameRawParts(pae.Expression), entityNameRawParts(pae.Name())...)
		}
	}
	return nil
}

func entityNameToString(node *ast.Node) string {
	parts := entityNameRawParts(node)
	if len(parts) == 0 {
		return fmt.Sprintf("")
	}
	return strings.Join(parts, ".")
}

