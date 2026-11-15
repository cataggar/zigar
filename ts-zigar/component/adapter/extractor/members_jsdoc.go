package export_zigar_typescript_extractor

import (
	"fmt"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/checker"
	"github.com/microsoft/TypeScript/tsc/internal/scanner"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

func (b *graphBuilder) extractMergedInterfaceDecls(nodes []*ast.Node) ([]uint32, zigar_typescript_types.InterfaceData) {
	var tpIDs []uint32
	for _, n := range nodes {
		if n != nil && len(n.TypeParameters()) > 0 {
			tpIDs = b.extractTypeParamList(n.TypeParameters())
			break
		}
	}
	if tpIDs == nil {
		tpIDs = []uint32{}
	}

	extendsClauses := []zigar_typescript_types.HeritageClause{}
	var allMembers []*ast.Node

	for _, n := range nodes {
		if n == nil || n.Kind != ast.KindInterfaceDeclaration {
			continue
		}
		id := n.AsInterfaceDeclaration()
		if id == nil {
			continue
		}
		if id.HeritageClauses != nil {
			for _, hcNode := range id.HeritageClauses.Nodes {
				if hcNode == nil || hcNode.Kind != ast.KindHeritageClause {
					continue
				}
				hc := hcNode.AsHeritageClause()
				if hc != nil && hc.Token == ast.KindExtendsKeyword && hc.Types != nil {
					for _, expr := range hc.Types.Nodes {
						extendsClauses = append(extendsClauses, b.extractHeritageExpr(expr))
					}
				}
			}
		}
		if id.Members != nil {
			allMembers = append(allMembers, id.Members.Nodes...)
		}
	}

	props, methods, callSigs, ctorSigs, indexSigs, _ := b.extractMemberNodes(allMembers, false)
	return tpIDs, zigar_typescript_types.InterfaceData{
		ExtendsClauses:      extendsClauses,
		Properties:          props,
		Methods:             methods,
		CallSignatures:      callSigs,
		ConstructSignatures: ctorSigs,
		IndexSignatures:     indexSigs,
	}
}

func (b *graphBuilder) extractClassDecl(node *ast.Node) ([]uint32, zigar_typescript_types.ClassData) {
	if node == nil {
		return []uint32{}, zigar_typescript_types.ClassData{
			ExtendsClause:     witTypes.None[zigar_typescript_types.HeritageClause](),
			ImplementsClauses: []zigar_typescript_types.HeritageClause{},
			Constructors:      []uint32{},
			Properties:        []uint32{},
			Methods:           []zigar_typescript_types.MethodNode{},
			IndexSignatures:   []zigar_typescript_types.IndexSigNode{},
		}
	}

	tpIDs := b.extractTypeParamList(node.TypeParameters())
	extendsOpt := witTypes.None[zigar_typescript_types.HeritageClause]()
	implementsList := []zigar_typescript_types.HeritageClause{}

	var heritageList *ast.NodeList
	var members []*ast.Node
	if node.Kind == ast.KindClassDeclaration {
		cd := node.AsClassDeclaration()
		if cd != nil {
			heritageList = cd.HeritageClauses
			if cd.Members != nil {
				members = cd.Members.Nodes
			}
		}
	} else if node.Kind == ast.KindClassExpression {
		ce := node.AsClassExpression()
		if ce != nil {
			heritageList = ce.HeritageClauses
			if ce.Members != nil {
				members = ce.Members.Nodes
			}
		}
	}

	if heritageList != nil {
		for _, hcNode := range heritageList.Nodes {
			if hcNode == nil || hcNode.Kind != ast.KindHeritageClause {
				continue
			}
			hc := hcNode.AsHeritageClause()
			if hc == nil || hc.Types == nil {
				continue
			}
			if hc.Token == ast.KindExtendsKeyword && len(hc.Types.Nodes) > 0 {
				extendsOpt = witTypes.Some(b.extractHeritageExpr(hc.Types.Nodes[0]))
			} else if hc.Token == ast.KindImplementsKeyword {
				for _, expr := range hc.Types.Nodes {
					implementsList = append(implementsList, b.extractHeritageExpr(expr))
				}
			}
		}
	}

	props, methods, _, _, indexSigs, ctors := b.extractMemberNodes(members, true)
	return tpIDs, zigar_typescript_types.ClassData{
		ExtendsClause:     extendsOpt,
		ImplementsClauses: implementsList,
		Constructors:      ctors,
		Properties:        props,
		Methods:           methods,
		IndexSignatures:   indexSigs,
	}
}

func (b *graphBuilder) extractObjectLiteralMembersAST(tl *ast.TypeLiteralNode) zigar_typescript_types.ObjectTypeData {
	if tl == nil || tl.Members == nil {
		return zigar_typescript_types.ObjectTypeData{
			Properties:          []uint32{},
			CallSignatures:      []uint32{},
			ConstructSignatures: []uint32{},
			IndexSignatures:     []zigar_typescript_types.IndexSigNode{},
		}
	}
	props, methods, callSigs, ctorSigs, indexSigs, _ := b.extractMemberNodes(tl.Members.Nodes, false)
	// On anonymous `object-literal`, WIT `ObjectTypeData` represents method signatures (`{ foo(x: number): void }`)
	// as function-typed properties in `Properties` so zero method members on `{ ... }` type literals are lost!
	for _, m := range methods {
		var tyID uint32
		if len(m.Signatures) == 1 {
			tyID = b.allocType(zigar_typescript_types.MakeTypeKindFunctionType(m.Signatures[0]))
		} else {
			parts := make([]uint32, 0, len(m.Signatures))
			for _, sigID := range m.Signatures {
				parts = append(parts, b.allocType(zigar_typescript_types.MakeTypeKindFunctionType(sigID)))
			}
			tyID = b.allocType(zigar_typescript_types.MakeTypeKindIntersection(parts))
		}
		propID := b.allocProp(zigar_typescript_types.PropNode{
			Name:           m.Name,
			ComputedSymbol: m.ComputedSymbol,
			Ty:             tyID,
			SetterTy:       witTypes.None[uint32](),
			HasGetter:      false,
			HasSetter:      false,
			Modifiers:      m.Modifiers,
			Jsdoc:          m.Jsdoc,
		})
		props = append(props, propID)
	}

	return zigar_typescript_types.ObjectTypeData{
		Properties:          props,
		CallSignatures:      callSigs,
		ConstructSignatures: ctorSigs,
		IndexSignatures:     indexSigs,
	}
}

type accessorAccum struct {
	name      string
	symKey    witTypes.Option[zigar_typescript_types.SymbolKey]
	getter    *ast.Node
	setter    *ast.Node
	modifiers zigar_typescript_types.ModifierFlags
	nodes     []*ast.Node
}

type methodAccum struct {
	name      string
	symKey    witTypes.Option[zigar_typescript_types.SymbolKey]
	modifiers zigar_typescript_types.ModifierFlags
	decls     []*ast.Node
}

func (b *graphBuilder) extractMemberNodes(
	members []*ast.Node,
	isClass bool,
) (
	props []uint32,
	methods []zigar_typescript_types.MethodNode,
	callSigs []uint32,
	ctorSigs []uint32,
	indexSigs []zigar_typescript_types.IndexSigNode,
	constructors []uint32,
) {
	props = []uint32{}
	methods = []zigar_typescript_types.MethodNode{}
	callSigs = []uint32{}
	ctorSigs = []uint32{}
	indexSigs = []zigar_typescript_types.IndexSigNode{}
	constructors = []uint32{}

	var ctorDecls []*ast.Node
	var accessorOrder []string
	accessors := map[string]*accessorAccum{}
	var methodOrder []string
	methodGroups := map[string]*methodAccum{}

	for _, m := range members {
		if m == nil {
			continue
		}
		if !b.cfg.IncludePrivateMembers && b.isPrivateMemberNode(m) {
			continue
		}

		switch m.Kind {
		case ast.KindConstructor:
			ctorDecls = append(ctorDecls, m)
			// Also extract TypeScript parameter properties (`constructor(public readonly x: number)`).
			if pl := m.ParameterList(); pl != nil {
				for _, p := range pl.Nodes {
					if p != nil && ast.IsParameterPropertyDeclaration(p, m) {
						if !b.cfg.IncludePrivateMembers && b.isPrivateMemberNode(p) {
							continue
						}
						props = append(props, b.extractPropertyNode(p))
					}
				}
			}

		case ast.KindPropertySignature, ast.KindPropertyDeclaration:
			props = append(props, b.extractPropertyNode(m))

		case ast.KindGetAccessor, ast.KindSetAccessor:
			name, symKey := b.resolveMemberNameAndSymbolKey(m.Name(), m.Symbol())
			isStatic := ast.GetCombinedModifierFlags(m)&ast.ModifierFlagsStatic != 0
			groupKey := fmt.Sprintf("%t:%s", isStatic, name)
			acc, exists := accessors[groupKey]
			if !exists {
				acc = &accessorAccum{name: name, symKey: symKey}
				accessors[groupKey] = acc
				accessorOrder = append(accessorOrder, groupKey)
			}
			acc.modifiers |= b.extractNodeModifiers(m, false) | zigar_typescript_types.ModifierFlags_AccessorMod
			acc.nodes = append(acc.nodes, m)
			if m.Kind == ast.KindGetAccessor {
				acc.getter = m
			} else {
				acc.setter = m
			}

		case ast.KindMethodSignature, ast.KindMethodDeclaration:
			name, symKey := b.resolveMemberNameAndSymbolKey(m.Name(), m.Symbol())
			isStatic := ast.GetCombinedModifierFlags(m)&ast.ModifierFlagsStatic != 0
			groupKey := fmt.Sprintf("%t:%s", isStatic, name)
			mg, exists := methodGroups[groupKey]
			if !exists {
				mg = &methodAccum{name: name, symKey: symKey}
				methodGroups[groupKey] = mg
				methodOrder = append(methodOrder, groupKey)
			}
			mg.modifiers |= b.extractNodeModifiers(m, false)
			mg.decls = append(mg.decls, m)

		case ast.KindCallSignature:
			callSigs = append(callSigs, b.extractSignatureFromDecl(m))

		case ast.KindConstructSignature:
			ctorSigs = append(ctorSigs, b.extractSignatureFromDecl(m))

		case ast.KindIndexSignature:
			if idx, ok := b.extractIndexSigNode(m); ok {
				indexSigs = append(indexSigs, idx)
			}
		}
	}

	// Finalize constructors (dropping implementation body when overload declarations exist).
	if len(ctorDecls) > 0 {
		constructors = b.extractFunctionOverloadSigs(ctorDecls)
	}

	// Finalize merged getters/setters (including divergent `get x(): A` / `set x(v: B)`!).
	for _, key := range accessorOrder {
		acc := accessors[key]
		hasGetter := acc.getter != nil
		hasSetter := acc.setter != nil
		var getterTyID uint32
		var setterParamTyNode *ast.Node
		var setterTyID uint32

		if hasSetter {
			if pl := acc.setter.ParameterList(); pl != nil && len(pl.Nodes) > 0 {
				p0 := pl.Nodes[0]
				if p0 != nil {
					if p0.Type() != nil {
						setterParamTyNode = p0.Type()
						setterTyID = b.extractTypeNode(setterParamTyNode)
					} else {
						setterTyID = b.extractCheckerType(b.tc.GetTypeAtLocation(p0))
					}
				}
			}
		}

		if hasGetter {
			if acc.getter.Type() != nil {
				getterTyID = b.extractTypeNode(acc.getter.Type())
			} else {
				sig := b.tc.GetSignatureFromDeclaration(acc.getter)
				if sig != nil {
					getterTyID = b.extractCheckerType(b.tc.GetReturnTypeOfSignature(sig))
				} else {
					getterTyID = b.extractCheckerType(b.tc.GetTypeAtLocation(acc.getter))
				}
			}
		} else if hasSetter {
			getterTyID = setterTyID
		}

		setterOpt := witTypes.None[uint32]()
		if hasGetter && hasSetter && setterTyID != 0 {
			// Check whether setter parameter type diverges from getter return type!
			getterCheckerTy := b.tc.GetTypeAtLocation(acc.getter)
			var setterCheckerTy *checker.Type
			if pl := acc.setter.ParameterList(); pl != nil && len(pl.Nodes) > 0 {
				setterCheckerTy = b.tc.GetTypeAtLocation(pl.Nodes[0])
			}
			if setterTyID != getterTyID && (getterCheckerTy == nil || setterCheckerTy == nil || getterCheckerTy != setterCheckerTy) {
				setterOpt = witTypes.Some(setterTyID)
			}
		}
		if hasGetter && !hasSetter {
			acc.modifiers |= zigar_typescript_types.ModifierFlags_ReadonlyMod
		}

		propID := b.allocProp(zigar_typescript_types.PropNode{
			Name:           b.intern(acc.name),
			ComputedSymbol: acc.symKey,
			Ty:             getterTyID,
			SetterTy:       setterOpt,
			HasGetter:      hasGetter,
			HasSetter:      hasSetter,
			Modifiers:      acc.modifiers,
			Jsdoc:          b.extractJsdocForNodes(acc.nodes),
		})
		props = append(props, propID)
	}

	// Finalize overloaded methods.
	for _, key := range methodOrder {
		mg := methodGroups[key]
		sigs := b.extractFunctionOverloadSigs(mg.decls)
		methods = append(methods, zigar_typescript_types.MethodNode{
			Name:           b.intern(mg.name),
			ComputedSymbol: mg.symKey,
			Signatures:     sigs,
			Modifiers:      mg.modifiers,
			Jsdoc:          b.extractJsdocForNodes(mg.decls),
		})
	}

	return props, methods, callSigs, ctorSigs, indexSigs, constructors
}

func (b *graphBuilder) extractPropertyNode(node *ast.Node) uint32 {
	name, symKey := b.resolveMemberNameAndSymbolKey(node.Name(), node.Symbol())
	var tyID uint32
	if node.Type() != nil {
		tyID = b.extractTypeNode(node.Type())
	} else {
		tyID = b.extractCheckerType(b.tc.GetTypeAtLocation(node))
	}
	return b.allocProp(zigar_typescript_types.PropNode{
		Name:           b.intern(name),
		ComputedSymbol: symKey,
		Ty:             tyID,
		SetterTy:       witTypes.None[uint32](),
		HasGetter:      false,
		HasSetter:      false,
		Modifiers:      b.extractNodeModifiers(node, false),
		Jsdoc:          b.extractJsdocForNode(node),
	})
}

func (b *graphBuilder) extractCheckerPropertySymbol(sym *ast.Symbol, containingType *checker.Type) uint32 {
	var firstDecl *ast.Node
	var getterDecl, setterDecl *ast.Node
	for _, d := range sym.Declarations() {
		if d == nil {
			continue
		}
		if firstDecl == nil {
			firstDecl = d
		}
		if d.Kind == ast.KindGetAccessor {
			getterDecl = d
		} else if d.Kind == ast.KindSetAccessor {
			setterDecl = d
		}
	}

	var nameNode *ast.Node
	if firstDecl != nil {
		nameNode = firstDecl.Name()
	}
	name, symKey := b.resolveMemberNameAndSymbolKey(nameNode, sym)

	var mods zigar_typescript_types.ModifierFlags
	if firstDecl != nil {
		mods = b.extractNodeModifiers(firstDecl, false)
	}
	if sym.Flags()&ast.SymbolFlagsOptional != 0 {
		mods |= zigar_typescript_types.ModifierFlags_OptionalMod
	}
	if b.tc.IsReadonlySymbol(sym) {
		mods |= zigar_typescript_types.ModifierFlags_ReadonlyMod
	}

	propTy := b.tc.GetTypeOfPropertyOfType(containingType, sym.Name())
	if propTy == nil {
		propTy = b.tc.GetTypeOfSymbol(sym)
	}
	if sym.Flags()&ast.SymbolFlagsOptional != 0 &&
		propTy != nil &&
		propTy.Flags()&checker.TypeFlagsUnion != 0 &&
		(firstDecl == nil || !typeNodeHasExplicitUndefined(firstDecl.Type())) {
		if stripped := b.tc.RemoveMissingOrUndefinedType(propTy); stripped != nil && stripped.Flags()&checker.TypeFlagsNever == 0 {
			propTy = stripped
		}
	}
	tyID := b.extractCheckerType(propTy)

	hasGetter := sym.Flags()&ast.SymbolFlagsGetAccessor != 0 || getterDecl != nil
	hasSetter := sym.Flags()&ast.SymbolFlagsSetAccessor != 0 || setterDecl != nil
	setterOpt := witTypes.None[uint32]()
	if hasGetter && hasSetter && setterDecl != nil {
		if pl := setterDecl.ParameterList(); pl != nil && len(pl.Nodes) > 0 {
			writeTy := b.tc.GetTypeAtLocation(pl.Nodes[0])
			if writeTy != nil && writeTy != propTy {
				setterOpt = witTypes.Some(b.extractCheckerType(writeTy))
			}
		}
	}

	return b.allocProp(zigar_typescript_types.PropNode{
		Name:           b.intern(name),
		ComputedSymbol: symKey,
		Ty:             tyID,
		SetterTy:       setterOpt,
		HasGetter:      hasGetter,
		HasSetter:      hasSetter,
		Modifiers:      mods,
		Jsdoc:          b.extractJsdocForNodes(sym.Declarations()),
	})
}

func (b *graphBuilder) isPrivateMemberNode(node *ast.Node) bool {
	if node == nil {
		return false
	}
	if ast.GetCombinedModifierFlags(node)&ast.ModifierFlagsPrivate != 0 {
		return true
	}
	if node.Name() != nil && node.Name().Kind == ast.KindPrivateIdentifier {
		return true
	}
	return false
}

func (b *graphBuilder) isPrivateSymbol(sym *ast.Symbol) bool {
	if sym == nil {
		return false
	}
	if checker.IsPrivateIdentifierSymbol(sym) || strings.HasPrefix(sym.Name(), "#") {
		return true
	}
	for _, d := range sym.Declarations() {
		if b.isPrivateMemberNode(d) {
			return true
		}
	}
	return false
}

func (b *graphBuilder) resolveMemberNameAndSymbolKey(
	nameNode *ast.Node,
	memberSym *ast.Symbol,
) (string, witTypes.Option[zigar_typescript_types.SymbolKey]) {
	if nameNode != nil {
		switch nameNode.Kind {
		case ast.KindIdentifier, ast.KindPrivateIdentifier, ast.KindStringLiteral, ast.KindNumericLiteral, ast.KindNoSubstitutionTemplateLiteral:
			return nameNode.Text(), witTypes.None[zigar_typescript_types.SymbolKey]()

		case ast.KindComputedPropertyName:
			cpn := nameNode.AsComputedPropertyName()
			if cpn != nil && cpn.Expression != nil {
				return b.resolveComputedKeyExpr(cpn.Expression)
			}
		}
	}

	// Fallback when inspecting Checker-synthesized property symbols (`__@iterator`, etc.).
	if memberSym != nil {
		if nameType := b.tc.GetNameTypeOfSymbol(memberSym); nameType != nil && nameType.Flags()&checker.TypeFlagsUniqueESSymbol != 0 {
			if essSym := b.unwrapUniqueESSymbol(nameType.Symbol()); essSym != nil {
				if wk, ok := matchWellKnownSymbolName(essSym.Name()); ok && !b.hasExtractableDecl(essSym) {
					return "[Symbol." + essSym.Name() + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyWellKnown(wk))
				}
				ids := b.extractSymbolIfExtractable(essSym)
				if len(ids) > 0 {
					return "[" + essSym.Name() + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyUnique(ids[0]))
				}
				return "[" + essSym.Name() + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyCustom(b.intern(essSym.Name())))
			}
		}
		return memberSym.Name(), witTypes.None[zigar_typescript_types.SymbolKey]()
	}

	return "", witTypes.None[zigar_typescript_types.SymbolKey]()
}

