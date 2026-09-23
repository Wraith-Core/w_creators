import React,{useEffect,useRef,useState} from 'react';
import {fromDisplay,formatDisplay} from './treeState';

// Storage is -1..1 (the node's min/max); the pad's number inputs show the display scale (−100..100).
const clampTo=(n,min,max)=>Math.round(Math.max(min,Math.min(max,Number(n)||0))*100)/100;

// Two related morphology axes edited together and sent as one setMany (one undo step).
export default function FeaturePad({node,disabled,onChange,text}){
 const {x,y}=node,min=Number(node.min??-1),max=Number(node.max??1),display=node.display||{scale:100,decimals:0};
 const clamp=n=>clampTo(n,min,max);
 const vx=Number(x.value)||0,vy=Number(y.value)||0;
 const [draft,setDraft]=useState({x:vx,y:vy});
 const current=useRef(draft),drag=useRef(false);
 const update=value=>{current.current=value;setDraft(value);};
 useEffect(()=>{if(!disabled&&!drag.current)update({x:vx,y:vy});},[vx,vy,disabled]);
 const commit=()=>{const v=current.current;if(v.x!==vx||v.y!==vy)onChange({[x.control]:v.x,[y.control]:v.y});};
 const span=max-min;
 const point=e=>{
  const rect=e.currentTarget.getBoundingClientRect();
  update({x:clamp(min+(e.clientX-rect.left)/rect.width*span),y:clamp(max-(e.clientY-rect.top)/rect.height*span)});
 };
 const centre=clamp((min+max)/2);
 const pct=v=>(v-min)/span*100;
 const step=display.scale?1/display.scale:.01;
 return <article className="feature-pad">
  <header><strong>{x.label} / {y.label}</strong><button className="wst-button" type="button" disabled={disabled} onClick={()=>{update({x:centre,y:centre});commit();}}>{text.center}</button></header>
  <div className="feature-pad-grid" role="group" tabIndex={disabled?-1:0} aria-label={x.label+' / '+y.label} aria-describedby={'pad-help-'+node.id}
   onPointerDown={e=>{if(disabled||e.button!==0)return;e.preventDefault();drag.current=true;e.currentTarget.setPointerCapture(e.pointerId);point(e);}}
   onPointerMove={e=>{if(drag.current&&!disabled)point(e);}}
   onPointerUp={e=>{if(!drag.current)return;point(e);drag.current=false;commit();}}
   onPointerCancel={()=>{drag.current=false;update({x:vx,y:vy});}}
   onKeyDown={e=>{
    if(disabled)return;
    const delta=(e.shiftKey ? 5 : 1)*step*2,v=current.current;
    if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(e.key)){
     e.preventDefault();update(e.key==='Home'?{x:centre,y:centre}:{x:clamp(v.x+(e.key==='ArrowRight'?delta:e.key==='ArrowLeft'?-delta:0)),y:clamp(v.y+(e.key==='ArrowUp'?delta:e.key==='ArrowDown'?-delta:0))});
    }
   }}
   onKeyUp={e=>{if(!disabled&&['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(e.key))commit();}}
   onBlur={()=>{if(!disabled&&!drag.current)commit();}}>
   <span className="pad-axis pad-top">{y.label} +</span><span className="pad-axis pad-bottom">{y.label} −</span>
   <span className="pad-axis pad-left">−</span><span className="pad-axis pad-right">+</span>
   <span className="pad-center"/><span className="pad-point" style={{left:pct(draft.x)+'%',top:(100-pct(draft.y))+'%'}}/>
  </div>
  <div className="pad-values">{[['x',x],['y',y]].map(([axis,field])=><label key={axis}>{field.label}
   <input className="wst-input" type="number" min={min*(display.scale||1)} max={max*(display.scale||1)} step="1" disabled={disabled} value={formatDisplay(draft[axis],display)}
    onChange={e=>{const v=fromDisplay(e.target.value,display,min,max);if(v!==null)update({...current.current,[axis]:clamp(v)});}}
    onBlur={commit} onKeyDown={e=>{if(e.key==='Enter'){e.preventDefault();commit();}}}/>
  </label>)}</div>
  <small id={'pad-help-'+node.id}>{text.padHelp}</small>
 </article>;
}
