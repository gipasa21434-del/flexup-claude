#!/usr/bin/env bash
# Generates FLEX UP demo videos 100% synthetically with FFmpeg built-in sources (lavfi).
# No third-party footage or music is used, so the output is free of licensing issues.
# Output: FlexUp/Resources/DemoMedia/*.mp4 + *_thumb.jpg (540x960, H.264 + AAC, ~8 s).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=FlexUp/Resources/DemoMedia
mkdir -p "$OUT"
FONT=$(fc-match -f '%{file}' 'DejaVu Sans:bold' 2>/dev/null || echo /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf)
W=540; H=960; D=8; FPS=30

# $1 name, $2 video filtergraph producing [v], $3 audio expression (aevalsrc), $4 caption
make() {
  local name=$1 vf=$2 aexpr=$3 caption=$4
  if [[ -n "${ONLY:-}" && " ${ONLY} " != *" ${name} "* ]]; then return; fi
  ffmpeg -hide_banner -loglevel error -y \
    -filter_complex "${vf},format=yuv420p,drawtext=fontfile=${FONT}:text='${caption}':fontcolor=white@0.85:fontsize=34:x=(w-text_w)/2:y=h*0.16:shadowcolor=black@0.6:shadowx=2:shadowy=2,drawtext=fontfile=${FONT}:text='FLEX UP DEMO':fontcolor=white@0.55:fontsize=22:x=(w-text_w)/2:y=h-90[v];aevalsrc='${aexpr}':s=44100:d=${D},volume=0.35,afade=t=in:d=0.4,afade=t=out:st=$((D-1)):d=1[a]" \
    -map "[v]" -map "[a]" -t $D -r $FPS -c:v libx264 -profile:v high -preset slow -crf "${CRF:-30}" -pix_fmt yuv420p \
    -g $FPS -movflags +faststart -c:a aac -b:a 64k "$OUT/$name.mp4"
  ffmpeg -hide_banner -loglevel error -y -ss 2 -i "$OUT/$name.mp4" -frames:v 1 -q:v 5 -vf scale=270:480 "$OUT/${name}_thumb.jpg"
  echo "✓ $name ($(du -h "$OUT/$name.mp4" | cut -f1))"
}

# Simple synthesized "music": chords with a pulsing envelope.
PULSE='0.5*sin(2*PI*110*t)*(0.5+0.5*sin(2*PI*4*t))+0.3*sin(2*PI*220*t)+0.2*sin(2*PI*330*t)*gt(mod(t,0.5),0.25)'
CALM='0.4*sin(2*PI*174.6*t)*(0.6+0.4*sin(2*PI*0.25*t))+0.3*sin(2*PI*261.6*t)+0.2*sin(2*PI*392*t)'
FUN='0.5*sin(2*PI*(440+220*sin(2*PI*2*t))*t)*gt(mod(t,0.25),0.12)+0.2*sin(2*PI*110*t)'
COZY='0.35*sin(2*PI*196*t)+0.3*sin(2*PI*246.9*t)*(0.7+0.3*sin(2*PI*0.5*t))+0.2*sin(2*PI*293.7*t)+0.05*(random(0)-0.5)'
ART='0.4*sin(2*PI*329.6*t)*(0.5+0.5*sin(2*PI*0.5*t))+0.3*sin(2*PI*493.9*t)+0.2*sin(2*PI*659.3*t)*(0.5+0.5*cos(2*PI*1*t))'

make demo_neon "gradients=s=${W}x${H}:c0=0x8A2BFF:c1=0x19E3D1:c2=0x0E0F13:c3=0xF43F5E:nb_colors=4:speed=0.04:duration=${D}:rate=${FPS},hue=H=2*PI*t/4" "$PULSE" "Утренний разгон"
make demo_ocean "gradients=s=${W}x${H}:c0=0x0B3D91:c1=0x19E3D1:c2=0x0E0F13:nb_colors=3:speed=0.008:duration=${D}:rate=${FPS},gblur=sigma=8" "$CALM" "Дыши"
make demo_fractal "mandelbrot=s=${W}x${H}:rate=${FPS}:start_scale=3:end_scale=0.05:end_pts=${D}*${FPS}:outer=normalized_iteration_count,hue=H=t/2" "$ART" "Бесконечность"
make demo_life "life=s=135x240:rate=${FPS}:mold=10:life_color=0x19E3D1:death_color=0x8A2BFF:mold_color=0x1A1033:ratio=0.3,scale=${W}:${H}:flags=neighbor" "$FUN" "Мы и друзья"
make demo_cozy "gradients=s=${W}x${H}:c0=0xB45309:c1=0xF59E0B:c2=0x2A160A:nb_colors=3:speed=0.01:duration=${D}:rate=${FPS},noise=alls=5,vignette=PI/4" "$COZY" "Тёплый вечер"
make demo_pulse "color=c=0x0E0F13:s=${W}x${H}:r=${FPS}:d=${D},geq=r='128+127*sin(hypot(X-W/2,Y-H/2)/18-T*8)':g='40+30*sin(T*3)':b='200+55*cos(hypot(X-W/2,Y-H/2)/18-T*8)'" "$PULSE" "Ритм 128"
make demo_sunset "gradients=s=${W}x${H}:c0=0xF97316:c1=0xEC4899:c2=0x6D28D9:c3=0x0E0F13:nb_colors=4:speed=0.006:duration=${D}:rate=${FPS},gblur=sigma=4" "$CALM" "Золотой час"
make demo_spiral "color=c=black:s=${W}x${H}:r=${FPS}:d=${D},geq=r='128+127*sin(atan2(Y-H/2,X-W/2)*6+hypot(X-W/2,Y-H/2)/20-T*6)':g='128+127*sin(atan2(Y-H/2,X-W/2)*6+hypot(X-W/2,Y-H/2)/20-T*6+2)':b='160'" "$FUN" "Не моргай"
make demo_matrix "cellauto=s=${W}x${H}:rule=110:rate=${FPS}:random_fill_ratio=0.5,colorchannelmixer=rr=0.5:gg=0.1:bb=1.0,hue=H=t" "$ART" "Сигнал"
make demo_rain "color=c=0x101828:s=${W}x${H}:r=${FPS}:d=${D},geq=lum='40+150*gt(sin(X*0.37)*sin(Y*0.05+T*14+X*1.3),0.985)':cb=150:cr=120,gblur=sigma=1.2,vignette" "$COZY" "Дождь за окном"
echo "Done. Total: $(du -sh "$OUT" | cut -f1)"
