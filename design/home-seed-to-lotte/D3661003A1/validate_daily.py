#!/usr/bin/env python3
from pathlib import Path
import argparse,json,hashlib,xml.etree.ElementTree as ET
from PIL import Image
import numpy as np
ROOT=Path(__file__).resolve().parent

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);args=p.parse_args()
    m=json.loads((ROOT/'manifest.json').read_text());entries=m['entries'];total=m['assetCount'];assert len(entries)==total
    svg_hashes=[];png_hashes=[];small=[];alphas=[]
    for x in entries:
        svg=ROOT/x['svg'];png=ROOT/x['png'];ET.parse(svg);svg_hashes.append(hashlib.sha256(svg.read_bytes()).hexdigest());im=Image.open(png)
        assert im.mode=='RGBA' and im.size==(512,512)
        assert im.getchannel('A').getextrema()==(0,255)
        assert all(im.getpixel(p)[3]==0 for p in [(0,0),(511,0),(0,511),(511,511)])
        png_hashes.append(hashlib.sha256(im.tobytes()).hexdigest())
        ar=np.asarray(im.resize((48,48),Image.Resampling.LANCZOS),dtype=np.int32)
        # Ignore the hidden RGB of fully transparent pixels in visual differences.
        ar[:,:,:3]=ar[:,:,:3]*ar[:,:,3:4]//255
        small.append(ar)
    pairs=[]
    for prev,cur,pa,ca in zip(entries,entries[1:],small,small[1:]):
        pixels=int(np.count_nonzero(np.max(np.abs(pa-ca),axis=2)>35))
        silhouette=int(np.count_nonzero(np.abs(pa[:,:,3]-ca[:,:,3])>40))
        pairs.append({'fromDay':prev['day'],'toDay':cur['day'],'sameStage':prev['stage']==cur['stage'],'changedPixels48':pixels,'silhouettePixels48':silhouette})
    unique_svg=len(set(svg_hashes));unique_png=len(set(png_hashes))
    report={'requestID':'D3661003A1','assetCount':total,'svgCount':len(list((ROOT/'daily').glob('*.svg'))),'pngCount':len(list((ROOT/'daily').glob('*.png'))),'uniqueSVG':unique_svg,'uniqueDecodedPNG':unique_png,'allTransparent':True,'allRGBA512':True,'daysContinuous':[x['day'] for x in entries]==list(range(1,total+1)),'stagesCovered':len(set(x['stage'] for x in entries)),'stageLengthSum':sum(m['stageLengths']),'stageLengths':m['stageLengths'],'adjacentPairs':len(pairs),'minimumChangedPixels48':min(x['changedPixels48'] for x in pairs),'minimumSilhouettePixels48':min(x['silhouettePixels48'] for x in pairs),'weakPairs':[x for x in pairs if x['changedPixels48']<50],'pairs':pairs,'appIntegrated':False}
    out=Path(args.output);out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='pairs'},ensure_ascii=False))
    assert report['svgCount']==report['pngCount']==total
    assert unique_svg==unique_png==total
    assert report['daysContinuous'] and report['stagesCovered']==53
    assert not report['weakPairs'],'Need stronger daily visual changes'
if __name__=='__main__':main()
