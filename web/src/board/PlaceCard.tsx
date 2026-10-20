/* ════════════════════════════════════════════════════════════════════════════
 * w_creators · board/PlaceCard.tsx - the selected place's card
 *
 *   its name, id and state (on / off, usable now)
 *   the fields       name · town · NPC model (◀ the suggestions ▶ and a box to type another) · radius ·
 *                    store / pricing profile (clothing) · on / off · blip       -> «حفظ» on the strip (op save)
 *   its spots        the NPC, the editing spot, the catalogue book (clothing), the chair (barber): where each one
 *                    stands, a button that places it in the world (op place: Lua hides the board, runs the world
 *                    editor, then sends the board again) and «إزالة» (op clear) when it is set
 * Stops: f:label f:town f:npc f:npcText f:radius f:store f:pricing f:enabled f:blip · sp:<what>:place|pick|clear
 * ════════════════════════════════════════════════════════════════════════════ */

import { useState } from 'react';
import type { Nav } from './cursor';
import { Btn, Field, NumField, Stepper, Switch, type Message } from './fields';
import { cls, Txt, useI18n } from './i18n';
import { GlyphAim, GlyphCross, GlyphPin } from './icons';
import {
  fmtSpot, labelOk, LABEL_MAX, MODEL_MAX, modelOk, radiusOk, SPOTS, townOk, TOWN_MAX, withValue,
  type BoardData, type Form, type Place, type SpotKind,
} from './model';

/** op place's `what`: a spot, or `pickChair` (aim at a chair already in the map) */
export type PlaceWhat = SpotKind | 'pickChair';

const PLACE_LABEL: Record<SpotKind, string> = {
  npc: 'btn.placeNpc',
  preview: 'btn.placePreview',
  book: 'btn.placeBook',
  chair: 'btn.placeChair',
};

interface Props {
  place: Place;
  form: Form;
  board: BoardData;
  nav: Nav;
  busy: boolean;
  patch: (p: Partial<Form>) => void;
  /** `model`: the prop for a new chair (one of board.chairModels) */
  onPlace: (what: PlaceWhat, model?: string) => void;
  onClear: (what: SpotKind) => void;
}