// unwrapUniqueESSymbol maps a synthetic `UniqueESSymbolType` symbol back to its
// underlying variable/property declaration symbol (`export declare const s: unique symbol`).
func (b *graphBuilder) unwrapUniqueESSymbol(sym *ast.Symbol) *ast.Symbol {
	sym = b.canonicalSymbol(sym)
	if sym == nil {
		return nil
	}
	for _, d := range sym.Declarations() {
		if d != nil && d.Symbol() != nil {
			if declSym := b.canonicalSymbol(d.Symbol()); declSym != nil {
				return declSym
			}
		}
	}
	return sym
}

func (b *graphBuilder) resolveComputedKeyExpr(expr *ast.Node) (string, witTypes.Option[zigar_typescript_types.SymbolKey]) {
	if expr == nil {
		return "", witTypes.None[zigar_typescript_types.SymbolKey]()
	}
	switch expr.Kind {
	case ast.KindStringLiteral, ast.KindNoSubstitutionTemplateLiteral, ast.KindNumericLiteral:
		return expr.Text(), witTypes.None[zigar_typescript_types.SymbolKey]()

	case ast.KindPropertyAccessExpression:
		pae := expr.AsPropertyAccessExpression()
		if pae != nil && pae.Expression != nil && pae.Name() != nil {
			lhs := entityNameToString(pae.Expression)
			prop := pae.Name().Text()
			if lhs == "Symbol" {
				if wk, ok := matchWellKnownSymbolName(prop); ok {
					return "[Symbol." + prop + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyWellKnown(wk))
				}
				return "[Symbol." + prop + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyCustom(b.intern("Symbol." + prop)))
			}
		}
	}

	// Check if expression resolves to a `unique symbol` declaration (`[myUniqueSym]` or `[ns.mySym]`).
	exprTy := b.tc.GetTypeAtLocation(expr)
	if exprTy != nil && exprTy.Flags()&checker.TypeFlagsUniqueESSymbol != 0 {
		sym := b.resolveExpressionSymbol(expr)
		if sym == nil {
			sym = b.unwrapUniqueESSymbol(exprTy.Symbol())
		}
		if sym != nil {
			if wk, ok := matchWellKnownSymbolName(sym.Name()); ok && !b.hasExtractableDecl(sym) {
				return "[Symbol." + sym.Name() + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyWellKnown(wk))
			}
			ids := b.extractSymbolIfExtractable(sym)
			label := entityNameToString(expr)
			if label == "" {
				label = sym.Name()
			}
			if len(ids) > 0 {
				return "[" + label + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyUnique(ids[0]))
			}
			return "[" + label + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyCustom(b.intern(label)))
		}
	}

	// Check if expression evaluates to a string/number literal (`const K = "foo"; [K]: number`).
	if exprTy != nil && exprTy.Flags()&(checker.TypeFlagsStringLiteral|checker.TypeFlagsNumberLiteral) != 0 {
		lt := exprTy.AsLiteralType()
		switch v := lt.Value().(type) {
		case string:
			return v, witTypes.None[zigar_typescript_types.SymbolKey]()
		}
	}

	raw := scanner.GetSourceTextOfNodeFromSourceFile(ast.GetSourceFileOfNode(expr), expr, false)
	raw = strings.TrimSpace(raw)
	return "[" + raw + "]", witTypes.Some(zigar_typescript_types.MakeSymbolKeyCustom(b.intern(raw)))
}

