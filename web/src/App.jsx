import React,{useEffect,useState} from 'react';
import Editor from './Editor';
import CharacterCard from './CharacterCard';
export default function App(){
 const [editor,setEditor]=useState(null),[card,setCard]=useState(null),[strings,setStrings]=useState({});
 useEffect(()=>{const receive=({data})=>{
  if(data.locale){document.documentElement.lang=data.locale;document.documentElement.dir=data.locale==='ar'?'rtl':'ltr'}
  if(data.strings)setStrings(v=>({...v,...data.strings}));
  if(data.type==='editor'){setEditor(data);setCard(null)}
  if(data.type==='editorClose'||data.type==='close')setEditor(null);
  if(data.type==='charCard')setCard(data.show===false||data.visible===false||data.isVisible===false?null:(data.data||data));
 };window.addEventListener('message',receive);return()=>window.removeEventListener('message',receive)},[]);
 return editor?<Editor key={editor.id} payload={editor} onPayload={setEditor} onClose={()=>setEditor(null)}/>:card?<CharacterCard data={card} strings={strings}/>:null;
}
