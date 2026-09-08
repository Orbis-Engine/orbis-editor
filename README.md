# orbis-editor

The [Orbis](https://github.com/Orbis-Engine/orbis) editor.

```sh
flutter run -d macos
```

Opens a launcher rather than an empty editor, because an editor with no project
has nothing honest to show — every panel would be an empty state, and a screen
full of empty states is worse than a screen that asks one question.

## What works

- **Launcher** — recent projects with paths and when they were last opened, a
  project whose folder has moved marked rather than hidden, and opening a
  folder that already holds a project.
- **New project** — name, location, and a template, with the folder path shown
  before it is created so nobody is surprised by where their project went.
- **Editor shell** — outliner, viewport region, inspector and status bar, with
  the transport where every editor puts it.

The viewport is marked unfinished rather than dressed up. It becomes real when
the renderer can load a scene.

## Design

One accent, spent deliberately. Everything merely present is grey; the ember is
reserved for what is selected, what is primary, and what is being edited right
now — an interface where everything is highlighted has highlighted nothing.
Spacing is on a four-point scale, because editors go wrong when each panel picks
its own padding.

`lib/src/theme/orbis_theme.dart` is the whole system.

## Licence

MIT, © 2026 Chris Beckett. The editor links the renderer, so builds carry Filament's
Apache 2.0 licence too — see [LICENSE](LICENSE).
