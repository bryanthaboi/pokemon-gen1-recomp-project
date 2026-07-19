# Native modding

The modding book lives on the
[project wiki](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki).

- [Getting started](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki/Getting-Started)
  — install a mod, write a first one, enable and disable it.
- [Tutorials](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki/Tutorials)
  — twelve dependency-ordered rungs, each a runnable mod.
- [Cookbook](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki/Cookbook)
  — task-sized recipes.
- [Registry reference](https://github.com/bryanthaboi/pokemon-gen1-recomp-project/wiki/Reference-Registries)
  — every registry, generated from `src/mods/Schemas.lua`.

Regenerate the reference straight into a wiki checkout:

```sh
luajit tools/gen_registry_docs.lua ../pokemon-gen1-recomp-project.wiki
```
