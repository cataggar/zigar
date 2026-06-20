# zigar-compiler

![Logo](https://github.com/chung-leong/zigar/blob/main/logo.png?raw=true)

Backend component usedby node-zigar, rollup-plugin-zigar, and zigar. It handles the compilation
process.

Consult [the project wiki](https://github.com/chung-leong/zigar/wiki) for more details.

## Importing C code (Zig 0.17+)

Zig 0.17 removed the `@cImport` builtin; C translation now happens through the build
system. zigar bridges this with a simple convention: if a C header named
`<source>.cimport.h` (or `cimport.h`) sits next to your module's source file, zigar
runs `b.addTranslateC` on it and exposes the result to your module under the import
name `c`.

So instead of:

```zig
const c = @cImport({
    @cInclude("stdio.h");
});
pub const printf = c.printf;
```

create a header next to the module (e.g. `main.cimport.h` for `main.zig`):

```c
#include <stdio.h>
```

and import it in Zig:

```zig
const c = @import("c");
pub const printf = c.printf;
```

`#define`s and additional `#include`s (including local `.c` files, resolved relative
to the module directory) go in the header. The translate-c module follows the
module's target, optimize, and libc settings.