func matchWellKnownSymbolName(name string) (zigar_typescript_types.WellKnownSymbol, bool) {
	switch name {
	case "iterator":
		return zigar_typescript_types.WellKnownSymbol_Iterator, true
	case "asyncIterator":
		return zigar_typescript_types.WellKnownSymbol_AsyncIterator, true
	case "dispose":
		return zigar_typescript_types.WellKnownSymbol_Dispose, true
	case "asyncDispose":
		return zigar_typescript_types.WellKnownSymbol_AsyncDispose, true
	case "hasInstance":
		return zigar_typescript_types.WellKnownSymbol_HasInstance, true
	case "toStringTag":
		return zigar_typescript_types.WellKnownSymbol_ToStringTag, true
	case "toPrimitive":
		return zigar_typescript_types.WellKnownSymbol_ToPrimitive, true
	case "species":
		return zigar_typescript_types.WellKnownSymbol_Species, true
	case "match":
		return zigar_typescript_types.WellKnownSymbol_Match, true
	case "replace":
		return zigar_typescript_types.WellKnownSymbol_Replace, true
	case "search":
		return zigar_typescript_types.WellKnownSymbol_Search, true
	case "split":
		return zigar_typescript_types.WellKnownSymbol_Split, true
	default:
		return 0, false
	}
}

