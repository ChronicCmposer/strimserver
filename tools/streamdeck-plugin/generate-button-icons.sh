
mkdir -p com.chroniccmposer.strimserver.sdPlugin/imgs/actions/egress
mkdir -p com.chroniccmposer.strimserver.sdPlugin/imgs/plugin

# ON — green, filled, on a dark tile
cat > com.chroniccmposer.strimserver.sdPlugin/imgs/actions/egress/on.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 72 72" width="72" height="72">
  <rect width="72" height="72" rx="14" fill="#17171a"/>
  <g fill="#33d17a">
    <circle cx="36" cy="24" r="4.5"/>
    <path d="M33 27 h6 l5 28 h-7 l-1.5-9 h-4 L30 55 h-7 z"/>
  </g>
  <g fill="none" stroke="#33d17a" stroke-width="3.5" stroke-linecap="round">
    <path d="M24 24 a17 17 0 0 1 24 0"/>
    <path d="M18 24 a25 25 0 0 1 36 0"/>
    <path d="M48 24 a17 17 0 0 0 -24 0"/>
    <path d="M54 24 a25 25 0 0 0 -36 0"/>
  </g>
</svg>
EOF

# OFF — grey, filled, no signal waves
cat > com.chroniccmposer.strimserver.sdPlugin/imgs/actions/egress/off.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 72 72" width="72" height="72">
  <rect width="72" height="72" rx="14" fill="#17171a"/>
  <g fill="#6b6b6b">
    <circle cx="36" cy="24" r="4.5"/>
    <path d="M33 27 h6 l5 28 h-7 l-1.5-9 h-4 L30 55 h-7 z"/>
  </g>
</svg>
EOF

# Action-list icon (20x20 intent) — small tower
cat > com.chroniccmposer.strimserver.sdPlugin/imgs/actions/egress/icon.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" width="20" height="20">
  <g fill="none" stroke="#ffffff" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
    <path d="M10 8 L6.5 16 M10 8 L13.5 16 M8 13 H12"/>
    <circle cx="10" cy="7" r="1.3" fill="#ffffff" stroke="none"/>
    <path d="M6 7 a5.5 5.5 0 0 1 8 0"/>
  </g>
</svg>
EOF

# Category icon (28x28 intent) — same mark
cat > com.chroniccmposer.strimserver.sdPlugin/imgs/plugin/category.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28" width="28" height="28">
  <g fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M14 11 L9 23 M14 11 L19 23 M11 19 H17"/>
    <circle cx="14" cy="9" r="1.8" fill="#ffffff" stroke="none"/>
    <path d="M8 9 a8 8 0 0 1 12 0"/>
  </g>
</svg>
EOF

# Plugin / marketplace icon (256x256) — mark on dark rounded square
cat > com.chroniccmposer.strimserver.sdPlugin/imgs/plugin/marketplace.svg <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
  <rect width="256" height="256" rx="56" fill="#17171a"/>
  <g fill="none" stroke="#ffffff" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">
    <path d="M128 104 L96 192 M128 104 L160 192 M110 168 H146"/>
    <circle cx="128" cy="92" r="11" fill="#ffffff" stroke="none"/>
    <path d="M96 92 a44 44 0 0 1 64 0"/>
    <path d="M78 92 a66 66 0 0 1 100 0"/>
  </g>
</svg>
EOF


cd com.chroniccmposer.strimserver.sdPlugin/imgs/actions/egress

for state in on off; do
  rsvg-convert -w 72  -h 72  "$state.svg" -o "$state.png"
  rsvg-convert -w 144 -h 144 "$state.svg" -o "$state@2x.png"
done

# action-list icon (20x20 + @2x) and category (28x28 + @2x)
rsvg-convert -w 20 -h 20 icon.svg -o icon.png
rsvg-convert -w 40 -h 40 icon.svg -o icon@2x.png

cd ../../plugin
rsvg-convert -w 28  -h 28  category.svg    -o category.png
rsvg-convert -w 56  -h 56  category@2x.svg -o category@2x.png 2>/dev/null \
  || rsvg-convert -w 56 -h 56 category.svg -o category@2x.png
rsvg-convert -w 256 -h 256 marketplace.svg -o marketplace.png
rsvg-convert -w 512 -h 512 marketplace.svg -o marketplace@2x.png

