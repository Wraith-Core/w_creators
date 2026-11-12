import React,{useEffect,useRef,useState} from 'react';
import {Glyph,Choice} from './Chrome';
import FeaturePad from './FeaturePad';
import DateField from './DateField';
import {TINT_MAX,choiceOptions,formatDisplay,formatMoney,hasArabic,identityName,isNavigable,reviewItems,rowValue,segments,skipValue,stripFraction,stripWindow,textBlocked,trackPath} from './treeState';

// The generic renderer of one node of the Lua tree (§8.2), built from the original components:
// MenuRow, Choice, Slider, FeaturePad and the wst-plate panels. Every text comes from the node or
// from payload.strings; nothing here is hardcoded copy.

// A palette strip (node.track): loaded once per path. `url` is absolute (a relative url() inside a
// CSS variable does not resolve in CEF, see main.jsx); `at(f)` reads the colour at 0..1 along the
// strip, or null when the image cannot be read. A strip that does not load leaves the plain track.
const strips=new Map();
function useStrip(path){
  const [strip,setStrip]=useState(()=>strips.get(path)||null);
  useEffect(()=>{
    if(!path){setStrip(null);return undefined;}
    if(strips.has(path)){setStrip(strips.get(path));return undefined;}
    let live=true;
    const url=new URL(path,document.baseURI).href;
    const img=new Image();
    img.onload=()=>{
      let pixels=null;
      try{
        const c=document.createElement('canvas');c.width=img.naturalWidth;c.height=1;
        const g=c.getContext('2d');g.drawImage(img,0,Math.floor(img.naturalHeight/2),img.naturalWidth,1,0,0,img.naturalWidth,1);
        pixels=g.getImageData(0,0,img.naturalWidth,1).data;
      }catch{pixels=null;}
      const s={url,at:f=>{
        if(!pixels)return null;
        const x=Math.min(img.naturalWidth-1,Math.max(0,Math.floor(f*img.naturalWidth)))*4;
        return `rgb(${pixels[x]},${pixels[x+1]},${pixels[x+2]})`;
      }};
      strips.set(path,s);if(live)setStrip(s);
    };
    img.onerror=()=>{strips.set(path,null);if(live)setStrip(null);};
    img.src=url;
    return ()=>{live=false;};
  },[path]);
  return strip;
}

export function Slider({node,disabled,onChange,onPreview}) {
  const min=Number(node.min??0),max=Number(node.max??1),step=Number(node.step)||.01;
  const display=node.display||{scale:1,decimals:step<1?2:0};
  const value=Number(node.value)||0;
  const [draft,setDraft]=useState(value);
  const off=disabled||node.disabled;
  // a tint slider carries its palette's strip (the colours it picks from) and the indices to skip
  const strip=useStrip(trackPath(node.track));
  const skip=Array.isArray(node.skip)&&node.skip.length?node.skip:null;
  // resync when the value changes AND when a request settles (disabled drops): a refused set
  // (ok=false, same value back) must not keep showing the refused draft (as FeaturePad does)
  useEffect(()=>{if(!off)setDraft(value);},[value,off]);
  // every move previews on the ped; the release commits once (one undo step). A drag that ends on
  // the value it started from sends preview(null): the working look comes back.
  const previewed=useRef(false),previewRef=useRef(onPreview);previewRef.current=onPreview;
  // unmounted mid-drag (Escape pops the view): the working look comes back, nothing is left previewed
  useEffect(()=>()=>{if(previewed.current&&previewRef.current)previewRef.current(null);},[]);
  const change=e=>{
    const v=skip?skipValue(e.target.value,draft,skip,min,max):e.target.value;
    setDraft(v);if(onPreview){previewed.current=true;onPreview(Number(v));}
  };
  const commit=()=>{
    if(Number(draft)!==value)onChange(Number(draft));
    else if(previewed.current&&onPreview)onPreview(null);
    previewed.current=false;
  };
  // the strip holds the whole palette (tint 0 .. TINT_MAX): the chip reads the tint's own cell, and a
  // slider narrowed by the palette's limits shows only its min..max part of the strip
  const chip=strip?strip.at(stripFraction(draft,0,TINT_MAX)):null;
  const style={'--range-fill':`${(Number(draft)-min)/((max-min)||1)*100}%`};
  if(strip){
    const view=stripWindow(min,max);
    style['--range-image']=`url("${strip.url}")`;
    style['--range-size']=`${view.size}%`;style['--range-pos']=`${view.position}%`;
  }
  return <label className={'slider-field'+(strip?' has-strip':'')} data-off={off?'true':undefined}><span>{node.label}{chip&&<i className="choice-swatch" aria-hidden="true" style={{'--swatch':chip}}/>}<output>{formatDisplay(draft,display)}</output></span>
    <span className="range-track" style={style}>
      <input aria-label={node.label} type="range" min={min} max={max} step={step} value={draft} disabled={off} onChange={change} onPointerUp={commit} onKeyUp={commit} onBlur={commit}/>
    </span>
    {/* the words at the two ends (low on the left, as the track runs): «خفيف / كثيف», «قصير / طويل» */}
    {Array.isArray(node.ends)&&node.ends.length===2&&<span className="slider-ends" dir="ltr" aria-hidden="true"><span>{node.ends[0]}</span><span>{node.ends[1]}</span></span>}
  </label>;
}

