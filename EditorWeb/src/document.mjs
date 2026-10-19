import { Editor, Extension } from '@tiptap/core'
import { Plugin } from '@tiptap/pm/state'
import Link from '@tiptap/extension-link'
import StarterKit from '@tiptap/starter-kit'
import { TaskList, TaskItem } from '@tiptap/extension-list'
import Placeholder from '@tiptap/extension-placeholder'
import { Markdown } from '@tiptap/markdown'

export function safeLink(value) {
  try { const url = new URL(value); return ['https:', 'http:'].includes(url.protocol) && !!url.hostname && !url.username && !url.password }
  catch { return false }
}

const CanonicalLinks = Extension.create({
  name:'canonicalLinks',
  addProseMirrorPlugins() {
    return [new Plugin({ appendTransaction(transactions,_old,state) {
      if(!transactions.some(transaction=>transaction.docChanged))return null
      const transaction=state.tr
      state.doc.descendants((node,pos)=>{
        if(!node.isText)return
        for(const mark of node.marks)if(mark.type.name==='link') {
          const href=safeLink(mark.attrs.href)?new URL(mark.attrs.href).href:null
          if(href!==mark.attrs.href) {
            transaction.removeMark(pos,pos+node.nodeSize,mark)
            if(href)transaction.addMark(pos,pos+node.nodeSize,mark.type.create({...mark.attrs,href}))
          }
        }
      })
      return transaction.docChanged?transaction.setMeta('addToHistory',false):null
    } })]
  },
})

export function legacyDocument(text) {
  return { type:'doc', content:text.split('\n').map(line => ({ type:'paragraph', ...(line ? { content:[{ type:'text', text:line }] } : {}) })) }
}

export function createEditor(options = {}) {
  return new Editor({
    extensions:[
      StarterKit.configure({ heading:{ levels:[1,2] }, link:false }),
      Link.extend({inclusive:false}).configure({openOnClick:false,autolink:true,defaultProtocol:'https',isAllowedUri:safeLink}), CanonicalLinks,
      TaskList, TaskItem.configure({ nested:true, HTMLAttributes:{ 'data-type':'taskItem' } }),
      Placeholder.configure({ placeholder:'Write a note, or type / to add a heading, list, or to-do…' }),
      Markdown.configure({ markedOptions:{ gfm:true } }),
    ],
    content:legacyDocument(''),
    ...options,
  })
}

export function openDocument(editor, json, plainText) {
  const content = json ? JSON.parse(json) : legacyDocument(plainText)
  // Validate before setContent so an unsupported document cannot be silently shortened.
  editor.schema.nodeFromJSON(content).check()
  editor.chain().setContent(content, { emitUpdate:false, errorOnInvalidContent:true }).setMeta('addToHistory',false).run()
}

export function snapshot(editor) {
  return { json:JSON.stringify(editor.getJSON()), markdown:editor.getMarkdown(), plainText:editor.getText({ blockSeparator:'\n' }) }
}
