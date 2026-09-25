import React,{useEffect,useRef,useState} from 'react';
import {fromDisplay,formatDisplay} from './treeState';

// Storage is -1..1 (the node's min/max); the pad's number inputs show the display scale (−100..100).
const clampTo=(n,min,max)=>Math.round(Math.max(min,Math.min(max,Number(n)||0))*100)/100;

// The product of every CSS `zoom` between an element and the root. The panel is scaled with
// zoom:var(--ui-scale) (store-adapter.css), which is above 1 on anything taller than 1080p.
const effectiveZoom=el=>{
 let z=1;
 for(let a=el;a&&a.nodeType===1;a=a.parentElement){const v=parseFloat(getComputedStyle(a).zoom);if(v>0&&v!==1)z*=v;}
 return z;
};

// Two related morphology axes edited together and sent as one setMany (one undo step). While the
// pointer is down every move is previewed on the ped (onPreview); the release commits once.
export default function FeaturePad({node,disabled,onChange,onPreview,text}){
 const {x,y}=node,min=Number(node.min??-1),max=Number(node.max??1),display=node.display||{scale:100,decimals:0};
 const clamp=n=>clampTo(n,min,max);
 const vx=Number(x.value)||0,vy=Number(y.value)||0;
 const [draft,setDraft]=useState({x:vx,y:vy});
 const current=useRef(draft),drag=useRef(false);
 // per gesture: the zoom in force and which space the rect is measured in (see measure)
 const gesture=useRef({zoom:1,rectZoomed:false,previewed:false}),previewRef=useRef(onPreview);previewRef.current=onPreview;
 // unmounted mid-drag (Escape pops the view): the working look comes back, nothing is left previewed
 useEffect(()=>()=>{if(gesture.current.previewed&&previewRef.current)previewRef.current(null);},[]);
 const preview=v=>{if(!onPreview)return;gesture.current.previewed=true;onPreview({[x.control]:v.x,[y.control]:v.y});};
 const update=(value,live)=>{current.current=value;setDraft(value);if(live)preview(value);};
 useEffect(()=>{if(!disabled&&!drag.current)update({x:vx,y:vy});},[vx,vy,disabled]);
 const commit=()=>{
  const v=current.current;
  if(v.x!==vx||v.y!==vy)onChange({[x.control]:v.x,[y.control]:v.y});
  else if(gesture.current.previewed&&onPreview)onPreview(null); // ended where it began: the working look comes back
  gesture.current.previewed=false;
 };
 const cancel=()=>{drag.current=false;update({x:vx,y:vy});if(gesture.current.previewed&&onPreview)onPreview(null);gesture.current.previewed=false;};
 const span=max-min;
 // ⚠️ Pointer coordinates and the element's rect do not share a space once an ancestor is zoomed.
 //    In the game's CEF every layout API (getBoundingClientRect, offsetWidth, and offsetX too)
 //    is in UNZOOMED layout pixels while clientX/clientY arrive in zoomed viewport pixels: the
 //    first version mixed them and the point stuck to a corner; the second divided offsetX by a
 //    width in the other space and the point ran ahead of the cursor. Modern Chromium instead
 //    returns the rect zoomed, in the pointer's own space. So the gesture measures which case it
 //    is in: offsetWidth is layout pixels in both, and whichever of (offsetWidth, offsetWidth×zoom)
 //    the rect's width is nearer to says whether clientX must be divided by the zoom first.
 const measure=el=>{
  const z=effectiveZoom(el),rect=el.getBoundingClientRect();
  const rectZoomed=z!==1&&Math.abs(rect.width-el.offsetWidth*z)<Math.abs(rect.width-el.offsetWidth);
  gesture.current.zoom=z;gesture.current.rectZoomed=rectZoomed;
 };
 const point=e=>{
  const el=e.currentTarget,rect=el.getBoundingClientRect(),g=gesture.current,k=g.rectZoomed?1:g.zoom;
  const fx=(e.clientX/k-rect.left)/(rect.width||1),fy=(e.clientY/k-rect.top)/(rect.height||1);
  update({x:clamp(min+fx*span),y:clamp(max-fy*span)},true);
 };
 const centre=clamp((min+max)/2);
 const pct=v=>(v-min)/span*100;
 const step=display.scale?1/display.scale:.01;
 return <article className="feature-pad">
  <header><strong>{x.label} / {y.label}</strong><button className="wst-button" type="button" disabled={disabled} onClick={()=>{update({x:centre,y:centre});commit();}}>{text.center}</button></header>
  <div className="feature-pad-grid" role="group" tabIndex={disabled?-1:0} aria-label={x.label+' / '+y.label} aria-describedby={'pad-help-'+node.id}
   onPointerDown={e=>{if(disabled||e.button!==0)return;e.preventDefault();drag.current=true;measure(e.currentTarget);e.currentTarget.setPointerCapture(e.pointerId);point(e);}}
   onPointerMove={e=>{if(drag.current&&!disabled)point(e);}}
   onPointerUp={e=>{if(!drag.current)return;point(e);drag.current=false;commit();}}
   onPointerCancel={cancel}
   onKeyDown={e=>{
    if(disabled)return;
    const delta=(e.shiftKey ? 5 : 1)*step*2,v=current.current;
    if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(e.key)){
     e.preventDefault();update(e.key==='Home'?{x:centre,y:centre}:{x:clamp(v.x+(e.key==='ArrowRight'?delta:e.key==='ArrowLeft'?-delta:0)),y:clamp(v.y+(e.key==='ArrowUp'?delta:e.key==='ArrowDown'?-delta:0))},true);
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
    onChange={e=>{const v=fromDisplay(e.target.value,display,min,max);if(v!==null)update({...current.current,[axis]:clamp(v)},true);}}
    onBlur={commit} onKeyDown={e=>{if(e.key==='Enter'){e.preventDefault();commit();}}}/>
  </label>)}</div>
  <small id={'pad-help-'+node.id}>{text.padHelp}</small>
 </article>;
}
