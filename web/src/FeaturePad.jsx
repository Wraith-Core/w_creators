import React,{useEffect,useRef,useState} from 'react';

const clamp=n=>Math.round(Math.max(-1,Math.min(1,Number(n)||0))*100)/100;
export const featureValue=(field,app)=>field.expression
  ? Number(app.components?.__expressions?.[field.expression]||0)
  : Number((app.faceFeatures||[]).find(v=>v.hash===field.hash)?.index||0);

// Related native axes are edited together, and saved as a single undo step.
const PAIRS=[
 ['eyelid_width','eyelid_height'],['eyes_distance','eyes_height'],['eyes_angle','eyes_depth'],
 ['eyebrow_width','eyebrow_height'],['eyelidLeft','eyelidRight'],
 ['nose_width','nose_height'],['nose_size','nose_angle'],['nose_curvature','nostrils_distance'],
 ['mouth_x_pos','mouth_y_pos'],['mouth_width','mouth_depth'],
 ['upper_lip_width','upper_lip_height'],['lower_lip_width','lower_lip_height'],
 ['upper_lip_depth','lower_lip_depth'],
 ['mouthConerLeftWidth','mouthConerLeftHeight'],['mouthConerRightWidth','mouthConerRightHeight'],
 ['mouthConerLeftDepth','mouthConerLeftLipsDistance'],['mouthConerRightDepth','mouthConerRightLipsDistance'],
 ['chin_width','chin_height'],['jaw_width','jaw_height'],['chin_depth','jaw_depth'],
 ['cheekbones_width','cheekbones_height'],['ears_width','ear_height'],['ears_angle','earlobe_size'],
 ['face_width','faceWidth'],['shoulders','shoulderThickness'],['neckWidth','neckDepth'],['thighs','calves'],
 ['chest','waist'],['arms','hip'],
];
export function pairFeatures(fields){
 const used=new Set(),pairs=[];
 for(const [a,b] of PAIRS){
  const x=fields.find(f=>f.id===a),y=fields.find(f=>f.id===b);
  if(x&&y){pairs.push([x,y]);used.add(a);used.add(b);}
 }
 return {pairs,other:fields.filter(f=>!used.has(f.id))};
}

export default function FeaturePad({x,y,app,disabled,onChange,text}){
 const vx=featureValue(x,app),vy=featureValue(y,app);
 const [draft,setDraft]=useState({x:vx,y:vy});
 const current=useRef(draft),drag=useRef(false);
 const update=value=>{current.current=value;setDraft(value);};
 useEffect(()=>{if(!disabled&&!drag.current)update({x:vx,y:vy});},[vx,vy,disabled]);
 const commit=()=>{const v=current.current;if(v.x!==vx||v.y!==vy)onChange({[x.id]:v.x,[y.id]:v.y});};
 const point=e=>{
  const rect=e.currentTarget.getBoundingClientRect();
  update({x:clamp((e.clientX-rect.left)/rect.width*2-1),y:clamp(1-(e.clientY-rect.top)/rect.height*2)});
 };
 return <article className="feature-pad">
  <header><strong>{x.name} / {y.name}</strong><button className="wst-button" type="button" disabled={disabled} onClick={()=>{update({x:0,y:0});commit();}}>{text.center}</button></header>
  <div className="feature-pad-grid" role="group" tabIndex={disabled?-1:0} aria-label={x.name+' / '+y.name} aria-describedby={'pad-help-'+x.id}
   onPointerDown={e=>{if(disabled||e.button!==0)return;e.preventDefault();drag.current=true;e.currentTarget.setPointerCapture(e.pointerId);point(e);}}
   onPointerMove={e=>{if(drag.current&&!disabled)point(e);}}
   onPointerUp={e=>{if(!drag.current)return;point(e);drag.current=false;commit();}}
   onPointerCancel={()=>{drag.current=false;update({x:vx,y:vy});}}
   onKeyDown={e=>{
    if(disabled)return;
    const step=e.shiftKey ? .1 : .02,v=current.current;
    if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(e.key)){
     e.preventDefault();update(e.key==='Home'?{x:0,y:0}:{x:clamp(v.x+(e.key==='ArrowRight'?step:e.key==='ArrowLeft'?-step:0)),y:clamp(v.y+(e.key==='ArrowUp'?step:e.key==='ArrowDown'?-step:0))});
    }
   }}
   onKeyUp={e=>{if(!disabled&&['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(e.key))commit();}}
   onBlur={()=>{if(!disabled&&!drag.current)commit();}}>
   <span className="pad-axis pad-top">{y.name} +</span><span className="pad-axis pad-bottom">{y.name} −</span>
   <span className="pad-axis pad-left">−</span><span className="pad-axis pad-right">+</span>
   <span className="pad-center"/><span className="pad-point" style={{left:((draft.x+1)*50)+'%',top:((1-draft.y)*50)+'%'}}/>
  </div>
  <div className="pad-values">{[['x',x],['y',y]].map(([axis,field])=><label key={axis}>{field.name}
   <input className="wst-input" type="number" min="-1" max="1" step=".02" disabled={disabled} value={draft[axis]} onChange={e=>update({...current.current,[axis]:clamp(e.target.value)})} onBlur={commit} onKeyDown={e=>{if(e.key==='Enter'){e.preventDefault();commit();}}}/>
  </label>)}</div>
  <small id={'pad-help-'+x.id}>{text.padHelp}</small>
 </article>;
}
