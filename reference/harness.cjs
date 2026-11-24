const fs=require('fs'),vm=require('vm');
const file=process.argv[2];
const html=fs.readFileSync(file,'utf8');
const script=html.match(/<script>([\s\S]*)<\/script>/)[1];
const els={};
function mk(id){
  const e={id,innerHTML:'',value:'',textContent:'',hidden:false,checked:false,dataset:{},style:{},
    classList:{add(){},remove(){},toggle(){},contains(){return false}},
    addEventListener(){},removeEventListener(){},insertAdjacentHTML(){},appendChild(){},remove(){},focus(){},select(){},
    querySelector(){return mk('q')},querySelectorAll(){return []},closest(){return null},setAttribute(){},getAttribute(){return null}};
  return e;
}
const document={getElementById(id){return els[id]||(els[id]=mk(id))},querySelector(){return mk('q')},querySelectorAll(){return []},
  createElement(){return mk('c')},body:mk('body'),addEventListener(){},execCommand(){return true}};
const store={};
const ctx={document,window:{},localStorage:{getItem:k=>store[k]??null,setItem:(k,v)=>{store[k]=v},removeItem:k=>{delete store[k]}},
  console,setTimeout:()=>0,clearTimeout(){},navigator:{clipboard:{writeText:()=>Promise.resolve()}},alert(){},confirm:()=>true,Date,Math,JSON,Number,String,Array,Object,Intl};
ctx.window=ctx;
vm.createContext(ctx);
vm.runInContext(script,ctx);
global.run=(code)=>vm.runInContext(code,ctx);
global.els=els;
module.exports={run:global.run,els};
