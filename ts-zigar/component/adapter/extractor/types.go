package export_zigar_typescript_extractor

import (
	"math"
	"math/big"
	"strconv"
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/checker"
	"github.com/microsoft/TypeScript/tsc/internal/jsnum"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

func (b *graphBuilder) extractTypeParamList(nodes []*ast.Node) []uint32 {
	if len(nodes) == 0 {
		return []uint32{}
	}
	ids := make([]uint32, 0, len(nodes))
	// Phase 1: pre-allocate all type parameter IDs in the list before extracting constraints/defaults
	// so mutually recursive or F-bounded constraints (`Events extends EventMap<Events>`, `<A extends B, B>`) never loop!
	for _, n := range nodes {
		if n == nil || n.Kind != ast.KindTypeParameter {
			continue
		}
		ids = append(ids, b.preallocTypeParamDecl(n))
	}
	// Phase 2: populate constraints, defaults, and variance flags.
	for _, n := range nodes {
		if n == nil || n.Kind != ast.KindTypeParameter {
			continue
		}
		b.populateTypeParamDecl(n)
	}
	return ids
}

func (b *graphBuilder) preallocTypeParamDecl(node *ast.Node) uint32 {
	if existing, ok := b.tpByNode[node]; ok {
		return existing
	}
	sym := b.canonicalSymbol(node.Symbol())
	if sym != nil {
		if existing, ok := b.tpBySym[sym]; ok {
			b.tpByNode[node] = existing
			return existing
		}
	}
	name := ""
	if node.Name() != nil {
		name = node.Name().Text()
	} else if sym != nil {
		name = sym.Name()
	}
	id := b.allocTypeParam(b.intern(name))
	b.tpByNode[node] = id
	if sym != nil {
		b.tpBySym[sym] = id
	}
	return id
}

func (b *graphBuilder) populateTypeParamDecl(node *ast.Node) uint32 {
	id := b.preallocTypeParamDecl(node)
	if node == nil || node.Kind != ast.KindTypeParameter {
		return id
	}
	tpd := node.AsTypeParameterDeclaration()

	var isConst, inVar, outVar bool
	if mods := node.Modifiers(); mods != nil {
		for _, m := range mods.Nodes {
			if m == nil {
				continue
			}
			switch m.Kind {
			case ast.KindConstKeyword:
				isConst = true
			case ast.KindInKeyword:
				inVar = true
			case ast.KindOutKeyword:
				outVar = true
			}
		}
	}

	constraintOpt := witTypes.None[uint32]()
	if tpd.Constraint != nil {
		constraintOpt = witTypes.Some(b.extractTypeNode(tpd.Constraint))
	}
	defaultOpt := witTypes.None[uint32]()
	if tpd.DefaultType != nil {
		defaultOpt = witTypes.Some(b.extractTypeNode(tpd.DefaultType))
	}

	b.typeParams[id].Constraint = constraintOpt
	b.typeParams[id].DefaultType = defaultOpt
	b.typeParams[id].IsConst = isConst
	b.typeParams[id].InVariance = inVar
	b.typeParams[id].OutVariance = outVar
	return id
}

func (b *graphBuilder) ensureCheckerTypeParam(t *checker.Type) uint32 {
	if existing, ok := b.tpByCheckerType[t]; ok {
		return existing
	}

	isInstantiatedTP := t.Target() != nil || t.Mapper() != nil
	sym := b.canonicalSymbol(t.Symbol())
	if !isInstantiatedTP && sym != nil {
		if existing, ok := b.tpBySym[sym]; ok {
			return existing
		}
		for _, d := range sym.Declarations() {
			if d != nil && d.Kind == ast.KindTypeParameter {
				return b.populateTypeParamDecl(d)
			}
		}
	}

	name := "T"
	if sym != nil && sym.Name() != "" {
		name = sym.Name()
	}
	id := b.allocTypeParam(b.intern(name))
	b.tpByCheckerType[t] = id
	if !isInstantiatedTP && sym != nil {
		b.tpBySym[sym] = id
	}

	if sym != nil {
		for _, d := range sym.Declarations() {
			if d != nil && d.Kind == ast.KindTypeParameter {
				mods := ast.GetCombinedModifierFlags(d)
				b.typeParams[id].IsConst = mods&ast.ModifierFlagsConst != 0
				b.typeParams[id].InVariance = mods&ast.ModifierFlagsIn != 0
				b.typeParams[id].OutVariance = mods&ast.ModifierFlagsOut != 0
				break
			}
		}
	}

	if constraint := b.tc.GetBaseConstraintOfType(t); constraint != nil && constraint != t {
		b.typeParams[id].Constraint = witTypes.Some(b.extractCheckerType(constraint))
	}
	if def := b.tc.GetDefaultFromTypeParameter(t); def != nil && def != t {
		b.typeParams[id].DefaultType = witTypes.Some(b.extractCheckerType(def))
	}
	return id
}

// extractTypeNode extracts an AST TypeNode into `b.types`, pre-allocating its `type-id`
// before recursing so self-referential and cyclic types never infinite-loop.
func (b *graphBuilder) extractTypeNode(node *ast.Node) uint32 {
	if node == nil {
		return b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
	}

	// Unwrap parenthesized types (`(A | B)`).
	for node != nil && node.Kind == ast.KindParenthesizedType {
		pt := node.AsParenthesizedTypeNode()
		if pt == nil || pt.Type == nil {
			break
		}
		node = pt.Type
	}
	if node == nil {
		return b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
	}

	if existing, ok := b.astTypeMemo[node]; ok {
		return existing
	}

	id := b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
	b.astTypeMemo[node] = id

	kind := b.buildASTTypeKind(node)
	b.types[id].Kind = kind

	if b.cfg.ExpandUtilityTypes && isExpandableSyntaxNode(node, kind) {
		b.populateExpandedResolvedType(id, b.tc.GetTypeFromTypeNode(node))
	}

	return id
}

func isExpandableSyntaxNode(node *ast.Node, kind zigar_typescript_types.TypeKind) bool {
	if node == nil {
		return false
	}
	switch kind.Tag() {
	case zigar_typescript_types.TypeKind_KeyofType,
		zigar_typescript_types.TypeKind_TypeofQuery,
		zigar_typescript_types.TypeKind_IndexedAccess,
		zigar_typescript_types.TypeKind_Conditional,
		zigar_typescript_types.TypeKind_Mapped,
		zigar_typescript_types.TypeKind_TemplateLiteral,
		zigar_typescript_types.TypeKind_Intrinsic:
		return true
	case zigar_typescript_types.TypeKind_Reference:
		// Expand instantiated utility/type aliases (`Partial<Foo>`, `Pick<Foo, "a">`, `Record<string, number>`, `Uppercase<"hi">`, etc.).
		sym := node.Symbol()
		if sym != nil {
			for _, d := range sym.Declarations() {
				if d != nil && d.Kind == ast.KindTypeAliasDeclaration {
					return true
				}
			}
		}
		if node.Kind == ast.KindTypeReference {
			tr := node.AsTypeReferenceNode()
			if tr != nil && tr.TypeArguments != nil && len(tr.TypeArguments.Nodes) > 0 {
				return true
			}
		}
	}
	return false
}

func (b *graphBuilder) populateExpandedResolvedType(surfaceTypeID uint32, evaluated *checker.Type) {
	if evaluated == nil || surfaceTypeID >= uint32(len(b.types)) {
		return
	}
	flags := evaluated.Flags()
	// Skip uninformative unresolved type parameters / error-any.
	if flags&(checker.TypeFlagsTypeParameter|checker.TypeFlagsIndex|checker.TypeFlagsIndexedAccess|checker.TypeFlagsConditional) != 0 {
		return
	}
	if flags&checker.TypeFlagsAny != 0 && b.types[surfaceTypeID].Kind.Tag() != zigar_typescript_types.TypeKind_AnyType {
		return
	}

	expandedID := b.extractExpandedCheckerType(evaluated)
	if expandedID == surfaceTypeID {
		return
	}
	// Avoid redundant self-identical primitive or identical reference kinds.
	if b.types[expandedID].Kind.Tag() == b.types[surfaceTypeID].Kind.Tag() &&
		b.types[surfaceTypeID].Kind.Tag() == zigar_typescript_types.TypeKind_Reference {
		r1 := b.types[surfaceTypeID].Kind.Reference()
		r2 := b.types[expandedID].Kind.Reference()
		if r1.TargetName == r2.TargetName && r1.TargetDecl == r2.TargetDecl {
			return
		}
	}
	b.types[surfaceTypeID].ResolvedType = witTypes.Some(expandedID)
}

func (b *graphBuilder) buildASTTypeKind(node *ast.Node) zigar_typescript_types.TypeKind {
	switch node.Kind {
	case ast.KindAnyKeyword:
		return zigar_typescript_types.MakeTypeKindAnyType()
	case ast.KindUnknownKeyword:
		return zigar_typescript_types.MakeTypeKindUnknownType()
	case ast.KindVoidKeyword:
		return zigar_typescript_types.MakeTypeKindVoidType()
	case ast.KindUndefinedKeyword:
		return zigar_typescript_types.MakeTypeKindUndefinedType()
	case ast.KindNullKeyword:
		return zigar_typescript_types.MakeTypeKindNullType()
	case ast.KindNeverKeyword:
		return zigar_typescript_types.MakeTypeKindNeverType()
	case ast.KindBooleanKeyword:
		return zigar_typescript_types.MakeTypeKindBooleanType()
	case ast.KindNumberKeyword:
		return zigar_typescript_types.MakeTypeKindNumberType()
	case ast.KindBigIntKeyword:
		return zigar_typescript_types.MakeTypeKindBigintType()
	case ast.KindStringKeyword:
		return zigar_typescript_types.MakeTypeKindStringType()
	case ast.KindSymbolKeyword:
		return zigar_typescript_types.MakeTypeKindSymbolType()
	case ast.KindObjectKeyword:
		return zigar_typescript_types.MakeTypeKindObjectType()
	case ast.KindThisType, ast.KindThisKeyword:
		return zigar_typescript_types.MakeTypeKindThisType()
	case ast.KindIntrinsicKeyword:
		return zigar_typescript_types.MakeTypeKindIntrinsic(b.intern("intrinsic"))

	case ast.KindLiteralType:
		lt := node.AsLiteralTypeNode()
		if lt == nil || lt.Literal == nil {
			return zigar_typescript_types.MakeTypeKindAnyType()
		}
		return b.extractLiteralExprTypeKind(lt.Literal)

	case ast.KindTemplateLiteralType:
		tl := node.AsTemplateLiteralTypeNode()
		if tl == nil {
			return zigar_typescript_types.MakeTypeKindStringType()
		}
		headText := ""
		if tl.Head != nil {
			headText = tl.Head.Text()
		}
		spans := []zigar_typescript_types.TemplateSpan{}
		if tl.TemplateSpans != nil {
			for _, sp := range tl.TemplateSpans.Nodes {
				if sp == nil || sp.Kind != ast.KindTemplateLiteralTypeSpan {
					continue
				}
				ts := sp.AsTemplateLiteralTypeSpan()
				if ts == nil {
					continue
				}
				litText := ""
				if ts.Literal != nil {
					litText = ts.Literal.Text()
				}
				spans = append(spans, zigar_typescript_types.TemplateSpan{
					Ty:      b.extractTypeNode(ts.Type),
					Literal: b.intern(litText),
				})
			}
		}
		return zigar_typescript_types.MakeTypeKindTemplateLiteral(zigar_typescript_types.TemplateLiteralData{
			Head:  b.intern(headText),
			Spans: spans,
		})

	case ast.KindArrayType:
		at := node.AsArrayTypeNode()
		if at == nil {
			return zigar_typescript_types.MakeTypeKindArray(b.allocType(zigar_typescript_types.MakeTypeKindAnyType()))
		}
		return zigar_typescript_types.MakeTypeKindArray(b.extractTypeNode(at.ElementType))

	case ast.KindTupleType:
		tt := node.AsTupleTypeNode()
		return zigar_typescript_types.MakeTypeKindTuple(b.extractTupleElementsAST(tt))

	case ast.KindUnionType:
		ut := node.AsUnionTypeNode()
		members := []uint32{}
		if ut != nil && ut.Types != nil {
			for _, m := range ut.Types.Nodes {
				members = append(members, b.extractTypeNode(m))
			}
		}
		return zigar_typescript_types.MakeTypeKindUnionType(members)

	case ast.KindIntersectionType:
		it := node.AsIntersectionTypeNode()
		members := []uint32{}
		if it != nil && it.Types != nil {
			for _, m := range it.Types.Nodes {
				members = append(members, b.extractTypeNode(m))
			}
		}
		return zigar_typescript_types.MakeTypeKindIntersection(members)

	case ast.KindTypeOperator:
		to := node.AsTypeOperatorNode()
		if to == nil {
			return zigar_typescript_types.MakeTypeKindAnyType()
		}
		switch to.Operator {
		case ast.KindKeyOfKeyword:
			return zigar_typescript_types.MakeTypeKindKeyofType(b.extractTypeNode(to.Type))
		case ast.KindUniqueKeyword:
			return zigar_typescript_types.MakeTypeKindUniqueSymbol(b.intern("unique symbol"))
		case ast.KindReadonlyKeyword:
			if to.Type != nil {
				if to.Type.Kind == ast.KindArrayType {
					at := to.Type.AsArrayTypeNode()
					return zigar_typescript_types.MakeTypeKindReadonlyArray(b.extractTypeNode(at.ElementType))
				}
				if to.Type.Kind == ast.KindTupleType {
					return zigar_typescript_types.MakeTypeKindReadonlyTuple(b.extractTupleElementsAST(to.Type.AsTupleTypeNode()))
				}
				return b.buildASTTypeKind(to.Type)
			}
		}
		return zigar_typescript_types.MakeTypeKindAnyType()

	case ast.KindTypeReference:
		return b.buildTypeReferenceAST(node)

	case ast.KindInferType:
		it := node.AsInferTypeNode()
		if it != nil && it.TypeParameter != nil {
			tpID := b.populateTypeParamDecl(it.TypeParameter)
			return zigar_typescript_types.MakeTypeKindInferType(tpID)
		}
		return zigar_typescript_types.MakeTypeKindAnyType()

	case ast.KindFunctionType:
		sigID := b.extractSignatureFromDecl(node)
		return zigar_typescript_types.MakeTypeKindFunctionType(sigID)

	case ast.KindConstructorType:
		sigID := b.extractSignatureFromDecl(node)
		return zigar_typescript_types.MakeTypeKindConstructorType(sigID)

	case ast.KindTypeLiteral:
		tl := node.AsTypeLiteralNode()
		objData := b.extractObjectLiteralMembersAST(tl)
		return zigar_typescript_types.MakeTypeKindObjectLiteral(objData)

	case ast.KindTypeQuery:
		tq := node.AsTypeQueryNode()
		if tq == nil {
			return zigar_typescript_types.MakeTypeKindAnyType()
		}
		parts := b.entityNameParts(tq.ExprName)
		targetDecl := witTypes.None[uint32]()
		if sym := b.resolveExpressionSymbol(tq.ExprName); sym != nil {
			ids := b.extractSymbolIfExtractable(sym)
			if len(ids) > 0 {
				targetDecl = witTypes.Some(ids[0])
			}
		}
		typeArgs := b.extractTypeNodeList(tq.TypeArguments)
		return zigar_typescript_types.MakeTypeKindTypeofQuery(zigar_typescript_types.TypeofQueryData{
			EntityPath: parts,
			TargetDecl: targetDecl,
			TypeArgs:   typeArgs,
		})

	case ast.KindIndexedAccessType:
		ia := node.AsIndexedAccessTypeNode()
		if ia == nil {
			return zigar_typescript_types.MakeTypeKindAnyType()
		}
		return zigar_typescript_types.MakeTypeKindIndexedAccess(zigar_typescript_types.IndexedAccessData{
			ObjectTy: b.extractTypeNode(ia.ObjectType),
			IndexTy:  b.extractTypeNode(ia.IndexType),
		})

	case ast.KindConditionalType:
		ct := node.AsConditionalTypeNode()
		if ct == nil {
			return zigar_typescript_types.MakeTypeKindAnyType()
		}
		checkID := b.extractTypeNode(ct.CheckType)
		inferParamNodes := collectDirectInferParams(ct.ExtendsType)
		inferIDs := make([]uint32, 0, len(inferParamNodes))
		for _, ip := range inferParamNodes {
			inferIDs = append(inferIDs, b.preallocTypeParamDecl(ip))
		}
		extendsID := b.extractTypeNode(ct.ExtendsType)
		for _, ip := range inferParamNodes {
			b.populateTypeParamDecl(ip)
		}
		trueID := b.extractTypeNode(ct.TrueType)
		falseID := b.extractTypeNode(ct.FalseType)
		return zigar_typescript_types.MakeTypeKindConditional(zigar_typescript_types.ConditionalTypeData{
			CheckType:   checkID,
			ExtendsType: extendsID,
			TrueType:    trueID,
			FalseType:   falseID,
			InferParams: inferIDs,
		})

	case ast.KindMappedType:
		mt := node.AsMappedTypeNode()
		if mt == nil {
			return zigar_typescript_types.MakeTypeKindAnyType()
		}
		var tpID uint32
		if mt.TypeParameter != nil {
			tpID = b.populateTypeParamDecl(mt.TypeParameter)
		} else {
			tpID = b.allocTypeParam(b.intern("K"))
		}
		nameTypeOpt := witTypes.None[uint32]()
		if mt.NameType != nil {
			nameTypeOpt = witTypes.Some(b.extractTypeNode(mt.NameType))
		}
		valTypeID := uint32(0)
		if mt.Type != nil {
			valTypeID = b.extractTypeNode(mt.Type)
		} else {
			valTypeID = b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
		}
		return zigar_typescript_types.MakeTypeKindMapped(zigar_typescript_types.MappedTypeData{
			TypeParam:        tpID,
			NameType:         nameTypeOpt,
			ValueType:        valTypeID,
			ReadonlyModifier: convertMappedModifierToken(mt.ReadonlyToken),
			OptionalModifier: convertMappedModifierToken(mt.QuestionToken),
		})

	case ast.KindTypePredicate:
		pred := b.extractTypePredicateNode(node, nil)
		return zigar_typescript_types.MakeTypeKindTypePredicate(pred)

	case ast.KindImportType:
		it := node.AsImportTypeNode()
		if it == nil {
			return zigar_typescript_types.MakeTypeKindAnyType()
		}
		modSpec := ""
		if it.Argument != nil && it.Argument.Kind == ast.KindLiteralType {
			lt := it.Argument.AsLiteralTypeNode()
			if lt != nil && lt.Literal != nil && ast.IsStringLiteralLike(lt.Literal) {
				modSpec = lt.Literal.Text()
				if sf := ast.GetSourceFileOfNode(node); sf != nil {
					if targetSF := b.resolveModuleSpecifierNode(sf, lt.Literal); targetSF != nil && b.isExtractableSourceFile(targetSF) {
						b.ensureModuleWithSpecifier(targetSF, modSpec, b.cfg.FollowReExports)
					}
				}
			}
		}
		qualParts := b.entityNameParts(it.Qualifier)
		typeArgs := b.extractTypeNodeList(it.TypeArguments)
		return zigar_typescript_types.MakeTypeKindImportType(zigar_typescript_types.ImportTypeData{
			ModuleSpecifier: b.intern(modSpec),
			Qualifier:       qualParts,
			TypeArgs:        typeArgs,
			IsTypeOf:        it.IsTypeOf,
		})

	case ast.KindOptionalType:
		ot := node.AsOptionalTypeNode()
		if ot != nil && ot.Type != nil {
			return b.buildASTTypeKind(ot.Type)
		}
	case ast.KindRestType:
		rt := node.AsRestTypeNode()
		if rt != nil && rt.Type != nil {
			return b.buildASTTypeKind(rt.Type)
		}
	}

	return b.buildCheckerTypeKind(b.tc.GetTypeFromTypeNode(node), false)
}

func (b *graphBuilder) buildTypeReferenceAST(node *ast.Node) zigar_typescript_types.TypeKind {
	tr := node.AsTypeReferenceNode()
	if tr == nil || tr.TypeName == nil {
		return zigar_typescript_types.MakeTypeKindAnyType()
	}

	rawName := entityNameToString(tr.TypeName)
	sym := b.tc.GetSymbolAtLocation(tr.TypeName)
	sym = b.resolveAliasSymbol(sym)
	sym = b.canonicalSymbol(sym)

	// 1. Check if `tr.TypeName` refers to an in-scope TypeParameter!
	if sym != nil && sym.Flags()&ast.SymbolFlagsTypeParameter != 0 {
		if tpID, ok := b.tpBySym[sym]; ok {
			return zigar_typescript_types.MakeTypeKindTypeParam(tpID)
		}
		for _, d := range sym.Declarations() {
			if d != nil && d.Kind == ast.KindTypeParameter {
				tpID := b.populateTypeParamDecl(d)
				return zigar_typescript_types.MakeTypeKindTypeParam(tpID)
			}
		}
	}

	typeArgs := b.extractTypeNodeList(tr.TypeArguments)

	// 2. Normalize built-in default-lib `Array<T>` and `ReadonlyArray<T>`, and intrinsic string mappers (`Uppercase<T>`, etc.).
	if sym != nil && !b.hasExtractableDecl(sym) {
		switch sym.Name() {
		case "Array":
			if len(typeArgs) == 1 {
				return zigar_typescript_types.MakeTypeKindArray(typeArgs[0])
			}
		case "ReadonlyArray":
			if len(typeArgs) == 1 {
				return zigar_typescript_types.MakeTypeKindReadonlyArray(typeArgs[0])
			}
		case "Uppercase", "Lowercase", "Capitalize", "Uncapitalize":
			if len(typeArgs) == 0 {
				return zigar_typescript_types.MakeTypeKindIntrinsic(b.intern(sym.Name()))
			}
		}
	}

	// 3. Extract referenced declaration if it belongs to a non-default-lib module in the program.
	targetDecl := witTypes.None[uint32]()
	modSpecOpt := witTypes.None[uint32]()
	if sym != nil {
		ids := b.populateTypeTargetSymbol(sym)
		if len(ids) > 0 {
			targetDecl = witTypes.Some(ids[0])
			declMod := b.decls[ids[0]].Module
			if int(declMod) < len(b.modules) {
				modSpecOpt = witTypes.Some(b.modules[declMod].Specifier)
			}
		}
	}

	return zigar_typescript_types.MakeTypeKindReference(zigar_typescript_types.TypeRefData{
		TargetDecl:      targetDecl,
		TargetName:      b.intern(rawName),
		ModuleSpecifier: modSpecOpt,
		TypeArgs:        typeArgs,
	})
}

func (b *graphBuilder) populateTypeTargetSymbol(sym *ast.Symbol) []uint32 {
	sym = b.canonicalSymbol(sym)
	if sym == nil {
		return nil
	}
	// If `sym` is an EnumMember (`Color.Red`), link to parent Enum declaration if needed or extract parent enum.
	if sym.Flags()&ast.SymbolFlagsEnumMember != 0 && sym.Parent() != nil {
		return b.extractSymbolIfExtractable(sym.Parent())
	}
	ids := b.extractSymbolIfExtractable(sym)
	if len(ids) <= 1 {
		return ids
	}
	// Prefer type-space declaration (`interface`, `class`, `type-alias`, `enum`) over merged `variable` / `namespace` when resolving a `TypeReference`!
	for _, id := range ids {
		switch b.decls[id].Kind.Tag() {
		case zigar_typescript_types.DeclKind_InterfaceDecl,
			zigar_typescript_types.DeclKind_ClassDecl,
			zigar_typescript_types.DeclKind_TypeAliasDecl,
			zigar_typescript_types.DeclKind_EnumDecl:
			return []uint32{id}
		}
	}
	return ids
}

func (b *graphBuilder) hasExtractableDecl(sym *ast.Symbol) bool {
	if sym == nil {
		return false
	}
	for _, d := range sym.Declarations() {
		if d == nil {
			continue
		}
		if sf := ast.GetSourceFileOfNode(d); sf != nil && b.isExtractableSourceFile(sf) {
			return true
		}
	}
	return false
}

func parseTsNumericLiteral(raw string) (float64, bool) {
	clean := strings.ReplaceAll(strings.TrimSpace(raw), "_", "")
	if clean == "" {
		return 0, false
	}
	if len(clean) > 2 && clean[0] == '0' {
		var base int
		switch clean[1] {
		case 'x', 'X':
			base = 16
		case 'b', 'B':
			base = 2
		case 'o', 'O':
			base = 8
		}
		if base != 0 {
			bi, ok := new(big.Int).SetString(clean[2:], base)
			if !ok {
				return 0, false
			}
			val, _ := new(big.Rat).SetInt(bi).Float64()
			return val, true
		}
	}
	val, err := strconv.ParseFloat(clean, 64)
	if err != nil || math.IsNaN(val) {
		return 0, false
	}
	return val, true
}

func (b *graphBuilder) extractLiteralExprTypeKind(lit *ast.Node) zigar_typescript_types.TypeKind {
	switch lit.Kind {
	case ast.KindStringLiteral, ast.KindNoSubstitutionTemplateLiteral:
		return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueStr(b.intern(lit.Text())))
	case ast.KindNumericLiteral:
		val, ok := parseTsNumericLiteral(lit.Text())
		if !ok {
			return zigar_typescript_types.MakeTypeKindUnknownType()
		}
		return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueNum(val))
	case ast.KindBigIntLiteral:
		clean := strings.TrimSuffix(strings.ReplaceAll(lit.Text(), "_", ""), "n")
		return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueBigintLiteral(b.intern(clean)))
	case ast.KindTrueKeyword:
		return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueBoolean(true))
	case ast.KindFalseKeyword:
		return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueBoolean(false))
	case ast.KindNullKeyword:
		return zigar_typescript_types.MakeTypeKindNullType()
	case ast.KindPrefixUnaryExpression:
		pue := lit.AsPrefixUnaryExpression()
		if pue != nil && pue.Operand != nil && (pue.Operator == ast.KindMinusToken || pue.Operator == ast.KindPlusToken) {
			sign := 1.0
			prefix := ""
			if pue.Operator == ast.KindMinusToken {
				sign = -1.0
				prefix = "-"
			}
			if pue.Operand.Kind == ast.KindNumericLiteral {
				val, ok := parseTsNumericLiteral(pue.Operand.Text())
				if !ok {
					return zigar_typescript_types.MakeTypeKindUnknownType()
				}
				return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueNum(sign * val))
			}
			if pue.Operand.Kind == ast.KindBigIntLiteral {
				clean := prefix + strings.TrimSuffix(strings.ReplaceAll(pue.Operand.Text(), "_", ""), "n")
				return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueBigintLiteral(b.intern(clean)))
			}
		}
	}
	return zigar_typescript_types.MakeTypeKindUnknownType()
}

