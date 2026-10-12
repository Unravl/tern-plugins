# tern-plugins

Plugins and tweaks for [Tern](https://docs.stencil.so/tern/). Each folder is one plugin, named by its plugin id.

| Plugin | What it does |
| --- | --- |
| [`sessions-sidebar`](sessions-sidebar/README.md) | Left sidebar listing sessions per host, with icons, renaming, paths, activity strips, omp agent markers (question asked, task finished), collapsible and reorderable hosts and sessions, custom host title colors, a per-host new-session button, and docked, click-tab or hover display |

## Install a plugin

```sh
tern plugin install github.com/Unravl/tern-plugins/<plugin-id>
```

The repository is private, so this needs access to it. Without access, copy or unzip the plugin folder and run `tern plugin install <path-to-folder>`. Use `--force` to update and `tern plugin remove <plugin-id>` to uninstall.

## Develop

Link a plugin so Tern runs it from this folder, then reload after edits:

```sh
tern plugin link ~/Documents/tern-plugins/<plugin-id>
tern plugin reload
```

Agent instructions, including the automatic commit-and-push rule, are in [AGENTS.md](AGENTS.md).
