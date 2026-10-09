# zlist Examples

Common `zl` examples for listing, sorting, filtering, and long-view output.

## Basic Listing

**Standard list:**
```bash
zl
```

**Show all files with details, sorted by filename length:**
```bash
zl -la -s length
```

**Clean output without colors or icons:**
```bash
zl -p
```

**One name per line, handy for pipes:**
```bash
zl -1
zl -1p
```

## Long View

**Show the long view:**
```bash
zl -l
zl --long
```

**Hide permissions from the long view:**
```bash
zl -l --no-permissions
```

**Hide user from the long view:**
```bash
zl -l --no-user
```

**Hide group from the long view:**
```bash
zl -l --no-group
```

**Hide size from the long view:**
```bash
zl -l --no-size
```

**Hide time from the long view:**
```bash
zl -l --no-time
```

**Hide icon from the long view:**
```bash
zl -l --no-icon
```

**Show recursive directory sizes in long view:**
```bash
zl -l --du
```

**Sort by recursive directory size:**
```bash
zl --du -s size -l
```

## Recursive Listing

**Basic recursive listing with infinite depth:**
```bash
zl -r
```

**Limit recursion to 2 levels deep:**
```bash
zl -L 2
```

## Filtering

**Filter by file type:**
```bash
zl -d
zl -D
```

**Exclude some extensions:**
```bash
zl --ext zig,go,ts
```

**Match by name:**
```bash
zl --match test
```

**Filter files by size:**
```bash
zl --size lt:10K
zl --size gt:10K --size lte:2M
```

**Show files changed recently:**
```bash
zl --changed-within 7d
```

## Reports and Git

**Show summary report:**
```bash
zl -R
```

**Show Git status, which must be used with long view:**
```bash
zl -lg
```