// badge: the node's state word (owned / equipped / locked / new) when the value slot shows it; it
// only adds data-badge, so a plain price stays <span class="row-value">$3.50</span>.
export function MenuRow({id,label,value,badge,art,icon,onClick,disabled=false,action=false}) {
  return <button type="button" className={'wst-card menu-row'+(icon?' has-icon':'')} data-navkey={id} disabled={disabled} onClick={onClick}>
    {icon?<span aria-hidden="true" className="row-icon" style={{'--row-icon':`var(--cloth-${icon})`}}/>:art&&<Glyph tex={art} className="row-art"/>}<span className="row-label">{label}</span>
    {value!=null&&value!==''&&<span className="row-value" data-badge={badge||undefined}>{value}</span>}{!action&&<Glyph tex="selection_arrow_right" className="row-arrow"/>}
  </button>;
}

// A text field and its own action button: the typed value travels with the invoke (node.required:
// nothing to send while empty; node.clear: the field empties once the invoke succeeded).
export function TextNode({node,disabled,onInvoke}) {
  const [draft,setDraft]=useState(node.value||'');
  useEffect(()=>setDraft(node.value||''),[node.value]);
  const off=disabled||node.disabled;
  const blocked=off||textBlocked(node,draft);
  const submit=async()=>{
    if(blocked)return;
    const ok=await onInvoke(node.control,draft);
    if(ok&&node.clear)setDraft('');
  };
  return <div className="identity">
    <label>{node.label}<span className="wst-field input-plate"><input className="wst-input" autoComplete="off" maxLength={node.maxLength||undefined} placeholder={node.placeholder||undefined} disabled={off} value={draft}
      onChange={e=>setDraft(e.target.value)} onKeyDown={e=>{if(e.key==='Enter'){e.preventDefault();submit();}}}/></span></label>
    {node.actionLabel&&<button type="button" className="wst-button" disabled={blocked} onClick={submit}>{node.actionLabel}</button>}
    {node.reason&&<p className="menu-help">{node.reason}</p>}
  </div>;
}

// sign: the creator's Review card repeats the typed name as a handwritten signature under the rows
function Plate({title,hint,items,className='',sign}) {
  return <aside className={'wst-plate growth '+className}><strong>{title}</strong>
    {hint&&<p className="plate-hint">{hint}</p>}
    {(items||[]).map((item,i)=><p key={i}>{item.label}<span>{item.value}</span></p>)}
    {sign&&<p className={'review-sign'+(hasArabic(sign)?' is-ar':'')}><bdi>{sign}</bdi></p>}
  </aside>;
}

function ItemCard({node,strings}) {
  const item=node.item||{};
  const items=[];
  // the price in the store's chosen currency (Lua formats it: '$5.00' or '0.25 gold')
  if(item.price!=null)items.push({label:strings.price||'',value:item.priceLabel||formatMoney(item.price,item.currency,strings)});
  if(item.owned||item.equipped)items.push({label:(item.equipped?strings.equipped:strings.owned)||'',value:''});
  if(item.variants)items.push({label:strings.variants||'',value:String(item.variants)});
  // the colours the character owns of it (colourways)
  if(item.colors)items.push({label:strings.ownedColors||'',value:String(item.colors)});
  return <Plate className="item-card" title={item.name||node.label} items={items}/>;
}

