#!/usr/bin/env python3
from pathlib import Path
import argparse, hashlib, json, xml.etree.ElementTree as ET
from PIL import Image
import numpy as np

ROOT=Path(__file__).resolve().parent


def delta(pa,ca):
    pixels=int(np.count_nonzero(np.max(np.abs(pa-ca),axis=2)>35))
    silhouette=int(np.count_nonzero(np.abs(pa[:,:,3]-ca[:,:,3])>40))
    return pixels,silhouette


def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);args=p.parse_args()
    m=json.loads((ROOT/'manifest.json').read_text());entries=m['entries'];stages=m['stages']
    svg_hashes=[];png_hashes=[];small=[];edge_issues=[]
    for e in entries:
        svg=ROOT/e['svg'];png=ROOT/e['png'];ET.parse(svg)
        svg_hashes.append(hashlib.sha256(svg.read_bytes()).hexdigest())
        im=Image.open(png);assert im.mode=='RGBA' and im.size==(512,512)
        alpha=im.getchannel('A');assert alpha.getextrema()==(0,255)
        pixels=np.asarray(im)
        if any(np.any(edge) for edge in [pixels[0,:,3],pixels[-1,:,3],pixels[:,0,3],pixels[:,-1,3]]):edge_issues.append(e['day'])
        png_hashes.append(hashlib.sha256(im.tobytes()).hexdigest())
        ar=np.asarray(im.resize((48,48),Image.Resampling.LANCZOS),dtype=np.int32)
        ar[:,:,:3]=ar[:,:,:3]*ar[:,:,3:4]//255
        small.append(ar)
    pairs=[]
    for prev,cur,pa,ca in zip(entries,entries[1:],small,small[1:]):
        pixels,silhouette=delta(pa,ca)
        pairs.append({'fromDay':prev['day'],'toDay':cur['day'],'sameStage':prev['stage']==cur['stage'],'changedPixels48':pixels,'silhouettePixels48':silhouette})
    boundary=[p for p in pairs if not p['sameStage']]
    completed=[]
    for i,pa in enumerate(small[2::3]):
        for j,ca in enumerate(small[2::3][i+1:],i+1):
            pixels,silhouette=delta(pa,ca)
            completed.append({'stageA':i+1,'stageB':j+1,'changedPixels48':pixels,'silhouettePixels48':silhouette})
    years=[s['year'] for s in stages if s['year'] is not None]
    stage_mapping=all([x['detail'] for x in entries if x['stage']==s['stage']]==[1,2,3] and s['dayStart']==(s['stage']-1)*3+1 and s['dayEnd']==s['stage']*3 for s in stages)
    report={'requestID':'D3X61003A1','assetCount':len(entries),'svgCount':len(list((ROOT/'daily').glob('*.svg'))),'pngCount':len(list((ROOT/'daily').glob('*.png'))),'uniqueSVG':len(set(svg_hashes)),'uniqueDecodedPNG':len(set(png_hashes)),'uniqueDecoded48':len(set(hashlib.sha256(x.tobytes()).hexdigest() for x in small)),'allTransparent':True,'allRGBA512':True,'edgeClippingDays':edge_issues,'daysContinuous':[e['day'] for e in entries]==list(range(1,367)),'stageCount':len(stages),'uniqueStageNames':len(set(s['name'] for s in stages)),'everyStageThreeDays':stage_mapping,'representativeYearsSorted':years==sorted(years),'natureCampingCount':sum(s['year'] is None for s in stages),'worldArchitectureCount':sum(s['year'] is not None for s in stages),'adjacentPairs':len(pairs),'stageBoundaries':len(boundary),'minimumDailyChangedPixels48':min(p['changedPixels48'] for p in pairs),'minimumBoundaryChangedPixels48':min(p['changedPixels48'] for p in boundary),'minimumBoundarySilhouettePixels48':min(p['silhouettePixels48'] for p in boundary),'weakDailyPairs':[p for p in pairs if p['changedPixels48']<50],'weakBoundaryPairs':[p for p in boundary if p['changedPixels48']<200],'completeSubjectPairsCompared':len(completed),'identicalCompletedSubjects48':[p for p in completed if p['changedPixels48']==0],'closestCompletedSubjects48':sorted(completed,key=lambda p:p['changedPixels48'])[:12],'pairs':pairs,'appIntegrated':False,'differencePolicy':'RGBA int32 premultiplication before comparing; 48px max-channel delta >35. Daily minimum50; three-day subject boundary minimum200. Pixel checks support, and do not replace, visual review.'}
    out=Path(args.output);out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='pairs'},ensure_ascii=False))
    assert report['assetCount']==report['svgCount']==report['pngCount']==366
    assert report['uniqueSVG']==report['uniqueDecodedPNG']==report['uniqueDecoded48']==366
    assert report['daysContinuous'] and report['stageCount']==122 and report['uniqueStageNames']==122 and stage_mapping
    assert report['representativeYearsSorted'] and not edge_issues
    assert not report['weakDailyPairs'],'Need stronger changes inside the subject'
    assert not report['weakBoundaryPairs'],'Need stronger change of building every three days'


if __name__=='__main__':main()
