//
//  OGVDecoder.m
//  OgvDemo
//
//  Created by Brion on 11/2/13.
//  Copyright (c) 2013 Brion Vibber. All rights reserved.
//

#import "OGVDecoder.h"

#define OV_EXCLUDE_STATIC_CALLBACKS
#include <ogg/ogg.h>
#include <vorbis/vorbisfile.h>
#include <theora/theoradec.h>

@implementation OGVDecoder {
    /* Ogg and codec state for demux/decode */
    ogg_sync_state    oggSyncState;
    ogg_page          oggPage;
    
    /* Video decode state */
    ogg_stream_state  theoraStreamState;
    th_info           theoraInfo;
    th_comment        theoraComment;
    th_setup_info    *theoraSetupInfo;
    th_dec_ctx       *theoraDecoderContext;
    
    int              theora_p;
    int              theora_processing_headers;
    
    /* single frame video buffering */
    int          videobuf_ready;
    ogg_int64_t  videobuf_granulepos;
    double       videobuf_time;
    
    int          audiobuf_ready;
    ogg_int64_t  audiobuf_granulepos; /* time position of last sample */
    
    int          raw;
    
    /* Audio decode state */
    int              vorbis_p;
    int              vorbis_processing_headers;
    ogg_stream_state vo;
    vorbis_info      vi;
    vorbis_dsp_state vd;
    vorbis_block     vb;
    vorbis_comment   vc;
    int          crop;

    ogg_packet oggPacket;
    
    int frames;
    
    enum AppState {
        STATE_BEGIN,
        STATE_HEADERS,
        STATE_DECODING
    } appState;
    int process_audio, process_video;
}


- (id)init
{
    self = [super init];
    if (self) {
        self.dataReady = NO;
        
        appState = STATE_BEGIN;
        
        /* start up Ogg stream synchronization layer */
        ogg_sync_init(&oggSyncState);
        
        /* init supporting Vorbis structures needed in header parsing */
        vorbis_info_init(&vi);
        vorbis_comment_init(&vc);
        
        /* init supporting Theora structures needed in header parsing */
        th_comment_init(&theoraComment);
        th_info_init(&theoraInfo);
        
        process_audio = 1;
        process_video = 1;
    }
    return self;
}


- (void) processBegin
{
	if (ogg_page_bos(&oggPage)) {
		int got_packet;
        
		// Initialize a stream state object...
		ogg_stream_state test;
		ogg_stream_init(&test,ogg_page_serialno(&oggPage));
		ogg_stream_pagein(&test, &oggPage);
        
		// Peek at the next packet, since th_decode_headerin() will otherwise
		// eat the first Theora video packet...
		got_packet = ogg_stream_packetpeek(&test, &oggPacket);
		if (!got_packet) {
			return;
		}
        
		/* identify the codec: try theora */
		if(process_video && !theora_p && (theora_processing_headers = th_decode_headerin(&theoraInfo,&theoraComment,&theoraSetupInfo,&oggPacket))>=0){
            
			/* it is theora -- save this stream state */
			memcpy(&theoraStreamState, &test, sizeof(test));
			theora_p = 1;
			
			if (theora_processing_headers == 0) {
				// Saving first video packet for later!
			} else {
				ogg_stream_packetout(&theoraStreamState, NULL);
			}
		} else if (process_audio && !vorbis_p && (vorbis_processing_headers = vorbis_synthesis_headerin(&vi,&vc,&oggPacket)) == 0) {
			// it's vorbis!
			// save this as our audio stream...
			memcpy(&vo, &test, sizeof(test));
			vorbis_p = 1;
			
			// ditch the processed packet...
			ogg_stream_packetout(&vo, NULL);
		} else {
			/* whatever it is, we don't care about it */
			ogg_stream_clear(&test);
		}
	} else {
		// Not a bitstream start -- move on to header decoding...
		appState = STATE_HEADERS;
	}
}