func (b *graphBuilder) unwrapVariadicTupleElemAST(node *ast.Node) *ast.Node {
	if node == nil {
		return nil
	}
	cur := ast.SkipTypeParentheses(node)
	if cur == nil {
		return node
	}
	switch cur.Kind {
	case ast.KindArrayType:
		if at := cur.AsArrayTypeNode(); at != nil && at.ElementType != nil {
			return at.ElementType
		}
	case ast.KindTypeOperator:
		if to := cur.AsTypeOperatorNode(); to != nil && to.Operator == ast.KindReadonlyKeyword && to.Type != nil {
			inner := ast.SkipTypeParentheses(to.Type)
			if inner != nil && inner.Kind == ast.KindArrayType {
				if at := inner.AsArrayTypeNode(); at != nil && at.ElementType != nil {
					return at.ElementType
				}
			}
		}
	case ast.KindTypeReference:
		tr := cur.AsTypeReferenceNode()
		if tr != nil && tr.TypeName != nil && tr.TypeArguments != nil && len(tr.TypeArguments.Nodes) == 1 {
			rawName := entityNameToString(tr.TypeName)
			if rawName == "Array" || rawName == "ReadonlyArray" || rawName == "globalThis.Array" || rawName == "globalThis.ReadonlyArray" {
				sym := b.tc.GetSymbolAtLocation(tr.TypeName)
				sym = b.resolveAliasSymbol(sym)
				sym = b.canonicalSymbol(sym)
				if sym == nil || (!b.hasExtractableDecl(sym) && sym.Flags()&ast.SymbolFlagsTypeParameter == 0) {
					return tr.TypeArguments.Nodes[0]
				}
			}
		}
	}
	return node
}