func (b *graphBuilder) propertyNameText(nameNode *ast.Node) string {
	txt, _ := b.resolveMemberNameAndSymbolKey(nameNode, nil)
	return txt
}

func (b *graphBuilder) extractIndexSigNode(node *ast.Node) (zigar_typescript_types.IndexSigNode, bool) {
	if node == nil || node.Kind != ast.KindIndexSignature {
		return zigar_typescript_types.IndexSigNode{}, false
	}
	isd := node.AsIndexSignatureDeclaration()
	if isd == nil {
		return zigar_typescript_types.IndexSigNode{}, false
	}
	keyName := "key"
	var keyTyID uint32
	if isd.Parameters != nil && len(isd.Parameters.Nodes) > 0 {
		p0 := isd.Parameters.Nodes[0]
		if p0 != nil {
			if p0.Name() != nil {
				keyName = p0.Name().Text()
			}
			if p0.Type() != nil {
				keyTyID = b.extractTypeNode(p0.Type())
			} else {
				keyTyID = b.extractCheckerType(b.tc.GetTypeAtLocation(p0))
			}
		}
	} else {
		keyTyID = b.allocType(zigar_typescript_types.MakeTypeKindStringType())
	}

	var valTyID uint32
	if isd.Type != nil {
		valTyID = b.extractTypeNode(isd.Type)
	} else {
		valTyID = b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
	}

	isReadonly := ast.GetCombinedModifierFlags(node)&ast.ModifierFlagsReadonly != 0
	return zigar_typescript_types.IndexSigNode{
		KeyName:    b.intern(keyName),
		KeyType:    keyTyID,
		ValueType:  valTyID,
		IsReadonly: isReadonly,
	}, true
}

