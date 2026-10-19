import { createEditor, openDocument, snapshot, safeLink } from './document.mjs'

const $=id=>document.getElementById(id)
const menu=$('slash-menu'),form=$('link-form'),canvas=$('canvas')
let identity=null,revision=0,loaded=false,slash=null,selected=0,filtered=[],ignoredSlash='',linkSelection=null,composing=false
const post=payload=>window.webkit?.messageHandlers.canopyNotes.postMessage({ ...identity,...payload })
const transient=()=>post({ kind:'transient',open:!menu.hidden || !form.hidden || composing })
const commands=[
  { title:'Text', glyph:'T', key:'text', run:chain=>chain.clearNodes().setParagraph() },
  { title:'Heading', glyph:'H₁', key:'h1', run:chain=>chain.toggleHeading({level:1}) },
  { title:'Subheading', glyph:'H₂', key:'h2', run:chain=>chain.toggleHeading({level:2}) },
  { title:'To-do list', glyph:'☑', key:'tasks', aliases:'todo task checkbox checklist to do', run:chain=>chain.toggleTaskList() },
  { title:'Bullet list', glyph:'•', key:'bullets', run:chain=>chain.toggleBulletList() },
  { title:'Numbered list', glyph:'1.', key:'numbers', run:chain=>chain.toggleOrderedList() },
  { title:'Quote', glyph:'❝', key:'quote', run:chain=>chain.toggleBlockquote() },
  { title:'Divider', glyph:'—', key:'divider', run:chain=>chain.setHorizontalRule() },
]

function hideSlash() { slash=null;menu.hidden=true;transient() }
function choose(command,fromSlash=false) {
  let chain=editor.chain().focus()
  if(fromSlash && slash) chain=chain.deleteRange({from:slash.from,to:editor.state.selection.from})
  hideSlash();command.run(chain).run();updateToolbar()
}
function updateToolbar() {
  $('bold').setAttribute('aria-pressed',String(editor.isActive('bold')))
  $('italic').setAttribute('aria-pressed',String(editor.isActive('italic')))
  const value=editor.isActive('taskList')?'tasks':editor.isActive('bulletList')?'bullets':editor.isActive('orderedList')?'numbers':
    editor.isActive('heading',{level:1})?'h1':editor.isActive('heading',{level:2})?'h2':editor.isActive('blockquote')?'quote':'text'
  $('block-type').value=value
}
function updateSlash() {
  if(!loaded || composing || !form.hidden) return
  const {$from,empty}=editor.state.selection
  const prefix=$from.parent.textBetween(0,$from.parentOffset,'\n')
  const match=empty && $from.parent.type.name==='paragraph' && /^\/([\w -]*)$/.exec(prefix)
  if(!match || ignoredSlash===`${$from.start()}:${prefix}`) { if(slash)hideSlash();return }
  const query=match[1].toLowerCase()
  filtered=commands.filter(command=>`${command.title} ${command.key} ${command.aliases || ''}`.toLowerCase().includes(query))
  if(!filtered.length) { hideSlash();return }
  if(slash?.query!==query)selected=0
  slash={from:$from.start(),query};selected=Math.min(selected,filtered.length-1)
  menu.replaceChildren()
  filtered.forEach((command,index)=>{
    const button=document.createElement('button');button.type='button';button.role='option';button.setAttribute('aria-selected',String(index===selected))
    const glyph=document.createElement('span');glyph.className='glyph';glyph.textContent=command.glyph
    const label=document.createElement('span');label.textContent=command.title
    button.append(glyph,label);button.addEventListener('pointerdown',event=>event.preventDefault());button.addEventListener('click',()=>choose(command,true));menu.append(button)
  })
  menu.hidden=false
  const coords=editor.view.coordsAtPos(editor.state.selection.from),height=Math.min(250,filtered.length*34+10)
  menu.style.left=`${Math.max(8,Math.min(innerWidth-220,coords.left))}px`
  menu.style.top=`${Math.max(42,coords.bottom+height+8<innerHeight?coords.bottom+5:coords.top-height-5)}px`
  transient()
}
function openLink() {
  hideSlash();linkSelection={from:editor.state.selection.from,to:editor.state.selection.to}
  $('link-address').value=editor.getAttributes('link').href || ''
  $('link-error').hidden=true;form.hidden=false;transient();$('link-address').focus();$('link-address').select()
}
function closeLink() { form.hidden=true;transient();editor.commands.focus() }

