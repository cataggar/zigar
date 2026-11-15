package export_zigar_typescript_compiler

import (
	"io/fs"
	"maps"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/microsoft/TypeScript/tsc/internal/bundled"
	"github.com/microsoft/TypeScript/tsc/internal/tspath"
	"github.com/microsoft/TypeScript/tsc/internal/vfs"
	witTypes "go.bytecodealliance.org/pkg/wit/types"
)

var defaultRootDir = tspath.RootedDirectoryPathFromNormalized("/")

// Vfs exports `zigar:typescript/compiler.vfs`: an isolated in-memory virtual
// filesystem optionally backed by TypeScript 7.1's embedded `lib.*.d.ts` files.
type Vfs struct {
	pinner         runtime.Pinner
	handle         int32
	mem            *memFS
	fs             vfs.FS
	useBundledLibs bool
}

func (self *Vfs) OnDrop() {
	if self == nil || self.mem == nil {
		return
	}
	self.mem.clear()
	self.mem = nil
	self.fs = nil
}

func (self *Vfs) FS() vfs.FS {
	return self.fs
}

func (self *Vfs) DefaultLibraryPath() tspath.RootedDirectoryPath {
	if self.useBundledLibs {
		return bundled.LibPath()
	}
	return tspath.RootedDirectoryPathFromNormalized("/__no_bundled_libs__")
}

func MakeVfs(useBundledLibs bool) *Vfs {
	mem := newMemFS(tspath.CaseSensitive)
	var wrapped vfs.FS = mem
	if useBundledLibs {
		wrapped = bundled.WrapFS(mem)
	}
	return &Vfs{
		mem:            mem,
		fs:             wrapped,
		useBundledLibs: useBundledLibs,
	}
}

func (self *Vfs) WriteFile(path string, contents string) {
	rooted, ok := normalizeFilePath(path, defaultRootDir)
	if !ok {
		return
	}
	_ = self.mem.WriteFile(rooted, strings.Clone(contents))
}

func (self *Vfs) ReadFile(path string) witTypes.Option[string] {
	rooted, ok := normalizeFilePath(path, defaultRootDir)
	if !ok {
		return witTypes.None[string]()
	}
	content, found := self.fs.ReadFile(rooted)
	if !found {
		return witTypes.None[string]()
	}
	return witTypes.Some[string](content)
}

func (self *Vfs) FileExists(path string) bool {
	rooted, ok := normalizeFilePath(path, defaultRootDir)
	if !ok {
		return false
	}
	return self.fs.FileExists(rooted)
}

func (self *Vfs) DeleteFile(path string) bool {
	rooted, ok := normalizeFilePath(path, defaultRootDir)
	if !ok {
		return false
	}
	return self.mem.deleteFile(rooted)
}

func (self *Vfs) ListFiles(dir string) []string {
	rootedDir := normalizeDirPath(dir, defaultRootDir)
	return self.mem.listFilesUnder(rootedDir)
}

func normalizeFilePath(raw string, baseDir tspath.RootedDirectoryPath) (tspath.RootedFilePath, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || strings.ContainsAny(trimmed, "?#") {
		return "", false
	}
	if baseDir == "" {
		baseDir = defaultRootDir
	}
	return tspath.ToRootedFilePath(strings.Clone(trimmed), baseDir), true
}

func normalizeDirPath(raw string, baseDir tspath.RootedDirectoryPath) tspath.RootedDirectoryPath {
	if baseDir == "" {
		baseDir = defaultRootDir
	}
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || trimmed == "." {
		return baseDir
	}
	if trimmed == "/" {
		return defaultRootDir
	}
	if strings.ContainsAny(trimmed, "?#") {
		return baseDir
	}
	return tspath.ToRootedDirectoryPath(strings.Clone(trimmed), baseDir)
}

// memFS implements `vfs.FS` completely in WASM linear memory with zero host disk access.
type memFS struct {
	mu              sync.RWMutex
	caseSensitivity tspath.CaseSensitivity
	files           map[string]*memFile
	dirs            map[string]*memDir
}

type memFile struct {
	path    tspath.RootedFilePath
	content string
	modTime time.Time
}

type memDir struct {
	path  tspath.RootedDirectoryPath
	files map[string]string
	dirs  map[string]string
}

var _ vfs.FS = (*memFS)(nil)

func newMemFS(caseSensitivity tspath.CaseSensitivity) *memFS {
	m := &memFS{
		caseSensitivity: caseSensitivity,
		files:           map[string]*memFile{},
		dirs:            map[string]*memDir{},
	}
	m.ensureDir(defaultRootDir)
	return m
}

func (m *memFS) clear() {
	m.mu.Lock()
	defer m.mu.Unlock()
	clear(m.files)
	clear(m.dirs)
}

func (m *memFS) key(path string) string {
	return m.caseSensitivity.Canonicalize(path)
}

func (m *memFS) ensureDir(path tspath.RootedDirectoryPath) *memDir {
	if dir := m.dirs[m.key(path.AsString())]; dir != nil {
		return dir
	}
	dir := &memDir{
		path:  path,
		files: map[string]string{},
		dirs:  map[string]string{},
	}
	m.dirs[m.key(path.AsString())] = dir
	if parent := path.AsPath().Directory(); parent != path {
		name := path.BaseName()
		m.ensureDir(parent).dirs[m.key(name)] = name
	}
	return dir
}

func (m *memFS) CaseSensitivity() tspath.CaseSensitivity {
	return m.caseSensitivity
}

func (m *memFS) FileExists(path tspath.RootedFilePath) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.files[m.key(path.AsString())] != nil
}