func (b *graphBuilder) extractTupleElementsAST(tt *ast.TupleTypeNode) []zigar_typescript_types.TupleElement {
	if tt == nil || tt.Elements == nil {
		return []zigar_typescript_types.TupleElement{}
	}
	elems := make([]zigar_typescript_types.TupleElement, 0, len(tt.Elements.Nodes))
	for _, el := range tt.Elements.Nodes {
		if el == nil {
			continue
		}
		switch el.Kind {
		case ast.KindNamedTupleMember:
			ntm := el.AsNamedTupleMember()
			if ntm == nil {
				continue
			}
			labelOpt := witTypes.None[uint32]()
			if el.Name() != nil {
				labelOpt = witTypes.Some(b.intern(el.Name().Text()))
			}
			elemTyNode := ntm.Type
			variadic := ntm.DotDotDotToken != nil
			if variadic {
				elemTyNode = b.unwrapVariadicTupleElemAST(elemTyNode)
			}
			elems = append(elems, zigar_typescript_types.TupleElement{
				Label:    labelOpt,
				Ty:       b.extractTypeNode(elemTyNode),
				Optional: ntm.QuestionToken != nil,
				Variadic: variadic,
			})

		case ast.KindOptionalType:
			ot := el.AsOptionalTypeNode()
			elems = append(elems, zigar_typescript_types.TupleElement{
				Label:    witTypes.None[uint32](),
				Ty:       b.extractTypeNode(ot.Type),
				Optional: true,
				Variadic: false,
			})

		case ast.KindRestType:
			rt := el.AsRestTypeNode()
			inner := b.unwrapVariadicTupleElemAST(rt.Type)
			elems = append(elems, zigar_typescript_types.TupleElement{
				Label:    witTypes.None[uint32](),
				Ty:       b.extractTypeNode(inner),
				Optional: false,
				Variadic: true,
			})

		default:
			elems = append(elems, zigar_typescript_types.TupleElement{
				Label:    witTypes.None[uint32](),
				Ty:       b.extractTypeNode(el),
				Optional: false,
				Variadic: false,
			})
		}
	}
	return elems
}