const editor=createEditor({
  element:$('editor'),editable:false,
  editorProps:{
    attributes:{ role:'textbox','aria-label':'Meeting notes','aria-multiline':'true',spellcheck:'true' },
    handleKeyDown(_view,event) {
      if(event.isComposing)return false
      if((event.metaKey || event.ctrlKey) && event.key.toLowerCase()==='k') { openLink();return true }
      if(slash && ['ArrowDown','ArrowUp','Enter','Escape'].includes(event.key)) {
        if(event.key==='Escape') { const {$from}=editor.state.selection;ignoredSlash=`${$from.start()}:${$from.parent.textBetween(0,$from.parentOffset,'\n')}`;hideSlash() }
        else if(event.key==='Enter')choose(filtered[selected],true)
        else { selected=(selected+(event.key==='ArrowDown'?1:-1)+filtered.length)%filtered.length;updateSlash() }
        return true
      }
      return false
    },
  },
  onUpdate() { if(loaded)post({kind:'change',revision:++revision,...snapshot(editor)});updateToolbar();updateSlash() },
  onSelectionUpdate() { updateToolbar();updateSlash() },
})

for(const id of ['bold','italic','link']) $(id).addEventListener('pointerdown',event=>event.preventDefault())
$('bold').addEventListener('click',()=>editor.chain().focus().toggleBold().run())
$('italic').addEventListener('click',()=>editor.chain().focus().toggleItalic().run())
$('link').addEventListener('click',openLink)
$('block-type').addEventListener('change',event=>{ const command=commands.find(command=>command.key===event.target.value);if(command)choose(command) })
form.addEventListener('submit',event=>{
  event.preventDefault();const href=$('link-address').value.trim()
  if(!safeLink(href)) { $('link-error').hidden=false;return }
  form.hidden=true;transient()
  let chain=editor.chain().focus().setTextSelection(linkSelection).extendMarkRange('link')
  if(linkSelection.from===linkSelection.to && !editor.isActive('link'))chain=chain.insertContent({type:'text',text:href,marks:[{type:'link',attrs:{href}}]})
  else chain=chain.setLink({href})
  chain.run()
})
$('link-cancel').addEventListener('click',closeLink)
$('link-remove').addEventListener('click',()=>{ form.hidden=true;transient();editor.chain().focus().setTextSelection(linkSelection).extendMarkRange('link').unsetLink().run() })
form.addEventListener('keydown',event=>{ if(event.key==='Escape') { event.preventDefault();closeLink() } })
canvas.addEventListener('click',event=>{
  const anchor=event.target.closest('a')
  if(anchor) { event.preventDefault();if(event.metaKey && safeLink(anchor.href))post({kind:'openLink',url:anchor.href}) }
})
canvas.addEventListener('compositionstart',()=>{ composing=true;transient() })
canvas.addEventListener('compositionend',()=>{ composing=false;transient();updateSlash() })
canvas.addEventListener('scroll',()=>{ if(slash)updateSlash() })

window.canopyNotes={
  open(config) {
    loaded=false;identity={meetingID:config.meetingID,session:config.session};revision=0
    try {
      openDocument(editor,config.json,config.plainText);editor.setEditable(true);loaded=true;updateToolbar()
      post({kind:'loaded'})
    } catch { editor.setEditable(false);post({kind:'error',message:'This formatted note could not be opened. Its saved content is preserved.'}) }
  },
  // A flush catches an undelivered edit, but must never turn merely opening an
  // old plain note into an edit or create another revision for saved content.
  snapshot() { return loaded && revision>0?{...identity,kind:'change',revision,...snapshot(editor)}:null },
  blockSaving() {
    loaded=false;hideSlash();form.hidden=true;transient();editor.setEditable(false)
    document.querySelectorAll('.toolbar button,.toolbar select').forEach(control=>{control.disabled=true})
  },
}
post({kind:'ready'})
