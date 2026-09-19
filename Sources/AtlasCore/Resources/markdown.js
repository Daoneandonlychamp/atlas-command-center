/* Markdown renderer shared by the Assistant transcript and the canvas.
 *
 * Extracted from chat.html so both surfaces escape and render identically —
 * duplicating this would mean a fix in one file silently not reaching the other,
 * and every branch here is what stands between untrusted model text and
 * innerHTML.
 *
 * Tested by Tests/chat_render_test.js. Keep it passing.
 *
 * Wrapped in an IIFE because it is injected as a user script and therefore
 * shares the page's global scope — a bare `const escapeHtml` here collides with
 * the page's own declaration and kills the page with a redeclaration error.
 * Nothing escapes but window.atlasMarkdown.
 */
'use strict';
(function(){
const SLOT='\u0000';
function escapeHtml(value){return String(value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]))}
function emphasis(text){
  return text
    .replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>')
    .replace(/(^|[^\w])__([^_]+)__(?!\w)/g,'$1<strong>$2</strong>')
    .replace(/\*([^*\n]+)\*/g,'<em>$1</em>')
    .replace(/(^|[^\w])_([^_\n]+)_(?!\w)/g,'$1<em>$2</em>');
}
function inlineMarkdown(value){
  const slots=[];
  const stash=html=>SLOT+(slots.push(html)-1)+SLOT;
  let out=escapeHtml(value);
  out=out.replace(/`([^`]+)`/g,(_,v)=>stash('<code>'+v+'</code>'));
  out=out.replace(/\[([^\]]*)\]\((https?:\/\/[^\s)]+)\)/g,(_,label,href)=>
    stash('<a href="'+href+'">'+emphasis(label)+'</a>'));
  out=emphasis(out);
  const slotRe=new RegExp(SLOT+'(\\d+)'+SLOT,'g');
  let prev;
  do{prev=out;out=out.replace(slotRe,(_,i)=>slots[Number(i)])}while(out!==prev);
  return out;
}
const isTableSep=line=>line.includes('-')&&line.includes('|')&&/^\s*\|?(?:\s*:?-+:?\s*\|)*\s*:?-+:?\s*\|?\s*$/.test(line);
const splitRow=line=>{let s=line.trim();if(s.startsWith('|'))s=s.slice(1);if(s.endsWith('|'))s=s.slice(0,-1);return s.split('|').map(c=>c.trim())};
function renderMarkdown(source){
  const lines=String(source||'').replace(/\r\n?/g,'\n').split('\n');
  let html='',paragraph=[],quote=[];
  const stack=[];
  const flushParagraph=()=>{if(paragraph.length){html+='<p>'+inlineMarkdown(paragraph.join(' '))+'</p>';paragraph=[]}};
  const flushList=()=>{while(stack.length)html+='</'+stack.pop().type+'>'};
  const flushQuote=()=>{if(quote.length){html+='<blockquote>'+renderMarkdown(quote.join('\n'))+'</blockquote>';quote=[]}};
  const flushAll=()=>{flushParagraph();flushList();flushQuote()};
  const openList=(type,indent,numbered)=>{
    const start=numbered&&numbered[2]!=='1'?' start="'+Number(numbered[2])+'"':'';
    html+='<'+type+start+'>';stack.push({type,indent});
  };
  for(let i=0;i<lines.length;i++){
    const line=lines[i];
    const fence=line.match(/^\s*```\s*([^`]*)$/);
    if(fence){
      flushAll();
      const language=fence[1].trim(),chunk=[];
      while(++i<lines.length&&!/^\s*```\s*$/.test(lines[i]))chunk.push(lines[i]);
      html+='<pre>'+(language?'<span class="code-label">'+escapeHtml(language)+'</span>':'')+'<code>'+escapeHtml(chunk.join('\n'))+'</code></pre>';
      continue;
    }
    if(/^\s*$/.test(line)){flushAll();continue}
    const heading=line.match(/^\s*(#{1,6})\s+(.+?)\s*#*$/);
    if(heading){flushAll();const n=heading[1].length;html+='<h'+n+'>'+inlineMarkdown(heading[2])+'</h'+n+'>';continue}
    if(/^\s*(---+|___+|\*\*\*+)\s*$/.test(line)){flushAll();html+='<hr>';continue}
    if(line.includes('|')&&i+1<lines.length&&isTableSep(lines[i+1])){
      flushAll();
      const head=splitRow(line);
      const align=splitRow(lines[i+1]).map(c=>c.startsWith(':')&&c.endsWith(':')?'center':c.endsWith(':')?'right':'');
      const at=n=>align[n]?' style="text-align:'+align[n]+'"':'';
      let body='';
      i++;
      while(i+1<lines.length&&lines[i+1].includes('|')&&!/^\s*$/.test(lines[i+1])){
        i++;
        body+='<tr>'+splitRow(lines[i]).map((c,n)=>'<td'+at(n)+'>'+inlineMarkdown(c)+'</td>').join('')+'</tr>';
      }
      html+='<div class="table-wrap"><table><thead><tr>'+head.map((c,n)=>'<th'+at(n)+'>'+inlineMarkdown(c)+'</th>').join('')+'</tr></thead><tbody>'+body+'</tbody></table></div>';
      continue;
    }
    const bullet=line.match(/^(\s*)[-*+]\s+(.+)$/),numbered=line.match(/^(\s*)(\d+)[.)]\s+(.+)$/);
    if(bullet||numbered){
      flushParagraph();flushQuote();
      const indent=(bullet||numbered)[1].replace(/\t/g,'    ').length;
      const type=bullet?'ul':'ol';
      const text=bullet?bullet[2]:numbered[3];
      while(stack.length>1&&indent<stack[stack.length-1].indent)html+='</'+stack.pop().type+'>';
      const top=stack[stack.length-1];
      if(!top||indent>top.indent)openList(type,indent,numbered);
      else if(top.type!==type){html+='</'+stack.pop().type+'>';openList(type,indent,numbered)}
      html+='<li>'+inlineMarkdown(text)+'</li>';
      continue;
    }
    const quoted=line.match(/^\s*>\s?(.*)$/);
    if(quoted){flushParagraph();flushList();quote.push(quoted[1]);continue}
    flushList();flushQuote();paragraph.push(line.trim());
  }
  flushAll();
  return html;
}

  window.atlasMarkdown = { renderMarkdown, escapeHtml };
})();
