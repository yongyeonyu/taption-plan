#!/bin/zsh
# APS1115A01: App Store 앱 미리보기 영상(iPhone 6.9형, 886x1920, 30fps, H.264, 30초 이하).
# 앱 화면 녹화(rec-*.mp4)만 이어 붙이고 일레븐랩스 음악을 입힌다. Apple 규정상 앱 밖의 장면은 넣지 않는다.
# 시뮬레이터 녹화는 화면이 바뀔 때만 프레임이 있어 끝을 마지막 프레임으로 채운다.
# 사용: preview.sh <녹화 폴더> <음악 wav> <출력 mp4>   (녹화 폴더의 clips.txt: "파일 시작초 길이" 한 줄에 하나)
set -e
src=$1; music=$2; out=$3
tmp=$(mktemp -d)
i=0; inputs=(); filters=""; total=0
while read -r file start len; do
  [[ -z $file || $file == \#* ]] && continue
  ffmpeg -nostdin -loglevel error -y -ss $start -t $len -i "$src/$file" \
    -vf "scale=886:-2,crop=886:1920:0:(ih-1920)/2,fps=30,tpad=stop_mode=clone:stop_duration=$len,setpts=N/30/TB,format=yuv420p" -t $len -r 30 -video_track_timescale 30000 -an -c:v libx264 -crf 16 "$tmp/$i.mp4"
  inputs+=(-i "$tmp/$i.mp4"); i=$((i+1)); total=$(echo "$total + $len" | bc)
done < "$src/clips.txt"
# 장면 사이 0.4초 겹쳐 잇기
fade=0.4; acc=0; prev="0:v"; n=$i
for ((k=1; k<n; k++)); do
  len_prev=$(sed -n "$((k))p" <(grep -v '^#' "$src/clips.txt" | awk 'NF'))
  acc=$(echo "$acc + $(echo $len_prev | awk '{print $3}') - $fade" | bc)
  filters+="[$prev][${k}:v]xfade=transition=fade:duration=$fade:offset=${acc}[v$k];"
  prev="v$k"
done
dur=$(echo "$total - ($n - 1) * $fade" | bc)
ffmpeg -nostdin -loglevel error -y "${inputs[@]}" -i "$music" \
  -filter_complex "${filters}[$prev]null[vout];[${n}:a]atrim=0:$dur,afade=t=out:st=$(echo "$dur - 1.5" | bc):d=1.5,loudnorm=I=-16:TP=-1.5,aresample=44100[aout]" \
  -map "[vout]" -map "[aout]" -c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p -r 30 -b:v 10M -maxrate 12M -bufsize 20M \
  -c:a aac -b:a 256k -ac 2 -movflags +faststart -t $dur "$out"
rm -rf "$tmp"
echo "$out $dur s"