func (b *graphBuilder) extractTypeNodeList(list *ast.NodeList) []uint32 {
	if list == nil || len(list.Nodes) == 0 {
		return []uint32{}
	}
	out := make([]uint32, 0, len(list.Nodes))
	for _, n := range list.Nodes {
		if n != nil {
			out = append(out, b.extractTypeNode(n))
		}
	}
	return out
}

func collectDirectInferParams(node *ast.Node) []*ast.Node {
	var out []*ast.Node
	var walk func(n *ast.Node)
	walk = func(n *ast.Node) {
		if n == nil {
			return
		}
		if n.Kind == ast.KindConditionalType {
			// Nested conditional types own their own `infer` parameters in their `ExtendsType`,
			// though `CheckType` of a nested conditional inside our `ExtendsType` is still in our scope.
			ct := n.AsConditionalTypeNode()
			if ct != nil {
				walk(ct.CheckType)
			}
			return
		}
		if n.Kind == ast.KindInferType {
			it := n.AsInferTypeNode()
			if it != nil && it.TypeParameter != nil && it.TypeParameter.Kind == ast.KindTypeParameter {
				out = append(out, it.TypeParameter)
				if tpd := it.TypeParameter.AsTypeParameterDeclaration(); tpd != nil && tpd.Constraint != nil {
					walk(tpd.Constraint)
				}
			}
			return
		}
		n.ForEachChild(func(child *ast.Node) bool {
			walk(child)
			return false
		})
	}
	walk(node)
	return out
}

