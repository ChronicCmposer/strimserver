#!/usr/bin/env bash

# use this by running in bash the following:
#
# . bslib.sh && generate2160p


generate1080p() {

	ffmpeg \
	  -f lavfi -i "nullsrc=s=1920x1080:r=60,format=gbrp,geq=r='(26+5*(1-cos(2*PI*T/30)))*(1-Y/H)':g='(33+109*(1-cos(2*PI*T/30)))*(1-Y/H)':b='255*(1-Y/H)',format=p010le,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
	  -f lavfi -i "anullsrc=r=48000:cl=stereo" \
	  -c:v hevc_videotoolbox \
	  -b:v 40000k \
	  -allow_sw 0 \
	  -profile:v main10 \
	  -g 120 \
	  -bf 0 \
	  -constant_bit_rate true \
	  -spatial_aq 1 \
     -color_range tv \
     -color_primaries bt709 \
     -color_trc bt709 \
     -colorspace bt709 \
	  -c:a aac_at -ar 48000 -ac 2 -b:a 320k \
	  -shortest -t 30 \
	  -movflags +faststart \
	  ~/Downloads/strimserver-offline-1080p60.mp4
}

generate1440p() {

	ffmpeg \
	  -f lavfi -i "nullsrc=s=2560x1440:r=60,format=gbrp,geq=r='(26+5*(1-cos(2*PI*T/30)))*(1-Y/H)':g='(33+109*(1-cos(2*PI*T/30)))*(1-Y/H)':b='255*(1-Y/H)',format=p010le,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
	  -f lavfi -i "anullsrc=r=48000:cl=stereo" \
	  -c:v hevc_videotoolbox \
	  -b:v 40000k \
	  -allow_sw 0 \
	  -profile:v main10 \
	  -g 120 \
	  -bf 0 \
	  -constant_bit_rate true \
	  -spatial_aq 1 \
     -color_range tv \
     -color_primaries bt709 \
     -color_trc bt709 \
     -colorspace bt709 \
	  -c:a aac_at -ar 48000 -ac 2 -b:a 320k \
	  -shortest -t 30 \
	  -movflags +faststart \
	  ~/Downloads/strimserver-offline-1440p60.mp4
}


generate2160p() {

	ffmpeg \
	  -f lavfi -i "nullsrc=s=3840x2160:r=60,format=gbrp,geq=r='(26+5*(1-cos(2*PI*T/30)))*(1-Y/H)':g='(33+109*(1-cos(2*PI*T/30)))*(1-Y/H)':b='255*(1-Y/H)',format=p010le,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
	  -f lavfi -i "anullsrc=r=48000:cl=stereo" \
	  -c:v hevc_videotoolbox \
	  -b:v 40000k \
	  -allow_sw 0 \
	  -profile:v main10 \
	  -g 120 \
	  -bf 0 \
	  -constant_bit_rate true \
	  -spatial_aq 1 \
     -color_range tv \
     -color_primaries bt709 \
     -color_trc bt709 \
     -colorspace bt709 \
	  -c:a aac_at -ar 48000 -ac 2 -b:a 320k \
	  -shortest -t 30 \
	  -movflags +faststart \
	  ~/Downloads/strimserver-offline-2160p60.mp4
}