func (b *graphBuilder) extractHeritageExpr(exprNode *ast.Node) zigar_typescript_types.HeritageClause {
	if exprNode == nil {
		return zigar_typescript_types.HeritageClause{
			TargetDecl: witTypes.None[uint32](),
			TargetType: b.allocType(zigar_typescript_types.MakeTypeKindAnyType()),
			TypeArgs:   []uint32{},
		}
	}

	// In TypeScript 7.1 Go AST, `HeritageClauseElement` is `ExpressionWithTypeArguments | TypeReferenceNode`.
	if exprNode.Kind == ast.KindTypeReference {
		tr := exprNode.AsTypeReferenceNode()
		typeArgs := b.extractTypeNodeList(tr.TypeArguments)
		refKind := b.buildTypeReferenceAST(exprNode)
		targetDecl := witTypes.None[uint32]()
		if refKind.Tag() == zigar_typescript_types.TypeKind_Reference {
			targetDecl = refKind.Reference().TargetDecl
		}
		return zigar_typescript_types.HeritageClause{
			TargetDecl: targetDecl,
			TargetType: b.allocType(refKind),
			TypeArgs:   typeArgs,
		}
	}

	if exprNode.Kind != ast.KindExpressionWithTypeArguments {
		tyID := b.extractTypeNode(exprNode)
		return zigar_typescript_types.HeritageClause{
			TargetDecl: witTypes.None[uint32](),
			TargetType: tyID,
			TypeArgs:   []uint32{},
		}
	}

	ewta := exprNode.AsExpressionWithTypeArguments()

	typeArgs := b.extractTypeNodeList(ewta.TypeArguments)
	targetName := entityNameToString(ewta.Expression)
	targetDecl := witTypes.None[uint32]()
	modSpec := witTypes.None[uint32]()

	if sym := b.resolveExpressionSymbol(ewta.Expression); sym != nil {
		ids := b.populateTypeTargetSymbol(sym)
		if len(ids) > 0 {
			targetDecl = witTypes.Some(ids[0])
			declMod := b.decls[ids[0]].Module
			if int(declMod) < len(b.modules) {
				modSpec = witTypes.Some(b.modules[declMod].Specifier)
			}
		}
	}

	var targetTypeID uint32
	if targetName != "" {
		targetTypeID = b.allocType(zigar_typescript_types.MakeTypeKindReference(zigar_typescript_types.TypeRefData{
			TargetDecl:      targetDecl,
			TargetName:      b.intern(targetName),
			ModuleSpecifier: modSpec,
			TypeArgs:        typeArgs,
		}))
	} else {
		targetTypeID = b.extractCheckerType(b.tc.GetTypeAtLocation(exprNode))
	}

	return zigar_typescript_types.HeritageClause{
		TargetDecl: targetDecl,
		TargetType: targetTypeID,
		TypeArgs:   typeArgs,
	}
}

