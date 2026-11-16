#!/bin/zsh
# APS1115A01: 홍보 영상(App Store 밖, 1080x1920 30fps). 일레븐랩스 생성 장면 + 스크린샷 + 음악.
# 사용: promo.sh <출력 mp4>   (design/APS1115A01 안에서 실행)
set -e
out=$1; tmp=$(mktemp -d); bg=0xC76D86
clip() { ffmpeg -nostdin -loglevel error -y -i "$1" -t $2 -vf "scale=1080:1920,fps=30,format=yuv420p" -an -c:v libx264 -crf 17 "$3"; }
shot() { ffmpeg -nostdin -loglevel error -y -loop 1 -t $2 -i "$1" -vf "scale=-2:1920,pad=1080:1920:(ow-iw)/2:0:color=$bg,zoompan=z='1+0.0006*on':d=1:s=1080x1920:fps=30,format=yuv420p" -c:v libx264 -crf 17 "$3"; }
clip source/promo-clips/promo-map.mp4 5 $tmp/a.mp4
mid=(); for f in output/iphone/0[1-5]-*.png(N); do shot $f 2.4 $tmp/${f:t:r}.mp4; mid+=($tmp/${f:t:r}.mp4); done
clip source/promo-clips/promo-travel.mp4 5 $tmp/b.mp4
shot output/iphone/06-stamp.png 2.4 $tmp/s9.mp4
clip source/promo-clips/promo-stamp.mp4 5 $tmp/c.mp4
list=($tmp/a.mp4 ${mid[1,3]} $tmp/b.mp4 ${mid[4,-1]} $tmp/s9.mp4 $tmp/c.mp4)
for f in $list; do echo "file '$f'"; done > $tmp/list.txt
ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i $tmp/list.txt -c copy $tmp/v.mp4
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 $tmp/v.mp4)
ffmpeg -nostdin -loglevel error -y -i $tmp/v.mp4 -stream_loop -1 -i source/music/cozy-little-lift.m4a \
  -filter_complex "[1:a]atrim=0:$dur,afade=t=in:d=0.5,afade=t=out:st=$(echo "$dur - 1.5" | bc):d=1.5,loudnorm=I=-14:TP=-1.5[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -movflags +faststart -shortest "$out"
rm -rf $tmp
echo "$out $dur s"
