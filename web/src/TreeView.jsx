import React,{useEffect,useState} from 'react';
import {Glyph,Choice} from './Chrome';
import FeaturePad from './FeaturePad';
import {choiceOptions,formatDisplay,formatMoney,isNavigable,rowValue,segments} from './treeState';

// The generic renderer of one node of the Lua tree (§8.2), built from the original components:
// MenuRow, Choice, Slider, FeaturePad and the wst-plate panels. Every text comes from the node or
// from payload.strings; nothing here is hardcoded copy.

export function Slider({node,disabled,onChange}) {
  const min=Number(node.min??0),max=Number(node.max??1),step=Number(node.step)||.01;
  const display=node.display||{scale:1,decimals:step<1?2:0};
  const value=Number(node.value)||0;
  const [draft,setDraft]=useState(value);
  useEffect(()=>setDraft(value),[value]);
  const commit=()=>{if(Number(draft)!==value)onChange(Number(draft))};
  const off=disabled||node.disabled;
  return <label className="slider-field"><span>{node.label}<output>{formatDisplay(draft,display)}</output></span>
    <span className="range-track" style={{'--range-fill':`${(Number(draft)-min)/((max-min)||1)*100}%`}}>
      <input aria-label={node.label} type="range" min={min} max={max} step={step} value={draft} disabled={off} onChange={e=>setDraft(e.target.value)} onPointerUp={commit} onKeyUp={commit} onBlur={commit}/>
    </span>
  </label>;
}

export function MenuRow({id,label,value,art,onClick,disabled=false,action=false}) {
  return <button type="button" className="wst-card menu-row" data-navkey={id} disabled={disabled} onClick={onClick}>
    {art&&<Glyph tex={art} className="row-art"/>}<span className="row-label">{label}</span>
    {value!=null&&value!==''&&<span className="row-value">{value}</span>}{!action&&<Glyph tex="selection_arrow_right" className="row-arrow"/>}
  </button>;
}

function TextNode({node,disabled,onInvoke}) {
  const [draft,setDraft]=useState(node.value||'');
  useEffect(()=>setDraft(node.value||''),[node.value]);
  const off=disabled||node.disabled;
  const submit=()=>{if(!off)onInvoke(node.control,draft)};
  return <div className="identity">
    <label>{node.label}<span className="wst-field input-plate"><input className="wst-input" autoComplete="off" maxLength={node.maxLength||undefined} placeholder={node.placeholder||undefined} disabled={off} value={draft}
      onChange={e=>setDraft(e.target.value)} onKeyDown={e=>{if(e.key==='Enter'){e.preventDefault();submit();}}}/></span></label>
    {node.actionLabel&&<button type="button" className="wst-button" disabled={off} onClick={submit}>{node.actionLabel}</button>}
    {node.reason&&<p className="menu-help">{node.reason}</p>}
  </div>;
}

function Plate({title,hint,items,className=''}) {
  return <aside className={'wst-plate growth '+className}><strong>{title}</strong>
    {hint&&<p>{hint}</p>}
    {(items||[]).map((item,i)=><p key={i}>{item.label}<span>{item.value}</span></p>)}
  </aside>;
}

function ItemCard({node,strings}) {
  const item=node.item||{};
  const items=[];
  if(item.price!=null)items.push({label:strings.price||'',value:formatMoney(item.price)});
  if(item.owned||item.equipped)items.push({label:(item.equipped?strings.equipped:strings.owned)||'',value:''});
  if(item.variants)items.push({label:strings.variants||'',value:String(item.variants)});
  return <Plate className="item-card" title={item.name||node.label} items={items}/>;
}

export function IdentityForm({identity,form,onChange,disabled}) {
  return <div className="identity">
    {(identity?.fields||[]).map(f=><label key={f.key}>{f.label}<span className="wst-field input-plate">
      {f.type==='info'
        ?<input className="wst-input" readOnly value={f.value||''}/>
        :<input className="wst-input" required autoComplete="off" disabled={disabled} type={f.type==='date'?'date':'text'} maxLength={f.maxLength||undefined} min={f.min||undefined} max={f.max||undefined}
          value={form?.[f.key]||''} onChange={e=>onChange({...form,[f.key]:e.target.value})}/>}
    </span></label>)}
  </div>;
}

function Control({node,strings,disabled,handlers}) {
  if(node.kind==='slider')return <Slider node={node} disabled={disabled} onChange={v=>handlers.set(node.control,v)}/>;
  const options=choiceOptions(node,strings);
  return <Choice caption={node.label} label={node.label} value={node.value} options={options} disabled={disabled||node.disabled||options.length===0} onChange={v=>handlers.set(node.control,v)}/>;
}

// The children of a group (already filtered by search) in their render segments.
export function GroupBody({nodes,strings,disabled,handlers}) {
  return segments(nodes).map((seg,i)=>{
    if(seg.type==='rows')return <nav key={i} className="menu-list">{seg.nodes.map(n=>n.kind==='action'
      ?<React.Fragment key={n.id}><MenuRow id={n.id} label={n.label} action disabled={disabled||!!n.disabled} value={n.summary} onClick={()=>(n.danger&&handlers.confirm?handlers.confirm(n):handlers.invoke(n.control))}/>{n.disabled&&n.reason&&<p className="menu-help">{n.reason}</p>}</React.Fragment>
      :<MenuRow key={n.id} id={n.id} label={n.label} art={n.art} value={rowValue(n,strings)} disabled={!!n.disabled} onClick={()=>handlers.open(n)}/>)}</nav>;
    if(seg.type==='controls')return <article key={i} className="component">{seg.nodes.map(n=><Control key={n.id} node={n} strings={strings} disabled={disabled} handlers={handlers}/>)}</article>;
    if(seg.type==='pads')return <React.Fragment key={i}>{seg.nodes.map(n=><FeaturePad key={n.id} node={n} text={strings} disabled={disabled||!!n.disabled} onChange={values=>handlers.setMany(values)}/>)}</React.Fragment>;
    if(seg.type==='extra')return <details key={i} className="feature-extra"><summary>{strings.advanced}</summary>{seg.nodes.map(n=><Slider key={n.id} node={n} disabled={disabled} onChange={v=>handlers.set(n.control,v)}/>)}</details>;
    const n=seg.nodes[0];
    if(n.kind==='text')return <TextNode key={n.id} node={n} disabled={disabled} onInvoke={handlers.invoke}/>;
    if(n.kind==='itemcard')return <ItemCard key={n.id} node={n} strings={strings}/>;
    if(n.kind==='info'||n.kind==='review')return <Plate key={n.id} title={n.label} hint={n.hint} items={n.items}/>;
    return null;
  });
}

// The view of the current node: a group's children, the identity form or a review plate.
export function NodeView({node,nodes,strings,disabled,handlers,identity,identityForm,onIdentity}) {
  if(node?.kind==='identity')return <IdentityForm identity={identity} form={identityForm} onChange={onIdentity} disabled={disabled}/>;
  if(node?.kind==='review')return <Plate title={node.label} hint={node.hint} items={node.items}/>;
  return <GroupBody nodes={nodes} strings={strings} disabled={disabled} handlers={handlers}/>;
}

export {isNavigable};
