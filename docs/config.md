# Config

`zl` ships with built-in icons and colors. If those aren't your vibe, drop your own in a `.zon` file:

```bash
zl -C zlist.zon
```

Leave a field out and the built-in value sticks. `by_ext` only overrides that extension — the rest of the map stays put.

```zon
.{
    .icons = .{
        .dir = " ",
        .file = " ",
        .symlink = " ",
        .by_ext = .{
            .{ .ext = ".zig", .icon = " " },
        },
    },
    .colors = .{
        .dir = "bright_blue",
        .file = "bright_yellow",
        .symlink = "cyan",
        .by_ext = .{
            .{ .ext = ".md", .color = "bright_magenta" },
        },
    },
}
```

Color names are the usual terminal ones: `bright_blue`, `bright_green`, `red`, and so on.
