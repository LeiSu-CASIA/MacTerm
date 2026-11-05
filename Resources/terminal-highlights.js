/* Viewport decorations for the pinned xterm 5.5 renderer; regex runs off-thread. */
window.MacTermHighlights={connect(terminal){
 let settings={enabled:false,ignoreCase:true,rules:[]},marks=[],timer=null,disposed=false,revision=0,worker=null,watchdog=null,job=0,suspended=false;
 let snapshot={count:0,truncated:false,ranges:[],pending:false};
 const notice=document.createElement('div');notice.setAttribute('role','status');notice.style.cssText='display:none;position:absolute;bottom:4px;right:8px;z-index:15;background:#202b3c;color:#eed49f;padding:4px 8px;font:11px system-ui;pointer-events:none';terminal.element?.appendChild(notice);
 const fold=s=>s.replace(/[A-Z]/g,c=>c.toLowerCase());
 function clear(){for(const item of marks){item.decoration.dispose();item.marker.dispose()}marks=[];snapshot={count:0,truncated:false,ranges:[],pending:false}}
 function stopWorker(){if(watchdog!==null)clearTimeout(watchdog);watchdog=null;if(worker)worker.terminate();worker=null;job++}
 function issue(message){stopWorker();clear();suspended=true;snapshot.issue=message;notice.textContent=message;notice.style.display='block'}
 function validate(value){if(!value || typeof value.enabled!=='boolean' || typeof value.ignoreCase!=='boolean' || (value.regularExpression!==undefined&&value.regularExpression!==null&&typeof value.regularExpression!=='boolean') || !Array.isArray(value.rules) || value.rules.length>20)throw new Error('Invalid highlight settings');for(const r of value.rules){if(typeof r.keyword!=='string'||!r.keyword.length||r.keyword.length>80||/[\x00-\x1f\x7f\u2028\u2029]/.test(r.keyword)||typeof r.color!=='string'||r.color.length!==7||!/^#[0-9a-fA-F]{6}$/.test(r.color))throw new Error('Invalid highlight rule');if(value.regularExpression)new RegExp(r.keyword,'u')}return JSON.parse(JSON.stringify(value))}
 function regexThread(){self.onmessage=event=>{try{const {groups,rules,ignoreCase}=event.data,patterns=rules.map(rule=>new RegExp(rule.keyword,ignoreCase?'giu':'gu')),matches=[];let truncated=false;
  outer:for(let g=0;g<groups.length;g++)for(let rule=0;rule<patterns.length;rule++){const pattern=patterns[rule],text=groups[g];pattern.lastIndex=0;let match;while((match=pattern.exec(text))!==null){if(match[0].length===0){pattern.lastIndex=match.index+(text.codePointAt(match.index)>0xffff?2:1);continue}matches.push({g,rule,start:match.index,end:match.index+match[0].length});if(matches.length>=10000){truncated=true;break outer}}}
  self.postMessage({matches,truncated});}catch(error){self.postMessage({error:String(error.message)})}}}
 function paint(group,rule,start,end,top,bottom,cursor,occupied){
  const cells=group.positions.slice(start,end),ranges=[];let overlap=false;
  for(const cell of cells){if(!cell||cell.row<top||cell.row>=bottom)continue;for(let x=cell.x;x<cell.end;x++)if(occupied.has(cell.row+':'+x))overlap=true;const last=ranges[ranges.length-1];if(last&&last.row===cell.row){last.end=Math.max(last.end,cell.end)}else ranges.push({row:cell.row,x:cell.x,end:cell.end})}
  if(overlap)return true;
  for(const range of ranges){if(marks.length>=500){snapshot.truncated=true;return false}const marker=terminal.registerMarker(range.row-cursor);if(!marker)continue;
   const color=settings.rules[rule].color,r=parseInt(color.slice(1,3),16),g=parseInt(color.slice(3,5),16),b=parseInt(color.slice(5,7),16),foreground=(r*299+g*587+b*114)>140000?'#10151f':'#ffffff';
   const decoration=terminal.registerDecoration({marker,x:range.x,width:range.end-range.x,backgroundColor:color,foregroundColor:foreground,layer:'bottom'});
   if(!decoration){marker.dispose();continue}marks.push({marker,decoration});snapshot.ranges.push({row:range.row,x:range.x,width:range.end-range.x,rule,color});for(let x=range.x;x<range.end;x++)occupied.add(range.row+':'+x);
  }return true;
 }
 function render(){timer=null;if(suspended)return;stopWorker();clear();if(disposed||!settings.enabled||window.MacTermXtermVersion!=='5.5.0'||terminal.buffer.active.type!=='normal')return;
  const buffer=terminal.buffer.active,top=buffer.viewportY,bottom=Math.min(buffer.length,top+Math.min(terminal.rows,200)),cursor=buffer.baseY+buffer.cursorY,epoch=revision;
  const occupied=new Set(),contextRows=settings.regularExpression?4096:8;let scanBottom=bottom;while(scanBottom<buffer.length&&scanBottom-bottom<contextRows&&buffer.getLine(scanBottom)?.isWrapped)scanBottom++;let first=top;while(first>0&&top-first<contextRows&&buffer.getLine(first)?.isWrapped)first--;
  let text='',positions=[],groups=[],units=0,limited=false,complete=!buffer.getLine(first)?.isWrapped;
  for(let row=first;row<scanBottom;row++){
   const line=buffer.getLine(row);if(!line)continue;if(settings.regularExpression&&terminal.cols>1000)complete=false;let end=Math.min(terminal.cols,1000);while(end>0){const c=line.getCell(end-1);if(c?.getChars()||c?.getWidth()===0)break;end--}
   for(let x=0;x<end;x++){const cell=line.getCell(x);if(!cell||cell.getWidth()===0)continue;const chars=cell.getChars()||' ';if(units+chars.length>1048576){snapshot.truncated=true;limited=true;complete=false;break}text+=chars;units+=chars.length;for(let i=0;i<chars.length;i++)positions.push(row>=top&&row<bottom?{row,x,end:Math.min(terminal.cols,x+Math.max(1,cell.getWidth()))}:null)}
   const wrapped=buffer.getLine(row+1)?.isWrapped;if(!wrapped||row+1===scanBottom||limited){if(text){if(settings.regularExpression&&(!complete||wrapped)){snapshot.truncated=true}else groups.push({text,positions})}text='';positions=[];complete=true;if(limited)break}
  }
  if(!settings.regularExpression){
   outer:for(const group of groups){const haystack=settings.ignoreCase?fold(group.text):group.text;for(let rule=0;rule<settings.rules.length;rule++){const needle=settings.ignoreCase?fold(settings.rules[rule].keyword):settings.rules[rule].keyword;let from=0,index;while((index=haystack.indexOf(needle,from))>=0){from=index+needle.length;if(!paint(group,rule,index,from,top,bottom,cursor,occupied))break outer}}}
   snapshot.count=marks.length;return;
  }
  if(!groups.length||!settings.rules.length)return;
  const ticket=job;snapshot.pending=true;
  try{const url=URL.createObjectURL(new Blob(['('+regexThread.toString()+')()'],{type:'text/javascript'}));try{worker=new Worker(url)}finally{URL.revokeObjectURL(url)}
   worker.onmessage=event=>{if(ticket!==job||disposed)return;if(watchdog!==null)clearTimeout(watchdog);watchdog=null;snapshot.pending=false;worker.terminate();worker=null;if(epoch!==revision||terminal.buffer.active!==buffer||buffer.viewportY!==top)return;
    if(event.data.error){issue('正则高亮无法匹配，请修改规则。');return}
    for(const match of event.data.matches){if(!paint(groups[match.g],match.rule,match.start,match.end,top,bottom,cursor,occupied))break}snapshot.truncated ||= event.data.truncated;snapshot.count=marks.length;
   };
   worker.onerror=()=>{if(ticket===job)issue('正则高亮暂不可用，请修改规则后重试。')};
   watchdog=setTimeout(()=>{if(ticket===job)issue('正则高亮处理超时，已暂停；请修改规则后重试。')},250);
   worker.postMessage({groups:groups.map(group=>group.text),rules:settings.rules,ignoreCase:settings.ignoreCase});
  }catch(error){issue('正则高亮暂不可用，请修改规则后重试。')}
 }
 function schedule(){revision++;if(disposed||suspended)return;if(!settings.enabled){clear();return}if(timer===null)timer=setTimeout(render,60)}
 const subscriptions=[terminal.onWriteParsed(schedule),terminal.onScroll(schedule),terminal.onResize(schedule),terminal.buffer.onBufferChange(()=>{clear();schedule()})];
 return {apply(value){const next=validate(value);revision++;stopWorker();settings=next;suspended=false;notice.style.display='none';schedule()},stats(){return JSON.parse(JSON.stringify(snapshot))},refresh(){revision++;if(timer!==null)clearTimeout(timer);render()},dispose(){disposed=true;if(timer!==null)clearTimeout(timer);stopWorker();for(const s of subscriptions)s.dispose();clear();notice.remove()}};
}};
