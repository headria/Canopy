import { build } from 'esbuild'
import { readFile,writeFile,mkdir,copyFile,readdir } from 'node:fs/promises'
import { resolve,dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
const here=dirname(fileURLToPath(import.meta.url)),root=resolve(here,'..'),out=resolve(root,'Resources/NoteEditor')
await mkdir(out,{recursive:true})
await build({ entryPoints:[resolve(here,'src/editor.mjs')],bundle:true,format:'iife',outfile:resolve(out,'editor.js'),minify:true,target:'safari17',legalComments:'eof' })
for (const name of ['index.html','editor.css']) await copyFile(resolve(here,'src',name),resolve(out,name))
const lock=JSON.parse(await readFile(resolve(here,'package-lock.json'),'utf8'));let notices='Canopy note editor — third-party notices\n\n'
for (const [path,pkg] of Object.entries(lock.packages)) {
  if (!path || pkg.dev || pkg.optional) continue
  const folder=resolve(here,path)
  for (const file of await readdir(folder)) if (/^(licen[cs]e|copying)(\.|$)/i.test(file)) {
    notices+=`${path} ${pkg.version}\n${await readFile(resolve(folder,file),'utf8')}\n\n`
  }
}
await writeFile(resolve(out,'ThirdPartyNotices.txt'),notices)
const hash=async path=>createHash('sha256').update(await readFile(path)).digest('hex')
const sources=['build.mjs','package.json','package-lock.json','src/editor.mjs','src/document.mjs','src/index.html','src/editor.css']
const manifest={ version:1, sources:{},outputs:{} }
for(const name of sources) manifest.sources[`EditorWeb/${name}`]=await hash(resolve(here,name))
for(const name of ['index.html','editor.css','editor.js','ThirdPartyNotices.txt']) manifest.outputs[name]=await hash(resolve(out,name))
await writeFile(resolve(out,'manifest.json'),JSON.stringify(manifest,null,2)+'\n')
console.log('Built the offline Canopy note editor.')
