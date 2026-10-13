# Spine Composer Fix

Keeps the omp composer bar one even band across the pane in Tern's **Spine** chat style when macOS **Reduce transparency** is on.

## The problem

With System Settings › Accessibility › Display › **Reduce transparency** on, Tern 0.8.3 gives every omp composer editor an opaque fill (`--pop-bg`, `!important`). That suits the **Reader** style, which draws the editor as a card. **Spine** instead draws a full-width composer band and clears the editor's own background, so the fill leaves a lighter, narrower box (840 px at most, centered) inside the band: the bar's background looks like it stops short of the pane edges.

## The fix

One stylesheet (installed by `window.luau` as `plugin:local:spine-composer-fix:spine-editor`) clears the editor fill, only for Spine and only under `prefers-reduced-transparency: reduce`. Reader and Console keep Tern's styling, and nothing changes when Reduce transparency is off.

## Install

```sh
tern plugin link ~/Documents/tern-plugins/spine-composer-fix
```

or `tern plugin install github.com/Unravl/tern-plugins/spine-composer-fix`.

## Limits

- Targets Tern's internal surface classes (`.sf-chat-spine`, `data-role^='omp.editor'`), not a documented SDK hook. A later Tern that renames them or fixes the bug makes this plugin a no-op; remove it then.
- The band itself stays Tern's slightly translucent Spine tint.

## Verification

Isolated native **Tern 0.8.3** window, Studio layout, Solid material, `dark-abyss` theme, Reduce transparency on, omp 18.8.5, `sessions-sidebar` docked: the Spine editor's computed background went from `rgb(35, 35, 39)` to `rgba(0, 0, 0, 0)` with the plugin, while Reader kept `rgb(35, 35, 39)`. `tests/spine-editor.txt` sets up that state; its header gives the `dump` check.