export default function PlaceCard({ place, form, board, nav, busy, patch, onPlace, onClear }: Props) {
  const { t } = useI18n();
  const bad = (show: boolean): Message | undefined => (show ? { text: t('err.invalid'), level: 'error' } : undefined);
  const clothing = place.type === 'clothing';

  const npcOptions = withValue(board.npcModels[place.type], form.npcModel).map((m) => ({ value: m, label: m }));
  // a profile left empty (the store's default) stays choosable as «-» beside the named ones
  const profile = (list: string[], value: string) => {
    const opts = withValue(list, value).map((v) => ({ value: v, label: v }));
    return value.trim() === '' || opts.length === 0 ? [{ value: '', label: '-' }, ...opts] : opts;
  };
  const storeOptions = profile(board.profiles.store, form.storeProfile);
  const pricingOptions = profile(board.profiles.pricing, form.pricingProfile);
  const [chairModel, setChairModel] = useState(board.chairModels[0] ?? '');
  const chairOptions = board.chairModels.map((m) => ({ value: m, label: m }));

  const spotLine = (w: SpotKind) => {
    const s = place[w];
    // the NPC's model; a chair: its prop's name, or «كرسي من الماب» for one picked from the map (a hash)
    const model = w === 'npc' ? place.npcModel || place.npc?.model
      : w === 'chair' && place.chair ? (place.chair.kind === 'prop' ? place.chair.model : t('spot.chairWorld')) : '';
    return (
      <div key={w} className="wcb-spot">
        <div className="wcb-spot-head">
          <span className="wcb-spot-name">{t(`spot.${w}`)}</span>
          <span className={cls('wcb-spot-at', !s && 'is-empty')}>
            {s ? <bdi dir="ltr" className="wf-num">{fmtSpot(s)}</bdi> : t('spot.none')}
          </span>
        </div>
        {s && model ? <div className={cls('wcb-spot-model', w === 'chair' && place.chair?.kind === 'world' && 'is-words')}>{model}</div> : null}
        {w === 'chair' && chairOptions.length > 0 && (
          <div className="wf-grid wcb-spot-pick">
            <Stepper id="sp:chair:model" nav={nav} label={t('field.chairModel')} latin options={chairOptions} value={chairModel}
              locked={chairOptions.length < 2} onChange={setChairModel} />
          </div>
        )}
        <div className="wf-btns">
          <Btn id={`sp:${w}:place`} nav={nav} icon={<GlyphPin />} label={t(PLACE_LABEL[w])} disabled={busy}
            onClick={() => onPlace(w, w === 'chair' ? chairModel : undefined)} />
          {w === 'chair' && (
            <Btn id="sp:chair:pick" nav={nav} icon={<GlyphAim />} label={t('btn.pickChair')} disabled={busy}
              onClick={() => onPlace('pickChair')} />
          )}
          {s && (
            <Btn id={`sp:${w}:clear`} nav={nav} quiet icon={<GlyphCross />} label={t('btn.clear')} disabled={busy}
              onClick={() => onClear(w)} />
          )}
        </div>
      </div>
    );
  };

  return (
    <>
      <div className="wf-card-head">
        <div style={{ minWidth: 0 }}>
          <div className="wcb-title">
            <span className="wcb-title-name"><Txt s={form.label.trim() || place.label || place.id} /></span>
            <span className={cls('wf-tag', place.enabled && 'is-solid')}>{t(place.enabled ? 'state.on' : 'state.off')}</span>
            {place.usable && <span className="wf-tag">{t('state.usable')}</span>}
          </div>
          <div className="wcb-id">{place.id}</div>
        </div>
      </div>

      <div className="wf-page is-scroll">
        <div className="wf-sec">{t('sec.details')}</div>
        <div className="wf-grid">
          <Field id="f:label" nav={nav} label={t('field.label')} value={form.label} maxLength={LABEL_MAX}
            onChange={(v) => patch({ label: v })} msg={bad(!labelOk(form.label))} />
          <Field id="f:town" nav={nav} label={t('field.town')} value={form.town} maxLength={TOWN_MAX}
            onChange={(v) => patch({ town: v })} msg={bad(!townOk(form.town))} />
          <Stepper id="f:npc" nav={nav} label={t('field.npcModel')} latin options={npcOptions} value={form.npcModel}
            locked={npcOptions.length < 2} onChange={(v) => patch({ npcModel: v })} />
          <Field id="f:npcText" nav={nav} label={t('field.npcModelText')} latin value={form.npcModel} maxLength={MODEL_MAX}
            onChange={(v) => patch({ npcModel: v.trim() })} msg={bad(!modelOk(form.npcModel))} />
          <NumField id="f:radius" nav={nav} label={t('field.radius')} value={form.radius}
            onChange={(n) => patch({ radius: n })} msg={bad(!radiusOk(form.radius))} />
          {clothing && (
            <Stepper id="f:store" nav={nav} label={t('field.storeProfile')} latin options={storeOptions} value={form.storeProfile}
              locked={storeOptions.length < 2} onChange={(v) => patch({ storeProfile: v })} />
          )}
          {clothing && (
            <Stepper id="f:pricing" nav={nav} label={t('field.pricingProfile')} latin options={pricingOptions} value={form.pricingProfile}
              locked={pricingOptions.length < 2} onChange={(v) => patch({ pricingProfile: v })} />
          )}
        </div>
        <div className="wf-switches">
          <Switch id="f:enabled" nav={nav} label={t('field.enabled')} on={form.enabled} onToggle={() => patch({ enabled: !form.enabled })} />
          <Switch id="f:blip" nav={nav} label={t('field.blip')} on={form.blip} onToggle={() => patch({ blip: !form.blip })} />
        </div>

        <div className="wf-sec">{t('sec.spots')}</div>
        <div className="wcb-spots">{SPOTS[place.type].map(spotLine)}</div>
        <p className="wf-note-line is-tight">{t('hint.place')}</p>
      </div>
    </>
  );
}