- (void) processHeaders
{
	if ((theora_p && theora_processing_headers) || (vorbis_p && vorbis_p < 3)) {
		int ret;
        
		/* look for further theora headers */
		if (theora_p && theora_processing_headers) {
			ret = ogg_stream_packetpeek(&theoraStreamState, &oggPacket);
			if (ret < 0) {
				NSLog(@"Error reading theora headers: %d.", ret);
				exit(1);
			}
			if (ret > 0) {
				theora_processing_headers = th_decode_headerin(&theoraInfo, &theoraComment, &theoraSetupInfo, &oggPacket);
				if (theora_processing_headers == 0) {
                    // We've completed the theora header
                    theora_p = 3;
				} else {
					ogg_stream_packetout(&theoraStreamState, NULL);
				}
			}
		}
		
		if (vorbis_p && (vorbis_p < 3)) {
			ret = ogg_stream_packetpeek(&vo, &oggPacket);
			if (ret < 0) {
				NSLog(@"Error reading vorbis headers: %d.", ret);
				exit(1);
			}
			if (ret > 0) {
				vorbis_processing_headers = vorbis_synthesis_headerin(&vi, &vc, &oggPacket);
				if (vorbis_processing_headers == 0) {
					vorbis_p++;
				} else {
					NSLog(@"Invalid vorbis header?");
					exit(1);
				}
				ogg_stream_packetout(&vo, NULL);
			}
		}
    } else {
        /* and now we have it all.  initialize decoders */
        if(theora_p){
            theoraDecoderContext=th_decode_alloc(&theoraInfo,theoraSetupInfo);
            
            self.hasVideo = YES;
			self.frameWidth = theoraInfo.frame_width;
            self.frameHeight = theoraInfo.frame_height;
            self.frameRate = (float)theoraInfo.fps_numerator / theoraInfo.fps_denominator;
            self.pictureWidth = theoraInfo.pic_width;
            self.pictureHeight = theoraInfo.pic_height;
            self.pictureOffsetX = theoraInfo.pic_x;
            self.pictureOffsetY = theoraInfo.pic_y;
            self.hDecimation = !(theoraInfo.pixel_fmt & 1);
            self.vDecimation = !(theoraInfo.pixel_fmt & 2);
        }
        
		if (vorbis_p) {
			vorbis_synthesis_init(&vd,&vi);
			vorbis_block_init(&vd,&vb);
			
            self.hasAudio = YES;
            self.audioChannels = vi.channels;
            self.audioRate = vi.rate;
		}
        
        appState = STATE_DECODING;
        self.dataReady = YES;
	}
}

- (void)processDecoding
{
	if (theora_p) {
		// fixme -- don't decode next frame until the time is right
		if(!videobuf_ready){
            /* theora is one in, one out... */
            if (ogg_stream_packetout(&theoraStreamState, &oggPacket) > 0 ){
                
                if (th_decode_packetin(theoraDecoderContext,&oggPacket,&videobuf_granulepos)>=0){
                    videobuf_time=th_granule_time(theoraDecoderContext,videobuf_granulepos);
                    videobuf_ready=1;
                    frames++;
                }
                
            }
		}
        
		if(videobuf_ready){
			/* dumpvideo frame, and get new one */
            th_ycbcr_buffer ycbcr;
            th_decode_ycbcr_out(theoraDecoderContext,ycbcr);
            
            if (self.onframe) {
                OGVFrameBuffer buffer;
                buffer.YData = ycbcr[0].data;
                buffer.CbData = ycbcr[1].data;
                buffer.CrData = ycbcr[2].data;
                buffer.YStride = ycbcr[0].stride;
                buffer.CbStride = ycbcr[1].stride;
                buffer.CrStride = ycbcr[2].stride;
                self.onframe(buffer);
            }
			videobuf_ready=0;
		}
	}
	
	if (vorbis_p) {
		while (ogg_stream_packetout(&vo, &oggPacket) > 0) {
			if(vorbis_synthesis(&vb, &oggPacket)==0) {
				vorbis_synthesis_blockin(&vd,&vb);
                
				// fixme -- timing etc!
                OGVAudioBuffer buffer;
				buffer.sampleCount = vorbis_synthesis_pcmout(&vd, &buffer.pcm);
                if (self.onaudio) {
                    self.onaudio(buffer);
                }
				vorbis_synthesis_read(&vd, buffer.sampleCount);
			}
		}
	}
}

- (void)receiveInput:(NSData *)data
{
    char *buffer = (char *)data.bytes;
    size_t bufsize = data.length;
	if (bufsize > 0) {
		char *dest = ogg_sync_buffer(&oggSyncState, bufsize);
		memcpy(dest, buffer, bufsize);
		ogg_sync_wrote(&oggSyncState, bufsize);
	}
}

- (BOOL)process
{
	if (ogg_sync_pageout(&oggSyncState, &oggPage) > 0) {
        if (theora_p) {
            ogg_stream_pagein(&theoraStreamState, &oggPage);
        }
        if (vorbis_p) {
            ogg_stream_pagein(&vo, &oggPage);
        }
		if (appState == STATE_BEGIN) {
			[self processBegin];
		} else if (appState == STATE_HEADERS) {
			[self processHeaders];
		} else if (appState == STATE_DECODING) {
			[self processDecoding];
		}
		return 1;
	}
	return 0;
}


- (void)dealloc
{
    if(theora_p){
        ogg_stream_clear(&theoraStreamState);
        th_decode_free(theoraDecoderContext);
        th_comment_clear(&theoraComment);
        th_info_clear(&theoraInfo);
    }
    // fixme free the vorbis state too
    ogg_sync_clear(&oggSyncState);
}

@end