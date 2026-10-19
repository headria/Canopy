import { test } from 'node:test'
import assert from 'node:assert/strict'
import { JSDOM } from 'jsdom'
import { createEditor,openDocument,snapshot,safeLink } from '../src/document.mjs'

const dom=new JSDOM('<!doctype html><html><body></body></html>',{pretendToBeVisual:true})
for(const key of ['window','document','navigator','Node','HTMLElement','Element','MutationObserver','getComputedStyle','DOMParser'])
  Object.defineProperty(globalThis,key,{value:typeof dom.window[key]==='function' && key==='getComputedStyle'?dom.window[key].bind(dom.window):dom.window[key],configurable:true})
globalThis.requestAnimationFrame=dom.window.requestAnimationFrame.bind(dom.window)
globalThis.cancelAnimationFrame=dom.window.cancelAnimationFrame.bind(dom.window)
dom.window.Range.prototype.getClientRects=()=>[]
dom.window.Range.prototype.getBoundingClientRect=()=>({top:0,bottom:0,left:0,right:0,width:0,height:0})
const make=()=>{const element=document.createElement('div');document.body.append(element);return createEditor({element})}
const fixture={type:'doc',content:[
  {type:'heading',attrs:{level:2},content:[{type:'text',text:'Next steps'}]},
  {type:'paragraph',content:[{type:'text',text:'Keep this',marks:[{type:'bold'}]},{type:'text',text:' reference',marks:[{type:'link',attrs:{href:'https://example.org/design'}}]}]},
  {type:'taskList',content:[{type:'taskItem',attrs:{checked:false},content:[{type:'paragraph',content:[{type:'text',text:'Send review'}]}]},{type:'taskItem',attrs:{checked:true},content:[{type:'paragraph',content:[{type:'text',text:'Prepare slides'}]}]}]},
]}

test('legacy notes remain literal, preserving blank lines, Unicode and markup-like text',()=>{
  let updates=0;const editor=make();editor.on('update',()=>updates++)
  const text='  Original 📝\n\n# Not an imported heading\n<script>literal</script>\n'
  openDocument(editor,null,text)
  assert.equal(snapshot(editor).plainText,text);assert.equal(updates,0)
  assert.equal(editor.isActive('heading'),false);assert.equal(editor.view.dom.querySelector('script'),null)
  editor.destroy()
})
test('headings, inline marks, links and checked tasks survive a document round trip and export',()=>{
  const editor=make();openDocument(editor,JSON.stringify(fixture),'')
  const saved=snapshot(editor)
  assert.match(saved.markdown,/## Next steps/);assert.match(saved.markdown,/\*\*Keep this\*\*/)
  assert.match(saved.markdown,/https:\/\/example.org\/design/);assert.match(saved.markdown,/- \[ \] Send review/);assert.match(saved.markdown,/- \[x\] Prepare slides/)
  const second=make();openDocument(second,saved.json,'')
  assert.deepEqual(second.getJSON(),editor.getJSON());assert.equal(snapshot(second).markdown,saved.markdown)
  editor.destroy();second.destroy()
})
test('clicking an inline checkbox edits the document and exported completion state',()=>{
  const editor=make();openDocument(editor,JSON.stringify(fixture),'')
  editor.view.dom.querySelector('input[type=checkbox]').click()
  assert.equal(editor.getJSON().content[2].content[0].attrs.checked,true)
  assert.match(snapshot(editor).markdown,/- \[x\] Send review/)
  editor.destroy()
})
test('undo removes a user edit without undoing the original document load',()=>{
  const editor=make();openDocument(editor,null,'Original note')
  editor.commands.setTextSelection(14);editor.commands.insertContent(' added')
  assert.equal(snapshot(editor).plainText,'Original note added')
  assert.equal(editor.commands.undo(),true);assert.equal(snapshot(editor).plainText,'Original note')
  assert.equal(editor.commands.undo(),false);assert.equal(snapshot(editor).plainText,'Original note')
  editor.destroy()
})
test('unsupported documents fail without replacing the current note',()=>{
  const editor=make();openDocument(editor,null,'Preserve this')
  assert.throws(()=>openDocument(editor,'{"type":"doc","content":[{"type":"future-widget"}]}',''))
  assert.equal(snapshot(editor).plainText,'Preserve this');editor.destroy()
})
test('links accept explicit web addresses and reject executable, local and credential-bearing URLs',()=>{
  for(const value of ['https://example.org','http://localhost:3000/path'])assert.equal(safeLink(value),true)
  for(const value of ['javascript:alert(1)','file:///etc/passwd','https://user:secret@example.org','not a link'])assert.equal(safeLink(value),false)
})
test('new link marks are canonicalized and typing after a label stays outside the link',()=>{
  const editor=make();openDocument(editor,null,'Reference')
  editor.commands.setTextSelection({from:1,to:10})
  editor.commands.setLink({href:' https://example.org/a b '})
  assert.equal(editor.getJSON().content[0].content[0].marks[0].attrs.href,'https://example.org/a%20b')
  editor.commands.setTextSelection(10);editor.commands.insertContent(' next')
  const text=editor.getJSON().content[0].content
  assert.equal(text.at(-1).text,' next');assert.equal(text.at(-1).marks,undefined)
  editor.destroy()
})
test('the Text command unwraps a list without dropping its content',()=>{
  const editor=make();openDocument(editor,null,'A simple item')
  editor.commands.setTextSelection(4);editor.commands.toggleTaskList()
  assert.equal(editor.isActive('taskList'),true)
  editor.chain().clearNodes().setParagraph().run()
  assert.equal(editor.isActive('taskList'),false)
  assert.equal(snapshot(editor).plainText.trimEnd(),'A simple item')
  editor.destroy()
})