// ★ `errors` is { firstname: 'INVALID_NAME', ... } from Lua (E.identityCheck), never a second copy
//   of the rules in JavaScript — the two could not be kept in step. A field is marked only once it
//   has something in it: an untouched field is missing, not wrong.
//   A date field is DateField (day · month · year, never the browser's date input); an info field (the
//   sex chosen on the stage, a locked repair identity) is a line to read, not an input: with
//   f.choices it is the two-way switch with the chosen side on the paper band. f.hint: a line under it.
export function IdentityForm({identity,form,onChange,disabled,errors,strings}) {
  const S=strings||{};
  return <div className="identity">
    {(identity?.fields||[]).map(f=>{
      const bad=f.type!=='info'&&errors&&errors[f.key]&&errors[f.key]!=='OK'?errors[f.key]:null;
      const error=bad&&<em className="identity-error" id={`identity-err-${f.key}`}>{S[bad]||S.identityInvalid||bad}</em>;
      const hint=f.hint&&<small className="identity-hint">{f.hint}</small>;
      if(f.type==='info'){
        const choices=Array.isArray(f.choices)&&f.choices.length>1&&f.choices.includes(f.value)?f.choices:null;
        return <div key={f.key} className="identity-info"><span className="identity-label" id={`identity-label-${f.key}`}>{f.label}</span>
          {choices
            ?<span className="identity-switch" role="radiogroup" aria-readonly="true" aria-labelledby={`identity-label-${f.key}`}>{choices.map(c=>
              <span key={c} role="radio" aria-checked={c===f.value} className={'identity-choice'+(c===f.value?' is-on':'')}>{c}</span>)}</span>
            :<span className={'identity-static'+(f.key==='dob'?' is-fig':'')}>{f.value||''}</span>}
          {hint}</div>;
      }
      if(f.type==='date')return <div key={f.key} className={'identity-date'+(bad?' is-invalid':'')}>
        <span className="identity-label" id={`identity-label-${f.key}`}>{f.label}</span>
        <DateField field={f} value={form?.[f.key]||''} disabled={disabled} strings={S} labelledBy={`identity-label-${f.key}`}
          invalid={!!bad} describedBy={bad?`identity-err-${f.key}`:undefined} onChange={v=>onChange({...form,[f.key]:v})}/>
        {error}{hint}</div>;
      return <label key={f.key} className={bad?'is-invalid':undefined}>{f.label}<span className="wst-field input-plate">
        <input className="wst-input" required autoComplete="off" disabled={disabled} type="text" maxLength={f.maxLength||undefined}
          aria-invalid={bad?'true':undefined} aria-describedby={bad?`identity-err-${f.key}`:undefined}
          value={form?.[f.key]||''} onChange={e=>onChange({...form,[f.key]:e.target.value})}/>
      </span>{error}{hint}</label>;
    })}
  </div>;
}

function Control({node,strings,disabled,handlers}) {
  if(node.kind==='slider')return <Slider node={node} disabled={disabled} onChange={v=>handlers.set(node.control,v)} onPreview={v=>handlers.preview&&handlers.preview(v==null?null:{[node.control]:v})}/>;
  const options=choiceOptions(node,strings);
  return <Choice caption={node.label} label={node.label} value={node.value} options={options} disabled={disabled||node.disabled||options.length===0} onChange={v=>handlers.set(node.control,v)}/>;
}

// The children of a group (already filtered by search) in their render segments.
export function GroupBody({nodes,strings,disabled,handlers}) {
  return segments(nodes).map((seg,i)=>{
    if(seg.type==='rows')return <nav key={i} className="menu-list">{seg.nodes.map(n=>n.kind==='action'
      ?<React.Fragment key={n.id}><MenuRow id={n.id} label={n.label} action disabled={disabled||!!n.disabled} value={n.summary} onClick={()=>(n.danger&&handlers.confirm?handlers.confirm(n):handlers.invoke(n.control))}/>{n.disabled&&n.reason&&<p className="menu-help">{n.reason}</p>}</React.Fragment>
      :<MenuRow key={n.id} id={n.id} label={n.label} art={n.art} icon={n.icon} value={rowValue(n,strings)} badge={n.badge&&(n.badgeLabel||strings[n.badge])?n.badge:undefined} disabled={!!n.disabled} onClick={()=>handlers.open(n)}/>)}</nav>;
    if(seg.type==='controls')return <article key={i} className="component">{seg.nodes.map(n=><Control key={n.id} node={n} strings={strings} disabled={disabled} handlers={handlers}/>)}</article>;
    if(seg.type==='pads')return <React.Fragment key={i}>{seg.nodes.map(n=><FeaturePad key={n.id} node={n} text={strings} disabled={disabled||!!n.disabled} onChange={values=>handlers.setMany(values)} onPreview={values=>handlers.preview&&handlers.preview(values)}/>)}</React.Fragment>;
    if(seg.type==='extra')return <details key={i} className="feature-extra"><summary>{strings.advanced}</summary>{seg.nodes.map(n=><Slider key={n.id} node={n} disabled={disabled} onChange={v=>handlers.set(n.control,v)} onPreview={v=>handlers.preview&&handlers.preview(v==null?null:{[n.control]:v})}/>)}</details>;
    const n=seg.nodes[0];
    if(n.kind==='text')return <TextNode key={n.id} node={n} disabled={disabled} onInvoke={handlers.invoke}/>;
    if(n.kind==='itemcard')return <ItemCard key={n.id} node={n} strings={strings}/>;
    if(n.kind==='info'||n.kind==='review')return <Plate key={n.id} title={n.label} hint={n.hint} items={n.items}/>;
    return null;
  });
}

// The view of the current node: a group's children, the identity form or a review plate.
export function NodeView({node,nodes,strings,disabled,handlers,identity,identityForm,onIdentity,identityErrors}) {
  if(node?.kind==='identity')return <IdentityForm identity={identity} form={identityForm} onChange={onIdentity} disabled={disabled} errors={identityErrors} strings={strings}/>;
  // the Review is the paper registration card; the creator's carries the typed name as its signature
  if(node?.kind==='review')return <Plate className="review-sheet" sign={identityName(identity,identityForm)} title={node.label} hint={node.hint} items={reviewItems(node,identity,identityForm)}/>;
  return <GroupBody nodes={nodes} strings={strings} disabled={disabled} handlers={handlers}/>;
}

export {isNavigable};