// extractSignatureFromDecl extracts a call or construct signature from an AST function/method/ctor/type node.
func (b *graphBuilder) extractSignatureFromDecl(decl *ast.Node) uint32 {
	if decl == nil {
		return b.allocSig()
	}
	if existing, ok := b.sigByNode[decl]; ok {
		return existing
	}

	sigID := b.allocSig()
	b.sigByNode[decl] = sigID

	tpIDs := b.extractTypeParamList(decl.TypeParameters())
	thisParamOpt := witTypes.None[uint32]()
	params := []zigar_typescript_types.ParamNode{}
	paramNames := []string{}

	if paramList := decl.ParameterList(); paramList != nil {
		for idx, p := range paramList.Nodes {
			if p == nil || p.Kind != ast.KindParameter {
				continue
			}
			pd := p.AsParameterDeclaration()
			pName := fmt.Sprintf("arg%d", idx)
			if p.Name() != nil {
				if p.Name().Kind == ast.KindIdentifier || p.Name().Kind == ast.KindThisKeyword {
					pName = p.Name().Text()
				} else {
					sf := ast.GetSourceFileOfNode(p)
					pName = strings.TrimSpace(scanner.GetSourceTextOfNodeFromSourceFile(sf, p.Name(), false))
				}
			}

			var pTyID uint32
			if pd != nil && pd.Type != nil {
				pTyID = b.extractTypeNode(pd.Type)
			} else {
				pTyID = b.extractCheckerType(b.tc.GetTypeAtLocation(p))
			}

			if idx == 0 && pName == "this" {
				thisParamOpt = witTypes.Some(pTyID)
				continue
			}

			isOpt := (pd != nil && (pd.QuestionToken != nil || pd.Initializer != nil))
			isRest := pd != nil && pd.DotDotDotToken != nil
			paramNames = append(paramNames, pName)
			params = append(params, zigar_typescript_types.ParamNode{
				Name:     b.intern(pName),
				Ty:       pTyID,
				Optional: isOpt,
				Rest:     isRest,
			})
		}
	}

	var retTyID uint32
	predOpt := witTypes.None[zigar_typescript_types.TypePredicateData]()
	retTypeNode := decl.Type()
	if retTypeNode != nil {
		if retTypeNode.Kind == ast.KindTypePredicate {
			pred := b.extractTypePredicateNode(retTypeNode, paramNames)
			predOpt = witTypes.Some(pred)
			retTyID = b.allocType(zigar_typescript_types.MakeTypeKindTypePredicate(pred))
			if b.cfg.ExpandUtilityTypes {
				var resolvedID uint32
				if pred.Asserts {
					resolvedID = b.allocType(zigar_typescript_types.MakeTypeKindVoidType())
				} else {
					resolvedID = b.allocType(zigar_typescript_types.MakeTypeKindBooleanType())
				}
				b.types[retTyID].ResolvedType = witTypes.Some(resolvedID)
			}
		} else {
			retTyID = b.extractTypeNode(retTypeNode)
		}
	} else if decl.Kind == ast.KindConstructor {
		// Constructors without explicit return annotation construct the enclosing class instance (`this`).
		if cls := ast.FindAncestor(decl, ast.IsClassLike); cls != nil && cls.Symbol() != nil {
			retTyID = b.extractCheckerType(b.tc.GetDeclaredTypeOfSymbol(cls.Symbol()))
		} else {
			retTyID = b.allocType(zigar_typescript_types.MakeTypeKindThisType())
		}
	} else {
		if checkerSig := b.tc.GetSignatureFromDeclaration(decl); checkerSig != nil {
			retTyID = b.extractCheckerType(b.tc.GetReturnTypeOfSignature(checkerSig))
		} else {
			retTyID = b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
		}
	}

	isAbstract := ast.GetCombinedModifierFlags(decl)&ast.ModifierFlagsAbstract != 0
	if decl.Kind == ast.KindConstructor && decl.Parent != nil {
		if ast.GetCombinedModifierFlags(decl.Parent)&ast.ModifierFlagsAbstract != 0 {
			isAbstract = true
		}
	}

	b.signatures[sigID] = zigar_typescript_types.SignatureNode{
		Id:            sigID,
		TypeParams:    tpIDs,
		ThisParam:     thisParamOpt,
		Params:        params,
		ReturnType:    retTyID,
		TypePredicate: predOpt,
		IsAbstract:    isAbstract,
		Jsdoc:         b.extractJsdocForNode(decl),
	}
	return sigID
}

