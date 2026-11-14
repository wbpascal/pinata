"""Instruction-level compare of same-name functions: WM vs Login / Zone 2016 exes (S02 §1.9, §2.7).
Usage: python3 -I tools/protocol-re/asmcmp.py <Class,Class…> [<login-pdb|zone-pdb> <Class::Fn,…>]
Prints functions whose normalised objdump differs (ratio < 1) or exist in one build only; with the 2nd form also
the unified diff. Diffs after the final ret are inline jump tables (data), not code."""
import re,subprocess,sys,difflib
E='re-data/exports'
EXE={'wm-pdb':'Files/Server/2016/w00_WorldManager/4WorldManagerServer2.exe','login-pdb':'Files/Server/2016/Login/3LoginServer2.exe','zone-pdb':'Files/Server/2016/w00_Zone00/5ZoneServer2.exe'}
cls=sys.argv[1].split(',')
def funcs(b):
    out=[];
    for l in open(f'{E}/{b}/decomp.c',encoding='utf-8',errors='replace'):
        if l.startswith('//==== FUNC '):
            p=l.split(); out.append((int(p[2],16),p[3]))
    out.sort(); res={}
    for i,(a,n) in enumerate(out):
        c=n.split('::')[0]
        if c in cls:
            key=n
            while key in res: key+="'"
            res[key]=(a,out[i+1][0])
    return res
def asm(b,a,e):
    t=subprocess.run(['objdump','-d','--no-show-raw-insn',f'--start-address={a}',f'--stop-address={e}',EXE[b]],capture_output=True,text=True).stdout.splitlines()
    r=[]
    for l in t:
        m=re.match(r'\s*[0-9a-f]+:\s+(.*)',l)
        if not m: continue
        s=m.group(1).split('#')[0].strip()
        if s=='int3' or not s: continue
        s=re.sub(r'0x[0-9a-f]{5,}','A',s); s=re.sub(r'<[^>]*>','',s)
        r.append(s)
    return r
W=funcs('wm-pdb')
for b in ('login-pdb','zone-pdb'):
    O=funcs(b)
    for n in sorted(set(W)|set(O)):
        if n not in W or n not in O: print(b,n,'ONLY', 'wm' if n in W else b, hex((W.get(n) or O.get(n))[0])); continue
        x=asm('wm-pdb',*W[n]); y=asm(b,*O[n])
        r=difflib.SequenceMatcher(None,x,y,autojunk=False).ratio()
        if r<1: print(b,n,hex(W[n][0]),hex(O[n][0]),len(x),len(y),round(r,3))
if len(sys.argv)>2:
    b=sys.argv[2]; O=funcs(b)
    for n in sys.argv[3].split(','):
        x=asm('wm-pdb',*W[n]); y=asm(b,*O[n])
        print('###',n)
        for l in difflib.unified_diff(x,y,lineterm='',n=1): print(l)
