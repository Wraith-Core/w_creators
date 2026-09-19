# Appearance editor contract

Lua owns the appearance state. `web/src/Editor.jsx` is shared by creator/store/wardrobe/barber. Language is supplied by w_lib through `UiLocale()`; the page never chooses an independent language.

## Lua → React

- `editor`: `{ id, mode, locale, title, app, categories, features, overlays, price, growth }`. A new id resets the form. The same id updates its snapshot without losing typed identity.
- `editorClose`: remove the editor.
- `charCard`: `{ show, name, job, cash, bank, gold, locale, strings }`, selection display only.
- `setLocale` / `receivedata`: selection-card locale and labels.

## React → Lua

`editor:action` always returns JSON: `{ok, payload? , closed?, error?}`. Its `id` is the session id. Only one mutation may be in flight.

- component: `{action:'component',category,model,variant}`; validated against w_lib; core body parts cannot be removed.
- feature: `{action:'feature',field,value}`; field references data/features.lua, range −1..1.
- body: `{action:'body',field:'scale'|'waist',value}`.
- overlay: `{action:'overlay',category,model,color,opacity}`; model 0 disables a layer.
- random / undo / reset: one acknowledged mutation; no parallel fire-and-forget edits.
- save: `{action:'save',identity:{firstname,lastname,age}}`; identity is only used by creator mode. Prices and permitted categories are server-owned.
- cancel: restore the opening snapshot, release focus/camera, return from the fitting room.

`editor:camera`: `{part:'default'|'head'|'eyes'|'body'|'pant'|'boot'}` or `{rotate:degrees}` or `{zoom:delta}`; always acknowledged.

The old component/overlay/CharacterCreation.Done/storeOpen callbacks and the duplicate menu hierarchy are retired. No NUI path may bypass the session to purchase or persist an appearance.

## Persistence

`characters_appearence.components` contains stable category hashes, `__version=2`, `__scale`, `__waist`, `__expressions`, and server-owned `__grooming`. Existing JSON arrays remain readable. The server ignores submitted growth clocks, prices and face changes in store/barber modes. Appearance and ownership writes share one database transaction; the framework currency charge has a compensating refund on database failure.