func convertMappedModifierToken(tok *ast.Node) zigar_typescript_types.MappedModifier {
	if tok == nil {
		return zigar_typescript_types.MappedModifier_None
	}
	switch tok.Kind {
	case ast.KindMinusToken:
		return zigar_typescript_types.MappedModifier_Remove
	case ast.KindPlusToken, ast.KindReadonlyKeyword, ast.KindQuestionToken:
		return zigar_typescript_types.MappedModifier_Add
	default:
		return zigar_typescript_types.MappedModifier_None
	}
}

// extractCheckerType lowers a semantic `*checker.Type` into `b.types` with cycle-safe memoization.
func (b *graphBuilder) extractCheckerType(t *checker.Type) uint32 {
	return b.extractCheckerTypeWithMode(t, false)
}

func (b *graphBuilder) extractExpandedCheckerType(t *checker.Type) uint32 {
	return b.extractCheckerTypeWithMode(t, true)
}

func (b *graphBuilder) extractCheckerTypeWithMode(t *checker.Type, expandAlias bool) uint32 {
	if t == nil {
		return b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
	}
	memo := b.checkerTypeMemo
	if expandAlias {
		memo = b.expandedTypeMemo
	}
	if existing, ok := memo[t]; ok {
		return existing
	}

	id := b.allocType(zigar_typescript_types.MakeTypeKindAnyType())
	memo[t] = id

	kind := b.buildCheckerTypeKind(t, expandAlias)
	b.types[id].Kind = kind
	return id
}

