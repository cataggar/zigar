package export_zigar_typescript_extractor

import (
	"strings"

	"github.com/microsoft/TypeScript/tsc/internal/ast"
	"github.com/microsoft/TypeScript/tsc/internal/zigarwit/imports/zigar_typescript_types"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

func (b *graphBuilder) matchesModuleFilter(spec string) bool {
	if len(b.modFilter) == 0 {
		return true
	}
	if b.modFilter[spec] {
		return true
	}
	if trimmed, ok := strings.CutPrefix(spec, "node:"); ok && b.modFilter[trimmed] {
		return true
	}
	if !strings.HasPrefix(spec, "node:") && b.modFilter["node:"+spec] {
		return true
	}
	return false
}

func (b *graphBuilder) sourceFileMatchesFilter(sf *ast.SourceFile, spec string) bool {
	if len(b.modFilter) == 0 {
		return true
	}
	if sf == nil {
		return false
	}
	if b.matchesModuleFilter(spec) || b.matchesModuleFilter(sf.FileName().AsString()) {
		return true
	}
	if sf.Statements != nil {
		for _, stmt := range sf.Statements.Nodes {
			if stmt != nil && stmt.Kind == ast.KindModuleDeclaration && ast.IsAmbientModule(stmt) && stmt.Name() != nil {
				if b.matchesModuleFilter(stmt.Name().Text()) {
					return true
				}
			}
		}
	}
	return false
}

func (b *graphBuilder) ensureModule(sf *ast.SourceFile, enqueue bool) uint32 {
	if sf == nil {
		return 0
	}
	return b.ensureModuleWithSpecifier(sf, sf.FileName().AsString(), enqueue)
}

func (b *graphBuilder) ensureModuleWithSpecifier(sf *ast.SourceFile, specifier string, enqueue bool) uint32 {
	filePath := sf.FileName().AsString()
	if existingID, ok := b.moduleByFile[filePath]; ok {
		if enqueue && !b.extractedModules[existingID] {
			b.enqueueModule(existingID)
		}
		return existingID
	}

	if specifier == "" {
		specifier = filePath
	}

	modID := uint32(len(b.modules))
	b.moduleByFile[filePath] = modID
	b.sfByModule[modID] = sf

	b.modules = append(b.modules, zigar_typescript_types.ModuleNode{
		Id:                  modID,
		Specifier:           b.intern(specifier),
		FilePath:            b.intern(filePath),
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

	if enqueue {
		b.enqueueModule(modID)
	}
	return modID
}

func (b *graphBuilder) enqueueModule(modID uint32) {
	if b.extractedModules[modID] {
		return
	}
	for _, queued := range b.moduleQueue {
		if queued == modID {
			return
		}
	}
	b.moduleQueue = append(b.moduleQueue, modID)
}

func (b *graphBuilder) seedConfiguredModuleSpecifiers(seenEntryMod map[uint32]bool) {
	for _, sf := range b.tsProg.GetSourceFiles() {
		if !b.isExtractableSourceFile(sf) {
			continue
		}
		fn := sf.FileName().AsString()
		if b.sourceFileMatchesFilter(sf, fn) {
			modID := b.ensureModule(sf, true)
			if !seenEntryMod[modID] {
				seenEntryMod[modID] = true
				b.entryModules = append(b.entryModules, modID)
			}
		}
	}
}

func (b *graphBuilder) drainModuleQueue() {
	for len(b.moduleQueue) > 0 {
		modID := b.moduleQueue[0]
		b.moduleQueue = b.moduleQueue[1:]
		if b.extractedModules[modID] {
			continue
		}
		b.extractedModules[modID] = true
		b.extractModule(modID)
	}
}

func (b *graphBuilder) resolveModuleSpecifierNode(sf *ast.SourceFile, specNode *ast.Node) *ast.SourceFile {
	if sf == nil || specNode == nil || !ast.IsStringLiteralLike(specNode) {
		return nil
	}
	if resolved := b.tsProg.GetResolvedModuleFromModuleSpecifier(sf, specNode); resolved != nil && resolved.IsResolved() {
		if targetSF := b.tsProg.GetSourceFileForResolvedModule(resolved); targetSF != nil {
			return targetSF
		}
	}
	return b.prog.ResolveSourceFile(specNode.Text())
}

func (b *graphBuilder) extractModule(modID uint32) {
	sf := b.sfByModule[modID]
	if sf == nil {
		return
	}

	// 1. Triple-slash directives: types, paths, libs.
	for _, ref := range sf.TypeReferenceDirectives {
		if ref == nil {
			continue
		}
		b.modules[modID].TripleSlashTypes = append(b.modules[modID].TripleSlashTypes, b.intern(ref.FileName))
		if resolved := b.tsProg.GetResolvedTypeReferenceDirectiveFromTypeReferenceDirective(ref, sf); resolved != nil && resolved.IsResolved() {
			if targetSF := b.tsProg.GetSourceFileByPath(resolved.ResolvedPath); targetSF != nil && b.isExtractableSourceFile(targetSF) {
				b.ensureModule(targetSF, true)
			}
		}
	}

	for _, ref := range sf.ReferencedFiles {
		if ref == nil {
			continue
		}
		b.modules[modID].TripleSlashPaths = append(b.modules[modID].TripleSlashPaths, b.intern(ref.FileName))
		if targetSF := b.tsProg.GetSourceFileFromReference(sf, ref); targetSF != nil && b.isExtractableSourceFile(targetSF) {
			b.ensureModule(targetSF, true)
		}
	}

	for _, ref := range sf.LibReferenceDirectives {
		if ref == nil {
			continue
		}
		b.modules[modID].TripleSlashLibs = append(b.modules[modID].TripleSlashLibs, b.intern(ref.FileName))
	}

	if sf.Statements == nil {
		return
	}

	reExportedNames := map[string]bool{}
	var ambientOrder []string
	ambientBlocks := map[string][]*ast.Node{}
	seenGlobalDecl := map[uint32]bool{}
	seenExportDecl := map[uint32]bool{}

	appendExport := func(id uint32) {
		if !seenExportDecl[id] {
			seenExportDecl[id] = true
			b.modules[modID].Exports = append(b.modules[modID].Exports, id)
		}
	}
	appendGlobal := func(id uint32) {
		if !seenGlobalDecl[id] {
			seenGlobalDecl[id] = true
			b.modules[modID].GlobalAugmentations = append(b.modules[modID].GlobalAugmentations, id)
		}
	}

	// 2. Inspect top-level directives, export assignments, re-exports, ambient modules, and `declare global`.
	for _, stmt := range sf.Statements.Nodes {
		if stmt == nil {
			continue
		}

		switch stmt.Kind {
		case ast.KindNamespaceExportDeclaration:
			if stmt.Name() != nil {
				b.modules[modID].UmdNamespace = witTypes.Some(b.intern(stmt.Name().Text()))
			}

		case ast.KindExportAssignment:
			ea := stmt.AsExportAssignment()
			if ea == nil {
				continue
			}
			if ea.IsExportEquals {
				if idOpt := b.extractExportAssignmentTarget(sf, modID, stmt, ea.Expression, "export="); isSome(idOpt) {
					b.modules[modID].ExportEquals = idOpt
				}
			} else {
				if idOpt := b.extractExportAssignmentTarget(sf, modID, stmt, ea.Expression, "default"); isSome(idOpt) {
					b.modules[modID].DefaultExport = idOpt
				}
			}

		case ast.KindExportDeclaration:
			ed := stmt.AsExportDeclaration()
			if ed == nil || ed.ModuleSpecifier == nil {
				continue
			}
			specText := ed.ModuleSpecifier.Text()
			targetSF := b.resolveModuleSpecifierNode(sf, ed.ModuleSpecifier)
			targetModOpt := witTypes.None[uint32]()
			if targetSF != nil && b.isExtractableSourceFile(targetSF) {
				targetModID := b.ensureModuleWithSpecifier(targetSF, specText, b.cfg.FollowReExports)
				targetModOpt = witTypes.Some(targetModID)
			}

			if ed.ExportClause == nil {
				// `export * from "./mod"`
				if isSome(targetModOpt) {
					b.modules[modID].StarReExports = appendUniqueU32(b.modules[modID].StarReExports, targetModOpt.Some())
				}
			} else if ed.ExportClause.Kind == ast.KindNamespaceExport {
				// `export * as ns from "./mod"`
				nsName := ""
				if ed.ExportClause.Name() != nil {
					nsName = ed.ExportClause.Name().Text()
				}
				reExportedNames[nsName] = true
				declID := b.makeReExportDecl(sf, modID, ed.ExportClause, nsName, "*", specText, targetModOpt, witTypes.None[uint32](), ed.IsTypeOnly)
				appendExport(declID)
			} else if ed.ExportClause.Kind == ast.KindNamedExports {
				ne := ed.ExportClause.AsNamedExports()
				if ne != nil && ne.Elements != nil {
					for _, elem := range ne.Elements.Nodes {
						if elem == nil || elem.Kind != ast.KindExportSpecifier {
							continue
						}
						es := elem.AsExportSpecifier()
						if es == nil || es.Name() == nil {
							continue
						}
						exportName := es.Name().Text()
						origName := exportName
						if es.PropertyName != nil {
							origName = es.PropertyName.Text()
						}
						targetDeclOpt := witTypes.None[uint32]()
						if b.cfg.FollowReExports {
							targetDeclOpt = b.resolveExportSpecifierTarget(elem)
						}
						isTypeOnly := ed.IsTypeOnly || es.IsTypeOnly
						declID := b.makeReExportDecl(sf, modID, elem, exportName, origName, specText, targetModOpt, targetDeclOpt, isTypeOnly)
						if exportName == "default" {
							if isNone(b.modules[modID].DefaultExport) {
								b.modules[modID].DefaultExport = witTypes.Some(declID)
							}
						} else {
							reExportedNames[exportName] = true
							appendExport(declID)
						}
					}
				}
			}

		case ast.KindImportEqualsDeclaration:
			// `export import X = require("...")` or `export import X = Ns.Y`
			if ast.GetCombinedModifierFlags(stmt)&ast.ModifierFlagsExport != 0 && stmt.Name() != nil {
				ieName := stmt.Name().Text()
				reExportedNames[ieName] = true
				if idOpt := b.extractImportEqualsNode(sf, modID, stmt); isSome(idOpt) {
					appendExport(idOpt.Some())
				}
			}

		case ast.KindModuleDeclaration:
			if ast.IsGlobalScopeAugmentation(stmt) {
				for _, id := range b.extractStatementBlockDecls(sf, modID, stmt.Body(), false) {
					appendGlobal(id)
				}
			} else if ast.IsAmbientModule(stmt) && stmt.Name() != nil {
				ambName := stmt.Name().Text()
				// Extract any nested `global { ... }` augmentations inside ambient modules (e.g. `@types/node` events.d.ts).
				b.extractNestedGlobalBlocks(sf, modID, stmt.Body(), appendGlobal)
				if b.matchesModuleFilter(ambName) {
					if _, exists := ambientBlocks[ambName]; !exists {
						ambientOrder = append(ambientOrder, ambName)
					}
					ambientBlocks[ambName] = append(ambientBlocks[ambName], stmt)
				}
			}
		}
	}

	// 3. Extract module-level exports (for external modules) or script-level globals (for ambient/script files).
	if ast.IsExternalModule(sf) {
		modSym := b.tc.GetSymbolOfNode(sf.AsNode())
		if modSym == nil {
			modSym = sf.AsNode().Symbol()
		}
		if modSym != nil {
			modExports := b.tc.GetExportsOfModule(modSym)
			exportByName := buildExportSymbolMap(modExports)
			for _, expSym := range modExports {
				if expSym == nil {
					continue
				}
				switch expSym.Name() {
				case "export=":
					continue
				case "default":
					if isNone(b.modules[modID].DefaultExport) {
						ids := b.extractExportedSymbolWithSet(sf, modID, expSym, true, exportByName)
						if len(ids) > 0 {
							b.modules[modID].DefaultExport = witTypes.Some(ids[0])
						}
					}
				default:
					if reExportedNames[expSym.Name()] {
						continue
					}
					// If follow-re-exports is false and this export comes solely from `export * from "..."`, skip duplicating it in Exports.
					if !b.cfg.FollowReExports && !b.isSymbolDeclaredInFile(expSym, sf) {
						continue
					}
					for _, id := range b.extractExportedSymbolWithSet(sf, modID, expSym, true, exportByName) {
						appendExport(id)
					}
				}
			}
		}
	} else {
		// Script / global declaration file (e.g. `@types/node` globals.d.ts, buffer.buffer.d.ts).
		for _, id := range b.extractTopLevelGlobalStatements(sf, modID, sf.Statements.Nodes) {
			appendGlobal(id)
		}
	}

	// 4. Extract deduplicated ambient module declarations (`declare module "node:fs"`, `declare module "fs"`, etc.).
	for _, ambName := range ambientOrder {
		blocks := ambientBlocks[ambName]
		decls := b.extractAmbientModuleDecls(sf, modID, ambName, blocks)
		b.modules[modID].AmbientModules = append(b.modules[modID].AmbientModules, zigar_typescript_types.AmbientModuleNode{
			ModuleName: b.intern(ambName),
			Decls:      decls,
		})
	}
}

func (b *graphBuilder) extractNestedGlobalBlocks(sf *ast.SourceFile, modID uint32, body *ast.Node, appendGlobal func(uint32)) {
	if body == nil || body.Kind != ast.KindModuleBlock {
		return
	}
	mb := body.AsModuleBlock()
	if mb == nil || mb.Statements == nil {
		return
	}
	for _, s := range mb.Statements.Nodes {
		if s != nil && s.Kind == ast.KindModuleDeclaration && ast.IsGlobalScopeAugmentation(s) {
			for _, id := range b.extractStatementBlockDecls(sf, modID, s.Body(), false) {
				appendGlobal(id)
			}
		}
	}
}

func (b *graphBuilder) extractAmbientModuleDecls(sf *ast.SourceFile, modID uint32, ambName string, blocks []*ast.Node) []uint32 {
	out := []uint32{}
	seen := map[uint32]bool{}
	reExported := map[string]bool{}
	addDecl := func(id uint32) {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}

	var ambSym *ast.Symbol
	if ambName != "" {
		ambSym = b.canonicalSymbol(b.tc.TryFindAmbientModule(ambName))
	}
	for _, blk := range blocks {
		if blk == nil {
			continue
		}
		if ambSym == nil {
			if s := b.tc.GetSymbolOfNode(blk); s != nil {
				ambSym = b.canonicalSymbol(s)
			} else if s := blk.Symbol(); s != nil {
				ambSym = b.canonicalSymbol(s)
			}
		}

		body := blk.Body()
		if body == nil || body.Kind != ast.KindModuleBlock {
			continue
		}
		mb := body.AsModuleBlock()
		if mb == nil || mb.Statements == nil {
			continue
		}

		for _, stmt := range mb.Statements.Nodes {
			if stmt == nil {
				continue
			}
			switch stmt.Kind {
			case ast.KindExportAssignment:
				ea := stmt.AsExportAssignment()
				if ea != nil {
					label := "default"
					if ea.IsExportEquals {
						label = "export="
					}
					if idOpt := b.extractExportAssignmentTarget(sf, modID, stmt, ea.Expression, label); isSome(idOpt) {
						addDecl(idOpt.Some())
						// Also surface any merged peers (e.g. `class EventEmitter` + `interface EventEmitter` + `namespace EventEmitter`).
						if sym := b.resolveExpressionSymbol(ea.Expression); sym != nil {
							for _, peerID := range b.extractSymbolAllCategories(sym, modID, true) {
								addDecl(peerID)
							}
						}
					}
				}

			case ast.KindImportEqualsDeclaration:
				if ast.GetCombinedModifierFlags(stmt)&ast.ModifierFlagsExport != 0 && stmt.Name() != nil {
					reExported[stmt.Name().Text()] = true
					if idOpt := b.extractImportEqualsNode(sf, modID, stmt); isSome(idOpt) {
						addDecl(idOpt.Some())
					}
				}

			case ast.KindExportDeclaration:
				ed := stmt.AsExportDeclaration()
				if ed == nil || ed.ModuleSpecifier == nil {
					continue
				}
				specText := ed.ModuleSpecifier.Text()
				targetSF := b.resolveModuleSpecifierNode(sf, ed.ModuleSpecifier)
				targetModOpt := witTypes.None[uint32]()
				if targetSF != nil && b.isExtractableSourceFile(targetSF) {
					targetModID := b.ensureModuleWithSpecifier(targetSF, specText, b.cfg.FollowReExports)
					targetModOpt = witTypes.Some(targetModID)
				}
				if ed.ExportClause == nil {
					// `export * from "node:fs"` inside `declare module "fs"`
					declID := b.makeReExportDecl(sf, modID, stmt, "*", "*", specText, targetModOpt, witTypes.None[uint32](), ed.IsTypeOnly)
					addDecl(declID)
				} else if ed.ExportClause.Kind == ast.KindNamespaceExport {
					nsName := ""
					if ed.ExportClause.Name() != nil {
						nsName = ed.ExportClause.Name().Text()
					}
					reExported[nsName] = true
					declID := b.makeReExportDecl(sf, modID, ed.ExportClause, nsName, "*", specText, targetModOpt, witTypes.None[uint32](), ed.IsTypeOnly)
					addDecl(declID)
				} else if ed.ExportClause.Kind == ast.KindNamedExports {
					ne := ed.ExportClause.AsNamedExports()
					if ne != nil && ne.Elements != nil {
						for _, elem := range ne.Elements.Nodes {
							if elem == nil || elem.Kind != ast.KindExportSpecifier {
								continue
							}
							es := elem.AsExportSpecifier()
							if es == nil || es.Name() == nil {
								continue
							}
							expName := es.Name().Text()
							origName := expName
							if es.PropertyName != nil {
								origName = es.PropertyName.Text()
							}
							reExported[expName] = true
							targetDeclOpt := witTypes.None[uint32]()
							if b.cfg.FollowReExports {
								targetDeclOpt = b.resolveExportSpecifierTarget(elem)
							}
							declID := b.makeReExportDecl(sf, modID, elem, expName, origName, specText, targetModOpt, targetDeclOpt, ed.IsTypeOnly || es.IsTypeOnly)
							addDecl(declID)
						}
					}
				}
			}
		}
	}

	if ambSym != nil {
		ambExports := b.tc.GetExportsOfModule(ambSym)
		exportByName := buildExportSymbolMap(ambExports)
		for _, expSym := range ambExports {
			if expSym == nil || expSym.Name() == "export=" || reExported[expSym.Name()] {
				continue
			}
			for _, id := range b.extractExportedSymbolWithSet(sf, modID, expSym, true, exportByName) {
				addDecl(id)
			}
		}
	}

	return out
}

func (b *graphBuilder) isSymbolDeclaredInFile(sym *ast.Symbol, sf *ast.SourceFile) bool {
	if sym == nil || sf == nil {
		return false
	}
	for _, d := range sym.Declarations() {
		if d != nil && ast.GetSourceFileOfNode(d) == sf {
			return true
		}
	}
	return false
}

func appendUniqueU32(slice []uint32, val uint32) []uint32 {
	for _, existing := range slice {
		if existing == val {
			return slice
		}
	}
	return append(slice, val)
}