func typeNodeHasExplicitUndefined(tn *ast.TypeNode) bool {
	if tn == nil {
		return false
	}
	switch tn.Kind {
	case ast.KindUndefinedKeyword:
		return true
	case ast.KindParenthesizedType:
		return typeNodeHasExplicitUndefined(tn.AsParenthesizedTypeNode().Type)
	case ast.KindUnionType:
		ut := tn.AsUnionTypeNode()
		if ut != nil && ut.Types != nil {
			for _, m := range ut.Types.Nodes {
				if typeNodeHasExplicitUndefined(m) {
					return true
				}
			}
		}
	}
	return false
}

func (b *graphBuilder) extractCheckerSignature(sig *checker.Signature, isAbstract bool) uint32 {
	if sig == nil {
		return b.allocSig()
	}
	decl := sig.Declaration()
	if decl != nil && sig.Target() == nil && sig == b.tc.GetSignatureFromDeclaration(decl) {
		return b.extractSignatureFromDecl(decl)
	}
	if existing, ok := b.sigByCheckerSig[sig]; ok {
		return existing
	}

	sigID := b.allocSig()
	b.sigByCheckerSig[sig] = sigID

	tpIDs := []uint32{}
	for _, tp := range sig.TypeParameters() {
		tpIDs = append(tpIDs, b.ensureCheckerTypeParam(tp))
	}

	thisParamOpt := witTypes.None[uint32]()
	if thisSym := sig.ThisParameter(); thisSym != nil {
		thisParamOpt = witTypes.Some(b.extractCheckerType(b.tc.GetTypeOfSymbol(thisSym)))
	}

	params := []zigar_typescript_types.ParamNode{}
	paramNames := []string{}
	sigParams := sig.Parameters()
	for i, pSym := range sigParams {
		if pSym == nil {
			continue
		}
		paramNames = append(paramNames, pSym.Name())
		var paramDecl *ast.ParameterDeclaration
		for _, d := range pSym.Declarations() {
			if d != nil && d.Kind == ast.KindParameter {
				paramDecl = d.AsParameterDeclaration()
				break
			}
		}
		isRest := (sig.HasRestParameter() && i == len(sigParams)-1) ||
			pSym.CheckFlags()&ast.CheckFlagsRestParameter != 0 ||
			(paramDecl != nil && paramDecl.DotDotDotToken != nil)
		isOpt := !isRest && (pSym.Flags()&ast.SymbolFlagsOptional != 0 ||
			pSym.CheckFlags()&ast.CheckFlagsOptionalParameter != 0 ||
			(paramDecl != nil && (paramDecl.QuestionToken != nil || paramDecl.Initializer != nil)))
		paramTy := b.tc.GetNonMissingTypeOfSymbol(pSym)
		if paramTy == nil {
			paramTy = b.tc.GetTypeOfSymbol(pSym)
		}
		if isOpt &&
			paramTy != nil &&
			paramTy.Flags()&checker.TypeFlagsUnion != 0 &&
			(paramDecl == nil || !typeNodeHasExplicitUndefined(paramDecl.Type)) {
			if stripped := b.tc.RemoveMissingOrUndefinedType(paramTy); stripped != nil && stripped.Flags()&checker.TypeFlagsNever == 0 {
				paramTy = stripped
			}
		}
		params = append(params, zigar_typescript_types.ParamNode{
			Name:     b.intern(pSym.Name()),
			Ty:       b.extractCheckerType(paramTy),
			Optional: isOpt,
			Rest:     isRest,
		})
	}

	retTyID := b.extractCheckerType(b.tc.GetReturnTypeOfSignature(sig))
	predOpt := witTypes.None[zigar_typescript_types.TypePredicateData]()
	if pred := b.tc.GetTypePredicateOfSignature(sig); pred != nil {
		predKind := pred.Kind()
		isAsserts := predKind == checker.TypePredicateKindAssertsThis || predKind == checker.TypePredicateKindAssertsIdentifier
		pName := pred.ParameterName()
		if predKind == checker.TypePredicateKindThis || predKind == checker.TypePredicateKindAssertsThis {
			pName = "this"
		}
		pIdxOpt := witTypes.None[uint32]()
		if pred.ParameterIndex() >= 0 {
			pIdxOpt = witTypes.Some(uint32(pred.ParameterIndex()))
		}
		tgtOpt := witTypes.None[uint32]()
		if pred.Type() != nil {
			tgtOpt = witTypes.Some(b.extractCheckerType(pred.Type()))
		}
		predData := zigar_typescript_types.TypePredicateData{
			ParamName:  b.intern(pName),
			ParamIndex: pIdxOpt,
			Asserts:    isAsserts,
			TargetType: tgtOpt,
		}
		predOpt = witTypes.Some(predData)
		baseRetTyID := retTyID
		retTyID = b.allocType(zigar_typescript_types.MakeTypeKindTypePredicate(predData))
		if b.cfg.ExpandUtilityTypes {
			b.types[retTyID].ResolvedType = witTypes.Some(baseRetTyID)
		}
	}

	b.signatures[sigID] = zigar_typescript_types.SignatureNode{
		Id:            sigID,
		TypeParams:    tpIDs,
		ThisParam:     thisParamOpt,
		Params:        params,
		ReturnType:    retTyID,
		TypePredicate: predOpt,
		IsAbstract:    isAbstract || sig.Flags()&checker.SignatureFlagsAbstract != 0,
		Jsdoc:         b.extractJsdocForNode(decl),
	}
	return sigID
}