func (b *graphBuilder) buildCheckerTypeKind(t *checker.Type, expandAlias bool) zigar_typescript_types.TypeKind {
	if t == nil {
		return zigar_typescript_types.MakeTypeKindAnyType()
	}

	// Preserve non-expanded alias references (`type Foo<T> = ...`) unless we are computing `ResolvedType`.
	if !expandAlias {
		if alias := t.Alias(); alias != nil && alias.Symbol() != nil {
			aliasSym := b.canonicalSymbol(alias.Symbol())
			if aliasSym != nil && aliasSym.Name() != "" {
				typeArgs := []uint32{}
				for _, arg := range alias.TypeArguments() {
					typeArgs = append(typeArgs, b.extractCheckerType(arg))
				}
				targetDecl := witTypes.None[uint32]()
				modSpec := witTypes.None[uint32]()
				ids := b.populateTypeTargetSymbol(aliasSym)
				if len(ids) > 0 {
					targetDecl = witTypes.Some(ids[0])
					declMod := b.decls[ids[0]].Module
					if int(declMod) < len(b.modules) {
						modSpec = witTypes.Some(b.modules[declMod].Specifier)
					}
				}
				return zigar_typescript_types.MakeTypeKindReference(zigar_typescript_types.TypeRefData{
					TargetDecl:      targetDecl,
					TargetName:      b.intern(aliasSym.Name()),
					ModuleSpecifier: modSpec,
					TypeArgs:        typeArgs,
				})
			}
		}
	}

	flags := t.Flags()

	// Unwrap SubstitutionType (`T & Constraint` inside narrowed conditional branches).
	if flags&checker.TypeFlagsSubstitution != 0 {
		return b.buildCheckerTypeKind(t.AsSubstitutionType().BaseType(), expandAlias)
	}

	// Primitives & Intrinsics.
	switch {
	case flags&checker.TypeFlagsAny != 0:
		return zigar_typescript_types.MakeTypeKindAnyType()
	case flags&checker.TypeFlagsUnknown != 0:
		return zigar_typescript_types.MakeTypeKindUnknownType()
	case flags&checker.TypeFlagsNever != 0:
		return zigar_typescript_types.MakeTypeKindNeverType()
	case flags&checker.TypeFlagsVoid != 0:
		return zigar_typescript_types.MakeTypeKindVoidType()
	case flags&checker.TypeFlagsUndefined != 0:
		return zigar_typescript_types.MakeTypeKindUndefinedType()
	case flags&checker.TypeFlagsNull != 0:
		return zigar_typescript_types.MakeTypeKindNullType()
	case flags&checker.TypeFlagsBoolean != 0 && flags&checker.TypeFlagsBooleanLiteral == 0:
		return zigar_typescript_types.MakeTypeKindBooleanType()
	case flags&checker.TypeFlagsNumber != 0 && flags&checker.TypeFlagsNumberLiteral == 0:
		return zigar_typescript_types.MakeTypeKindNumberType()
	case flags&checker.TypeFlagsBigInt != 0 && flags&checker.TypeFlagsBigIntLiteral == 0:
		return zigar_typescript_types.MakeTypeKindBigintType()
	case flags&checker.TypeFlagsString != 0 && flags&checker.TypeFlagsStringLiteral == 0:
		return zigar_typescript_types.MakeTypeKindStringType()
	case flags&checker.TypeFlagsESSymbol != 0 && flags&checker.TypeFlagsUniqueESSymbol == 0:
		return zigar_typescript_types.MakeTypeKindSymbolType()
	case flags&checker.TypeFlagsNonPrimitive != 0:
		return zigar_typescript_types.MakeTypeKindObjectType()
	}

	// Unique ES Symbol (`unique symbol`).
	if flags&checker.TypeFlagsUniqueESSymbol != 0 {
		symName := "unique symbol"
		if sym := t.Symbol(); sym != nil && sym.Name() != "" {
			symName = sym.Name()
		}
		return zigar_typescript_types.MakeTypeKindUniqueSymbol(b.intern(symName))
	}

	// Computed Enum (`TypeFlagsEnum` without literal value) or Enum Union (`enum Color { A, B }`).
	if sym := b.canonicalSymbol(t.Symbol()); sym != nil {
		if (sym.Flags()&(ast.SymbolFlagsRegularEnum|ast.SymbolFlagsConstEnum)) != 0 && flags&checker.TypeFlagsEnumLiteral == 0 {
			ids := b.populateTypeTargetSymbol(sym)
			targetDecl := witTypes.None[uint32]()
			modSpec := witTypes.None[uint32]()
			if len(ids) > 0 {
				targetDecl = witTypes.Some(ids[0])
				declMod := b.decls[ids[0]].Module
				if int(declMod) < len(b.modules) {
					modSpec = witTypes.Some(b.modules[declMod].Specifier)
				}
			}
			return zigar_typescript_types.MakeTypeKindReference(zigar_typescript_types.TypeRefData{
				TargetDecl:      targetDecl,
				TargetName:      b.intern(sym.Name()),
				ModuleSpecifier: modSpec,
				TypeArgs:        []uint32{},
			})
		}
	}

	// Literals (`string`, `number`, `bigint`, `boolean`, and enum literals).
	if flags&(checker.TypeFlagsStringLiteral|checker.TypeFlagsNumberLiteral|checker.TypeFlagsBigIntLiteral|checker.TypeFlagsBooleanLiteral|checker.TypeFlagsEnum) != 0 {
		if flags&checker.TypeFlagsEnum != 0 && flags&(checker.TypeFlagsStringLiteral|checker.TypeFlagsNumberLiteral) == 0 {
			// Computed enum member whose `LiteralType.Value()` is nil.
			sym := b.canonicalSymbol(t.Symbol())
			name := "enum"
			if sym != nil {
				name = sym.Name()
				if sym.Parent() != nil {
					name = sym.Parent().Name() + "." + sym.Name()
				}
			}
			ids := b.populateTypeTargetSymbol(sym)
			targetDecl := witTypes.None[uint32]()
			if len(ids) > 0 {
				targetDecl = witTypes.Some(ids[0])
			}
			return zigar_typescript_types.MakeTypeKindReference(zigar_typescript_types.TypeRefData{
				TargetDecl:      targetDecl,
				TargetName:      b.intern(name),
				ModuleSpecifier: witTypes.None[uint32](),
				TypeArgs:        []uint32{},
			})
		}

		lt := t.AsLiteralType()
		switch v := lt.Value().(type) {
		case string:
			return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueStr(b.intern(v)))
		case jsnum.Number:
			return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueNum(float64(v)))
		case float64:
			return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueNum(v))
		case jsnum.PseudoBigInt:
			return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueBigintLiteral(b.intern(v.String())))
		case bool:
			return zigar_typescript_types.MakeTypeKindLiteral(zigar_typescript_types.MakeLiteralValueBoolean(v))
		}
	}

	// TypeParameter & `this` type.
	if flags&checker.TypeFlagsTypeParameter != 0 {
		tp := t.AsTypeParameter()
		if tp != nil && tp.IsThisType() {
			return zigar_typescript_types.MakeTypeKindThisType()
		}
		tpID := b.ensureCheckerTypeParam(t)
		return zigar_typescript_types.MakeTypeKindTypeParam(tpID)
	}

	// `keyof T` (`TypeFlagsIndex`).
	if flags&checker.TypeFlagsIndex != 0 {
		return zigar_typescript_types.MakeTypeKindKeyofType(b.extractCheckerType(t.AsIndexType().Target()))
	}

	// `T[K]` (`TypeFlagsIndexedAccess`).
	if flags&checker.TypeFlagsIndexedAccess != 0 {
		ia := t.AsIndexedAccessType()
		return zigar_typescript_types.MakeTypeKindIndexedAccess(zigar_typescript_types.IndexedAccessData{
			ObjectTy: b.extractCheckerType(ia.ObjectType()),
			IndexTy:  b.extractCheckerType(ia.IndexType()),
		})
	}

	// Template literal type.
	if flags&checker.TypeFlagsTemplateLiteral != 0 {
		tl := t.AsTemplateLiteralType()
		texts := tl.Texts()
		types := tl.Types()
		head := ""
		if len(texts) > 0 {
			head = texts[0]
		}
		spans := make([]zigar_typescript_types.TemplateSpan, 0, len(types))
		for i, subTy := range types {
			tail := ""
			if i+1 < len(texts) {
				tail = texts[i+1]
			}
			spans = append(spans, zigar_typescript_types.TemplateSpan{
				Ty:      b.extractCheckerType(subTy),
				Literal: b.intern(tail),
			})
		}
		return zigar_typescript_types.MakeTypeKindTemplateLiteral(zigar_typescript_types.TemplateLiteralData{
			Head:  b.intern(head),
			Spans: spans,
		})
	}

	// String mapping intrinsic (`Uppercase<T>`, `Lowercase<T>`, `Capitalize<T>`, `Uncapitalize<T>`).
	if flags&checker.TypeFlagsStringMapping != 0 {
		name := "intrinsic"
		if sym := t.Symbol(); sym != nil && sym.Name() != "" {
			name = sym.Name()
		}
		return zigar_typescript_types.MakeTypeKindIntrinsic(b.intern(name))
	}

	// Conditional type.
	if flags&checker.TypeFlagsConditional != 0 {
		ct := t.AsConditionalType()
		checkID := b.extractCheckerType(ct.CheckType())
		extendsID := b.extractCheckerType(ct.ExtendsType())
		trueID := b.extractCheckerType(b.tc.GetTrueTypeOfConditionalType(t))
		falseID := b.extractCheckerType(b.tc.GetFalseTypeOfConditionalType(t))
		return zigar_typescript_types.MakeTypeKindConditional(zigar_typescript_types.ConditionalTypeData{
			CheckType:   checkID,
			ExtendsType: extendsID,
			TrueType:    trueID,
			FalseType:   falseID,
			InferParams: []uint32{},
		})
	}

	// Union & Intersection.
	if flags&checker.TypeFlagsUnion != 0 {
		parts := t.Types()
		members := make([]uint32, 0, len(parts))
		for _, m := range parts {
			members = append(members, b.extractCheckerTypeWithMode(m, expandAlias))
		}
		return zigar_typescript_types.MakeTypeKindUnionType(members)
	}
	if flags&checker.TypeFlagsIntersection != 0 {
		parts := t.Types()
		members := make([]uint32, 0, len(parts))
		for _, m := range parts {
			members = append(members, b.extractCheckerTypeWithMode(m, expandAlias))
		}
		return zigar_typescript_types.MakeTypeKindIntersection(members)
	}

	// Object types (Tuples, Arrays, Mapped types, Nominal Class/Interface References, Function/Constructor types, Anonymous Object Literals).
	if flags&checker.TypeFlagsObject != 0 {
		return b.buildCheckerObjectTypeKind(t, expandAlias)
	}

	return zigar_typescript_types.MakeTypeKindAnyType()
}

