export async function nuiSend(event,data={}) {
 const resource=typeof GetParentResourceName==='function'?GetParentResourceName():'w_creators';
 const controller=new AbortController();
 const timer=setTimeout(()=>controller.abort(),45000);
 try {
  const response=await fetch(`https://${resource}/${event}`,{method:'POST',headers:{'Content-Type':'application/json; charset=UTF-8'},body:JSON.stringify(data),signal:controller.signal});
  if(!response.ok)throw new Error('Request failed');
  return await response.json();
 } finally{clearTimeout(timer)}
}