func (b *graphBuilder) extractTypePredicateNode(node *ast.Node, paramNames []string) zigar_typescript_types.TypePredicateData {
	if node == nil || node.Kind != ast.KindTypePredicate {
		return zigar_typescript_types.TypePredicateData{
			ParamName:  b.intern(""),
			ParamIndex: witTypes.None[uint32](),
			Asserts:    false,
			TargetType: witTypes.None[uint32](),
		}
	}
	tpn := node.AsTypePredicateNode()

	pName := ""
	if tpn.ParameterName != nil {
		if tpn.ParameterName.Kind == ast.KindThisType || tpn.ParameterName.Kind == ast.KindThisKeyword {
			pName = "this"
		} else {
			pName = tpn.ParameterName.Text()
		}
	}

	paramIdxOpt := witTypes.None[uint32]()
	for i, n := range paramNames {
		if n == pName {
			paramIdxOpt = witTypes.Some(uint32(i))
			break
		}
	}

	targetOpt := witTypes.None[uint32]()
	if tpn.Type != nil {
		targetOpt = witTypes.Some(b.extractTypeNode(tpn.Type))
	}

	return zigar_typescript_types.TypePredicateData{
		ParamName:  b.intern(pName),
		ParamIndex: paramIdxOpt,
		Asserts:    tpn.AssertsModifier != nil,
		TargetType: targetOpt,
	}
}

// JSDoc extraction (`include-jsdoc: true`).

func (b *graphBuilder) extractJsdocForNodes(nodes []*ast.Node) witTypes.Option[zigar_typescript_types.JsdocInfo] {
	if !b.cfg.IncludeJsdoc || len(nodes) == 0 {
		return witTypes.None[zigar_typescript_types.JsdocInfo]()
	}
	for _, n := range nodes {
		if info := b.extractJsdocForNode(n); isSome(info) {
			return info
		}
	}
	return witTypes.None[zigar_typescript_types.JsdocInfo]()
}

func (b *graphBuilder) extractJsdocForNode(node *ast.Node) witTypes.Option[zigar_typescript_types.JsdocInfo] {
	if !b.cfg.IncludeJsdoc || node == nil {
		return witTypes.None[zigar_typescript_types.JsdocInfo]()
	}

	sf := ast.GetSourceFileOfNode(node)
	if sf == nil {
		return witTypes.None[zigar_typescript_types.JsdocInfo]()
	}

	jsdocNodes := collectJSDocBlocks(node, sf)
	if len(jsdocNodes) == 0 {
		return witTypes.None[zigar_typescript_types.JsdocInfo]()
	}

	var summaries []string
	tags := []zigar_typescript_types.JsdocTag{}
	isDeprecated := false
	depMsgOpt := witTypes.None[uint32]()

	for _, jdNode := range jsdocNodes {
		if jdNode == nil || jdNode.Kind != ast.KindJSDoc {
			continue
		}
		jd := jdNode.AsJSDoc()
		if jd == nil {
			continue
		}
		if comment := strings.TrimSpace(scanner.GetTextOfJSDocComment(jd.Comment)); comment != "" {
			summaries = append(summaries, comment)
		}
		if jd.Tags != nil {
			for _, tagNode := range jd.Tags.Nodes {
				if tagNode == nil {
					continue
				}
				tagNameNode := tagNode.TagName()
				tagName := ""
				if tagNameNode != nil {
					tagName = tagNameNode.Text()
				} else if tagNode.Kind == ast.KindJSDocDeprecatedTag {
					tagName = "deprecated"
				}
				if tagName == "" {
					continue
				}

				tagComment := strings.TrimSpace(scanner.GetTextOfJSDocComment(tagNode.CommentList()))
				// Prepend parameter name for `@param x description` tags when available.
				if tagNode.Kind == ast.KindJSDocParameterTag && tagNode.Name() != nil {
					paramTarget := entityNameToString(tagNode.Name())
					if paramTarget != "" {
						if tagComment != "" {
							tagComment = paramTarget + " " + tagComment
						} else {
							tagComment = paramTarget
						}
					}
				}

				if tagNode.Kind == ast.KindJSDocDeprecatedTag || tagName == "deprecated" {
					isDeprecated = true
					if tagComment != "" && isNone(depMsgOpt) {
						depMsgOpt = witTypes.Some(b.intern(tagComment))
					}
				}

				textOpt := witTypes.None[uint32]()
				if tagComment != "" {
					textOpt = witTypes.Some(b.intern(tagComment))
				}
				tags = append(tags, zigar_typescript_types.JsdocTag{
					Name: b.intern(tagName),
					Text: textOpt,
				})
			}
		}
	}

	summaryOpt := witTypes.None[uint32]()
	if len(summaries) > 0 {
		summaryOpt = witTypes.Some(b.intern(strings.Join(summaries, "\n\n")))
	}

	if isNone(summaryOpt) && len(tags) == 0 && !isDeprecated {
		return witTypes.None[zigar_typescript_types.JsdocInfo]()
	}

	return witTypes.Some(zigar_typescript_types.JsdocInfo{
		Summary:            summaryOpt,
		Tags:               tags,
		IsDeprecated:       isDeprecated,
		DeprecationMessage: depMsgOpt,
	})
}

func collectJSDocBlocks(node *ast.Node, sf *ast.SourceFile) []*ast.Node {
	cur := node
	for cur != nil {
		if docs := cur.JSDoc(sf); len(docs) > 0 {
			return docs
		}
		cur = ast.GetNextJSDocCommentLocation(cur)
	}
	return nil
}
