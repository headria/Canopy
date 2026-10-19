import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { JSDOM } from 'jsdom'

test('the actual host bridge flushes only user edits and keeps their revision',async()=>{
  const html=await readFile(new URL('../src/index.html',import.meta.url),'utf8')
  const dom=new JSDOM(html,{pretendToBeVisual:true})
  for(const key of ['window','document','navigator','Node','HTMLElement','Element','MutationObserver','getComputedStyle','DOMParser'])
    Object.defineProperty(globalThis,key,{value:key==='getComputedStyle'?dom.window[key].bind(dom.window):dom.window[key],configurable:true})
  globalThis.requestAnimationFrame=dom.window.requestAnimationFrame.bind(dom.window)
  globalThis.cancelAnimationFrame=dom.window.cancelAnimationFrame.bind(dom.window)
  const messages=[]
  dom.window.webkit={messageHandlers:{canopyNotes:{postMessage:value=>messages.push(value)}}}
  await import('../src/editor.mjs')
  const bridge=dom.window.canopyNotes
  bridge.open({meetingID:'legacy-note',session:'first',json:null,plainText:'  Original 📝\n\n# Literal\n'})
  assert.equal(bridge.snapshot(),null)
  assert.equal(messages.some(message=>message.kind==='change'),false)
  const json=JSON.stringify({type:'doc',content:[{type:'taskList',content:[{type:'taskItem',attrs:{checked:false},content:[{type:'paragraph',content:[{type:'text',text:'Send recap'}]}]}]}]})
  bridge.open({meetingID:'task-note',session:'second',json,plainText:'Send recap'})
  assert.equal(bridge.snapshot(),null)
  document.querySelector('input[type=checkbox]').click()
  const edit=messages.find(message=>message.kind==='change'),flush=bridge.snapshot()
  assert.equal(edit.meetingID,'task-note');assert.equal(edit.session,'second')
  assert.equal(edit.revision,1);assert.equal(flush.revision,1);assert.equal(flush.json,edit.json)
  assert.match(flush.markdown,/- \[x\] Send recap/)
  assert.equal(bridge.snapshot().revision,1)
  dom.window.close()
})
