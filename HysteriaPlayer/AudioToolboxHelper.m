//
//  ZVQAudioToolboxHelper.m
//  Zvooq
//
//  Created by User on 15/03/17.
//  Copyright © 2017 Dream Industries. All rights reserved.
//

#import "AudioToolboxHelper.h"

#include <stdlib.h>
#include <math.h>

#include <AudioToolbox/AudioQueue.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <CoreFoundation/CFRunLoop.h>

static int const NUM_CHANNELS = 1;
static int const NUM_BUFFERS = 1;
static int const BUFFER_SIZE = 1;
static int const SAMPLE_RATE = 1;

static unsigned int count;

void AudioToolboxHelperCallback(void *custom_data, AudioQueueRef queue, AudioQueueBufferRef buffer);

@implementation AudioToolboxHelper

+ (void)resetAudioQueue
{
    count = 0;
    unsigned int i;
    
    AudioStreamBasicDescription format;
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[NUM_BUFFERS];
    
    format.mSampleRate       = SAMPLE_RATE;
    format.mFormatID         = kAudioFormatLinearPCM;
    format.mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel   = 8 * sizeof(short);
    format.mChannelsPerFrame = NUM_CHANNELS;
    format.mBytesPerFrame    = sizeof(short) * NUM_CHANNELS;
    format.mFramesPerPacket  = 1;
    format.mBytesPerPacket   = format.mBytesPerFrame * format.mFramesPerPacket;
    format.mReserved         = 0;
    
    OSStatus err = AudioQueueNewOutput(&format, ZVQAudioToolboxHelperCallback, NULL, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &queue);
    
    for (i = 0; i < NUM_BUFFERS; i++)
    {
        AudioQueueAllocateBuffer(queue, BUFFER_SIZE, &buffers[i]);
        
        buffers[i]->mAudioDataByteSize = BUFFER_SIZE;
        
        ZVQAudioToolboxHelperCallback(NULL, queue, buffers[i]);
    }
    
    err = AudioQueueStart(queue, NULL);
    err = AudioQueueStop(queue, NO);
}

void AudioToolboxHelperCallback(void *custom_data, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
}

@end