func (b *graphBuilder) buildCheckerObjectTypeKind(t *checker.Type, expandAlias bool) zigar_typescript_types.TypeKind {
	objFlags := t.ObjectFlags()

	// 1. Tuple & ReadonlyTuple.
	if checker.IsTupleType(t) {
		tt := t.TargetTupleType()
		infos := tt.ElementInfos()
		args := b.tc.GetTypeArguments(t)
		elems := make([]zigar_typescript_types.TupleElement, 0, len(infos))
		for i, info := range infos {
			var argTy *checker.Type
			if i < len(args) {
				argTy = args[i]
			}
			labelOpt := witTypes.None[uint32]()
			if ld := info.LabeledDeclaration(); ld != nil && ld.Name() != nil {
				labelOpt = witTypes.Some(b.intern(ld.Name().Text()))
			}
			ef := info.TupleElementFlags()
			if ef&checker.ElementFlagsVariadic != 0 && ef&checker.ElementFlagsRest == 0 && argTy != nil && b.tc.IsArrayType(argTy) {
				argTy = b.tc.GetElementTypeOfArrayType(argTy)
			}
			elems = append(elems, zigar_typescript_types.TupleElement{
				Label:    labelOpt,
				Ty:       b.extractCheckerType(argTy),
				Optional: ef&checker.ElementFlagsOptional != 0,
				Variadic: ef&(checker.ElementFlagsRest|checker.ElementFlagsVariadic) != 0,
			})
		}
		if tt.IsReadonly() {
			return zigar_typescript_types.MakeTypeKindReadonlyTuple(elems)
		}
		return zigar_typescript_types.MakeTypeKindTuple(elems)
	}

	// 2. Array & ReadonlyArray.
	if b.tc.IsArrayType(t) {
		elem := b.tc.GetElementTypeOfArrayType(t)
		elemID := b.extractCheckerType(elem)
		isReadonly := false
		if tgt := t.Target(); tgt != nil && tgt.Symbol() != nil && tgt.Symbol().Name() == "ReadonlyArray" {
			isReadonly = true
		} else if t.Symbol() != nil && t.Symbol().Name() == "ReadonlyArray" {
			isReadonly = true
		}
		if isReadonly {
			return zigar_typescript_types.MakeTypeKindReadonlyArray(elemID)
		}
		return zigar_typescript_types.MakeTypeKindArray(elemID)
	}

	// 3. Nominal Class or Interface (or Generic TypeReference to Class/Interface).
	var targetSym *ast.Symbol
	var typeArgs []*checker.Type
	if objFlags&checker.ObjectFlagsReference != 0 && t.Target() != nil && t.Target().ObjectFlags()&checker.ObjectFlagsClassOrInterface != 0 {
		targetSym = b.canonicalSymbol(t.Target().Symbol())
		typeArgs = b.tc.GetTypeArguments(t)
	} else if objFlags&checker.ObjectFlagsClassOrInterface != 0 {
		targetSym = b.canonicalSymbol(t.Symbol())
	}

	if targetSym != nil && targetSym.Name() != "" && !strings.HasPrefix(targetSym.Name(), "__") {
		argIDs := make([]uint32, 0, len(typeArgs))
		for _, a := range typeArgs {
			argIDs = append(argIDs, b.extractCheckerType(a))
		}
		targetDecl := witTypes.None[uint32]()
		modSpec := witTypes.None[uint32]()
		ids := b.populateTypeTargetSymbol(targetSym)
		if len(ids) > 0 {
			targetDecl = witTypes.Some(ids[0])
			declMod := b.decls[ids[0]].Module
			if int(declMod) < len(b.modules) {
				modSpec = witTypes.Some(b.modules[declMod].Specifier)
			}
		}
		return zigar_typescript_types.MakeTypeKindReference(zigar_typescript_types.TypeRefData{
			TargetDecl:      targetDecl,
			TargetName:      b.intern(targetSym.Name()),
			ModuleSpecifier: modSpec,
			TypeArgs:        argIDs,
		})
	}

	// 4. Unexpanded generic MappedType (when not expanding into concrete properties or when constraint is still generic).
	if !expandAlias && objFlags&checker.ObjectFlagsMapped != 0 &&
		objFlags&(checker.ObjectFlagsClassOrInterface|checker.ObjectFlagsTuple|checker.ObjectFlagsReference) == 0 {
		mt := t.AsMappedType()
		mt.ResolveComponents(b.tc, t)
		tpID := b.ensureCheckerTypeParam(mt.TypeParameter())
		if c := mt.ConstraintType(); c != nil {
			b.typeParams[tpID].Constraint = witTypes.Some(b.extractCheckerType(c))
		}
		nameOpt := witTypes.None[uint32]()
		if nt := mt.NameType(); nt != nil {
			nameOpt = witTypes.Some(b.extractCheckerType(nt))
		}
		valID := b.extractCheckerType(mt.TemplateType())
		var roMod, optMod zigar_typescript_types.MappedModifier
		if sym := t.Symbol(); sym != nil {
			for _, d := range sym.Declarations() {
				if d != nil && d.Kind == ast.KindMappedType {
					if decl := d.AsMappedTypeNode(); decl != nil {
						roMod = convertMappedModifierToken(decl.ReadonlyToken)
						optMod = convertMappedModifierToken(decl.QuestionToken)
						break
					}
				}
			}
		}
		return zigar_typescript_types.MakeTypeKindMapped(zigar_typescript_types.MappedTypeData{
			TypeParam:        tpID,
			NameType:         nameOpt,
			ValueType:        valID,
			ReadonlyModifier: roMod,
			OptionalModifier: optMod,
		})
	}

	// 5. Pure single-signature FunctionType or ConstructorType vs structural ObjectLiteral!
	props := b.tc.GetPropertiesOfType(t)
	callSigs := b.tc.GetSignaturesOfType(t, checker.SignatureKindCall)
	ctorSigs := b.tc.GetSignaturesOfType(t, checker.SignatureKindConstruct)
	indexInfos := b.tc.GetIndexInfosOfType(t)

	if len(props) == 0 && len(indexInfos) == 0 {
		if len(callSigs) == 1 && len(ctorSigs) == 0 {
			return zigar_typescript_types.MakeTypeKindFunctionType(b.extractCheckerSignature(callSigs[0], false))
		}
		if len(ctorSigs) == 1 && len(callSigs) == 0 {
			isAbs := objFlags&checker.ObjectFlagsIsClassInstanceClone != 0 || ctorSigs[0].Flags()&checker.SignatureFlagsAbstract != 0
			return zigar_typescript_types.MakeTypeKindConstructorType(b.extractCheckerSignature(ctorSigs[0], isAbs))
		}
	}

	// 6. Structural ObjectLiteral (includes evaluated Partial<T>, Pick<T, K>, Record<string, V>, etc.!).
	propIDs := make([]uint32, 0, len(props))
	skippedPrivate := false
	for _, propSym := range props {
		if propSym == nil {
			continue
		}
		if !b.cfg.IncludePrivateMembers && b.isPrivateSymbol(propSym) {
			skippedPrivate = true
			continue
		}
		propIDs = append(propIDs, b.extractCheckerPropertySymbol(propSym, t))
	}
	if skippedPrivate {
		propIDs = append(propIDs, b.allocPrivateBrandProp())
	}

	callSigIDs := make([]uint32, 0, len(callSigs))
	for _, s := range callSigs {
		callSigIDs = append(callSigIDs, b.extractCheckerSignature(s, false))
	}
	ctorSigIDs := make([]uint32, 0, len(ctorSigs))
	for _, s := range ctorSigs {
		ctorSigIDs = append(ctorSigIDs, b.extractCheckerSignature(s, s.Flags()&checker.SignatureFlagsAbstract != 0))
	}
	idxNodes := make([]zigar_typescript_types.IndexSigNode, 0, len(indexInfos))
	for _, idx := range indexInfos {
		if idx == nil {
			continue
		}
		keyName := "key"
		if idx.Declaration() != nil && idx.Declaration().Kind == ast.KindIndexSignature {
			isd := idx.Declaration().AsIndexSignatureDeclaration()
			if isd != nil && isd.Parameters != nil && len(isd.Parameters.Nodes) > 0 && isd.Parameters.Nodes[0].Name() != nil {
				keyName = isd.Parameters.Nodes[0].Name().Text()
			}
		}
		idxNodes = append(idxNodes, zigar_typescript_types.IndexSigNode{
			KeyName:    b.intern(keyName),
			KeyType:    b.extractCheckerType(idx.KeyType()),
			ValueType:  b.extractCheckerType(idx.ValueType()),
			IsReadonly: idx.IsReadonly(),
		})
	}

	return zigar_typescript_types.MakeTypeKindObjectLiteral(zigar_typescript_types.ObjectTypeData{
		Properties:          propIDs,
		CallSignatures:      callSigIDs,
		ConstructSignatures: ctorSigIDs,
		IndexSignatures:     idxNodes,
	})
}