func (m *memFS) DirectoryExists(path tspath.RootedDirectoryPath) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.dirs[m.key(path.AsString())] != nil
}

func (m *memFS) ReadFile(path tspath.RootedFilePath) (string, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if file := m.files[m.key(path.AsString())]; file != nil {
		return file.content, true
	}
	return "", false
}

func (m *memFS) WriteFile(path tspath.RootedFilePath, data string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.writeFileLocked(path, data)
}

func (m *memFS) AppendFile(path tspath.RootedFilePath, data string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if file := m.files[m.key(path.AsString())]; file != nil {
		data = file.content + data
	}
	return m.writeFileLocked(path, data)
}

func (m *memFS) writeFileLocked(path tspath.RootedFilePath, data string) error {
	key := m.key(path.AsString())
	if m.dirs[key] != nil {
		return &fs.PathError{Op: "write", Path: path.AsString(), Err: fs.ErrInvalid}
	}
	now := time.Unix(0, 0)
	if file := m.files[key]; file != nil {
		file.content = data
		file.modTime = now
		return nil
	}
	for dir := path.Directory(); m.dirs[m.key(dir.AsString())] == nil; {
		if m.files[m.key(dir.AsString())] != nil {
			return &fs.PathError{Op: "write", Path: path.AsString(), Err: fs.ErrInvalid}
		}
		parent := dir.AsPath().Directory()
		if parent == dir {
			break
		}
		dir = parent
	}
	name := path.BaseName()
	m.ensureDir(path.Directory()).files[m.key(name)] = name
	m.files[key] = &memFile{path: path, content: data, modTime: now}
	return nil
}

func (m *memFS) deleteFile(path tspath.RootedFilePath) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := m.key(path.AsString())
	file := m.files[key]
	if file == nil {
		return false
	}
	delete(m.files, key)
	m.removeFromParentLocked(file.path.AsPath())
	return true
}

func (m *memFS) listFilesUnder(dir tspath.RootedDirectoryPath) []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	dirStr := dir.AsString()
	prefix := dirStr
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	out := make([]string, 0, len(m.files))
	for _, file := range m.files {
		p := file.path.AsString()
		if dirStr == "/" || strings.HasPrefix(p, prefix) {
			out = append(out, p)
		}
	}
	slices.Sort(out)
	return out
}

func (m *memFS) Remove(path tspath.RootedPath) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := m.key(path.AsString())
	if file := m.files[key]; file != nil {
		delete(m.files, key)
		m.removeFromParentLocked(file.path.AsPath())
	} else if dir := m.dirs[key]; dir != nil {
		m.removeDirLocked(dir)
		if dir.path.AsPath().Directory() != dir.path {
			m.removeFromParentLocked(dir.path.AsPath())
		}
	}
	return nil
}

func (m *memFS) removeFromParentLocked(path tspath.RootedPath) {
	name := m.key(path.BaseName())
	parent := m.dirs[m.key(path.Directory().AsString())]
	if parent != nil {
		delete(parent.files, name)
		delete(parent.dirs, name)
	}
}

func (m *memFS) removeDirLocked(dir *memDir) {
	if dir == nil {
		return
	}
	for _, name := range dir.files {
		delete(m.files, m.key(dir.path.ResolveFile(name).AsString()))
	}
	for _, name := range dir.dirs {
		m.removeDirLocked(m.dirs[m.key(dir.path.ResolveDirectory(name).AsString())])
	}
	delete(m.dirs, m.key(dir.path.AsString()))
}

func (m *memFS) Chtimes(path tspath.RootedPath, _ time.Time, mTime time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if file := m.files[m.key(path.AsString())]; file != nil {
		file.modTime = mTime
		return nil
	}
	if m.dirs[m.key(path.AsString())] != nil {
		return nil
	}
	return &fs.PathError{Op: "chtimes", Path: path.AsString(), Err: fs.ErrNotExist}
}

func (m *memFS) GetAccessibleEntries(path tspath.RootedDirectoryPath) vfs.Entries {
	m.mu.RLock()
	defer m.mu.RUnlock()
	entries := vfs.Entries{Symlinks: map[string]struct{}{}}
	if dir := m.dirs[m.key(path.AsString())]; dir != nil {
		entries.Files = slices.Sorted(maps.Values(dir.files))
		entries.Directories = slices.Sorted(maps.Values(dir.dirs))
	}
	return entries
}

func (m *memFS) Stat(path tspath.RootedPath) vfs.FileInfo {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if file := m.files[m.key(path.AsString())]; file != nil {
		return &memFileInfo{name: file.path.BaseName(), size: int64(len(file.content)), modTime: file.modTime}
	}
	if dir := m.dirs[m.key(path.AsString())] != nil; dir {
		d := m.dirs[m.key(path.AsString())]
		return &memFileInfo{name: d.path.BaseName(), mode: fs.ModeDir}
	}
	return nil
}

func (m *memFS) Realpath(path tspath.RootedPath) tspath.RootedPath {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if file := m.files[m.key(path.AsString())]; file != nil {
		return file.path.AsPath()
	}
	if dir := m.dirs[m.key(path.AsString())]; dir != nil {
		return dir.path.AsPath()
	}
	return path
}

type memFileInfo struct {
	name    string
	size    int64
	mode    fs.FileMode
	modTime time.Time
}

func (i *memFileInfo) Name() string       { return i.name }
func (i *memFileInfo) Size() int64        { return i.size }
func (i *memFileInfo) Mode() fs.FileMode  { return i.mode }
func (i *memFileInfo) ModTime() time.Time { return i.modTime }
func (i *memFileInfo) IsDir() bool        { return i.mode.IsDir() }
func (i *memFileInfo) Sys() any           { return nil }
