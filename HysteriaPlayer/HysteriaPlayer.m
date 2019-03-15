//
//  HysteriaPlayer.m
//
//  Created by saiday on 13/1/8.
//
//

#import "HysteriaPlayer.h"
#import <objc/runtime.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioSession.h>
#import "AudioToolboxHelper.h"
#endif

static const NSTimeInterval HyseriaPlayerFinishedPlaybackStallingEpsilon = 1.;
static NSString *const HysteriaRefererHeaderKey = @"Referer"

typedef NS_ENUM(NSInteger, PauseReason) {
    PauseReasonNone,
    PauseReasonForced,
    PauseReasonBuffering,
};

@interface HysteriaPlayer ()
{
    BOOL routeChangedWhilePlaying;
    BOOL interruptedWhilePlaying;
    BOOL isPreBuffered;
    BOOL tookAudioFocus;
    
    NSInteger prepareingItemHash;
    
#if TARGET_OS_IPHONE
    UIBackgroundTaskIdentifier bgTaskId;
    UIBackgroundTaskIdentifier removedId;
#endif
}


@property (nonatomic, strong, readwrite) NSArray *playerItems;
@property (nonatomic, readwrite) BOOL emptySoundPlaying;
@property (nonatomic) NSInteger lastItemIndex;

@property (nonatomic) HysteriaPlayerRepeatMode repeatMode;
@property (nonatomic) HysteriaPlayerShuffleMode shuffleMode;
@property (nonatomic) HysteriaPlayerStatus hysteriaPlayerStatus;
@property (nonatomic) PauseReason pauseReason;
@property (nonatomic, strong) NSMutableSet *playedItems;

- (void)longTimeBufferBackground;
- (void)longTimeBufferBackgroundCompleted;

@end

@implementation HysteriaPlayer


static HysteriaPlayer *sharedInstance = nil;
static dispatch_once_t onceToken;

#pragma mark -
#pragma mark ===========  Initialization, Setup  =========
#pragma mark -

+ (HysteriaPlayer *)sharedInstance {
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

- (id)init {
    self = [super init];
    if (self) {
        _playerItems = [NSArray array];
        
        _repeatMode = HysteriaPlayerRepeatModeOff;
        _shuffleMode = HysteriaPlayerShuffleModeOff;
        _hysteriaPlayerStatus = HysteriaPlayerStatusUnknown;
    }
    
    return self;
}

- (void)preAction
{
    tookAudioFocus = YES;
    
    [AudioToolboxHelper resetAudioQueue];
    [self backgroundPlayable];
    [self createAudioPlayer];
    [self AVAudioSessionNotification];
}

- (void)registerHandlerReadyToPlay:(ReadyToPlay)readyToPlay{}

-(void)registerHandlerFailed:(Failed)failed {}

- (void)setupSourceGetter:(SourceSyncGetter)itemBlock ItemsCount:(NSInteger)count {}

- (void)asyncSetupSourceGetter:(SourceAsyncGetter)asyncBlock ItemsCount:(NSInteger)count{}

- (void)setItemsCount:(NSInteger)count {}

- (void)createAudioPlayer
{
    if (self.skipEmptySoundPlaying) {
        self.audioPlayer = [[AVQueuePlayer alloc] init];
    } else {
        //play .1 sec empty sound
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSString *filepath = [bundle pathForResource:@"point1sec" ofType:@"mp3"];
        if ([[NSFileManager defaultManager]fileExistsAtPath:filepath]) {
            self.emptySoundPlaying = YES;
            AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:filepath]];
            self.audioPlayer = [AVQueuePlayer queuePlayerWithItems:[NSArray arrayWithObject:playerItem]];
        }
    }
    
    _audioPlayer.actionAtItemEnd = AVPlayerActionAtItemEndPause; // This heals items mix-up when item duration < 1 sec.
    
    if ([_audioPlayer respondsToSelector:@selector(automaticallyWaitsToMinimizeStalling)]) {
        _audioPlayer.automaticallyWaitsToMinimizeStalling = NO;
    }
    
    [self.audioPlayer addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew context:nil];
    [self.audioPlayer addObserver:self forKeyPath:@"rate" options:0 context:nil];
    [self.audioPlayer addObserver:self forKeyPath:@"currentItem" options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];
}

- (void)backgroundPlayable
{
#if TARGET_OS_IPHONE
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    if (audioSession.category != AVAudioSessionCategoryPlayback) {
        UIDevice *device = [UIDevice currentDevice];
        if ([device respondsToSelector:@selector(isMultitaskingSupported)]) {
            if (device.multitaskingSupported) {
                
                NSError *aError = nil;
                [audioSession setCategory:AVAudioSessionCategoryPlayback error:&aError];
                if (aError) {
                    if (!self.disableLogs) {
                        NSLog(@"HysteriaPlayer: set category error:%@",[aError description]);
                    }
                }
                aError = nil;
                [audioSession setActive:YES error:&aError];
                if (aError) {
                    if (!self.disableLogs) {
                        NSLog(@"HysteriaPlayer: set active error:%@",[aError description]);
                    }
                }
            }
        }
    }else {
        if (!self.disableLogs) {
            NSLog(@"HysteriaPlayer: unable to register background playback");
        }
    }
    
    [self longTimeBufferBackground];
#endif
}


/*
 * Tells OS this application starts one or more long-running tasks, should end background task when completed.
 */
-(void)longTimeBufferBackground
{
#if TARGET_OS_IPHONE
    bgTaskId = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:removedId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];
    
    if (bgTaskId != UIBackgroundTaskInvalid && removedId == 0 ? YES : (removedId != UIBackgroundTaskInvalid)) {
        [[UIApplication sharedApplication] endBackgroundTask: removedId];
    }
    removedId = bgTaskId;
#endif
}

-(void)longTimeBufferBackgroundCompleted
{
#if TARGET_OS_IPHONE
    if (bgTaskId != UIBackgroundTaskInvalid && removedId != bgTaskId) {
        [[UIApplication sharedApplication] endBackgroundTask: bgTaskId];
        removedId = bgTaskId;
    }
#endif
}

#pragma mark -
#pragma mark ===========  AVAudioSession Notifications  =========
#pragma mark -

- (void)AVAudioSessionNotification
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemFailedToPlayEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemPlaybackStall:)
                                                 name:AVPlayerItemPlaybackStalledNotification
                                               object:nil];
    
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(interruption:)
                                                 name:AVAudioSessionInterruptionNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(routeChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
#endif
}

#pragma mark -
#pragma mark ===========  Player Methods  =========
#pragma mark -

- (void)willPlayPlayerItemAtIndex:(NSInteger)index
{
    if (!tookAudioFocus) {
        [self preAction];
    }
    self.lastItemIndex = index;
    [self.playedItems addObject:@(index)];
    
    if ([self.delegate respondsToSelector:@selector(hysteriaPlayerWillChangedAtIndex:)]) {
        [self.delegate hysteriaPlayerWillChangedAtIndex:self.lastItemIndex];
    }
}

- (void)fetchAndPlayPlayerItem:(NSInteger)startAt
{
    [self fetchAndPlayPlayerItem:startAt withOffset:0];
}

- (void)fetchAndPlayPlayerItem:(NSInteger)startAt withOffset:(NSTimeInterval)timeOffset
{
    [self willPlayPlayerItemAtIndex:startAt];
    
    if ([self isPlaying]) {
        [self.audioPlayer pause];
        [self.audioPlayer removeAllItems];
    }
    
    BOOL findInPlayerItems = NO;
    findInPlayerItems = [self findSourceInPlayerItems:startAt];
    
    if (!findInPlayerItems) {
        [self getSourceURLAtIndex:startAt preBuffer:NO withOffset:timeOffset];
    } else if (self.audioPlayer.currentItem.status == AVPlayerStatusReadyToPlay) {
        [self.audioPlayer play];
    }
}

- (NSInteger)hysteriaPlayerItemsCount
{
    if ([self.datasource respondsToSelector:@selector(hysteriaPlayerNumberOfItems)]) {
        return [self.datasource hysteriaPlayerNumberOfItems];
    }
    return self.itemsCount;
}

- (void)getSourceURLAtIndex:(NSInteger)index preBuffer:(BOOL)preBuffer withOffset:(NSTimeInterval)timeOffset
{
    NSAssert([self.datasource respondsToSelector:@selector(hysteriaPlayerURLForItemAtIndex:preBuffer:)] || [self.datasource respondsToSelector:@selector(hysteriaPlayerAsyncSetUrlForItemAtIndex:preBuffer:)], @"You didn't implement URL getter delegate from HysteriaPlayerDelegate, hysteriaPlayerURLForItemAtIndex:preBuffer: and hysteriaPlayerAsyncSetUrlForItemAtIndex:preBuffer: provides for the use of alternatives.");
    NSAssert([self hysteriaPlayerItemsCount] > index, ([NSString stringWithFormat:@"You are about to access index: %li URL when your HysteriaPlayer items count value is %li, please check hysteriaPlayerNumberOfItems or set itemsCount directly.", (unsigned long)index, (unsigned long)[self hysteriaPlayerItemsCount]]));
    
    NSURL *itemURL;
    
    if ([self.datasource respondsToSelector:@selector(hysteriaPlayerURLForItemAtIndex:preBuffer:)]) {
        itemURL = [self.datasource hysteriaPlayerURLForItemAtIndex:index preBuffer:preBuffer];
    }
    
    if (itemURL) {
        
        void(^setupPlayerBlock)() = ^() {
            [self setupPlayerItemWithUrl:itemURL index:index withOffset:timeOffset];
            if (!preBuffer) {
                [self play];
            }
        };
        
        if ([NSThread isMainThread]) {
            setupPlayerBlock();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                setupPlayerBlock();
            });
        }
        
        
    } else if ([self.datasource respondsToSelector:@selector(hysteriaPlayerAsyncSetUrlForItemAtIndex:preBuffer:)]) {
        [self.datasource hysteriaPlayerAsyncSetUrlForItemAtIndex:index preBuffer:preBuffer];
    } else {
        NSException *exception = [[NSException alloc] initWithName:@"HysteriaPlayer Error" reason:[NSString stringWithFormat:@"Cannot find item URL at index %li", (unsigned long)index] userInfo:nil];
        @throw exception;
    }
}

- (void)setupPlayerItemWithUrl:(NSURL *)url index:(NSInteger)index withOffset:(NSTimeInterval)timeOffset
{
    NSDictionary *requestHeaders = nil;
    if (url.baseURL) {
        requestHeaders = @{
            @"AVURLAssetHTTPHeaderFieldsKey": @{
                HysteriaRefererHeaderKey:url.baseURL
            }
        };
    }
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:url options:requestHeaders];
    HysteriaItem *item = [[HysteriaItem alloc] initWithAsset:asset index:index];
    
    if (self.isMemoryCached) {
        NSMutableArray *playerItems = [NSMutableArray arrayWithArray:self.playerItems];
        [playerItems addObject:item];
        self.playerItems = playerItems;
    }
    
    item.offsetTime = timeOffset;
    [self insertPlayerItem:item];
}

- (BOOL)findSourceInPlayerItems:(NSInteger)index
{
    for (HysteriaItem *item in self.playerItems) {
        NSInteger checkIndex = item.index;
        if (checkIndex == index) {
            if (item.status == AVPlayerItemStatusReadyToPlay) {
                [item seekToTime:kCMTimeZero completionHandler:^(BOOL finished) {
                    [self insertPlayerItem:item];
                }];
                return YES;
            }
        }
    }
    return NO;
}

- (void)insertPlayerItem:(HysteriaItem *)item
{
    if ([self.audioPlayer.items count] > 1) {
        for (int i = 1 ; i < [self.audioPlayer.items count] ; i ++) {
            HysteriaItem *item = [self.audioPlayer.items objectAtIndex:i];
            if (item != self.audioPlayer.currentItem) {
                @try {
                    [item removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
                    [item removeObserver:self forKeyPath:@"status" context:nil];
                } @catch(id anException) {
                }
            }
            [self.audioPlayer removeItem:item];
        }
    }
    
    HysteriaItem *lastItem = [self.audioPlayer.items lastObject];
    
    if ([self.audioPlayer canInsertItem:item afterItem:lastItem]) {
        [self.audioPlayer insertItem:item afterItem:lastItem];
    }
}

- (void)removeAllItems
{
    for (HysteriaItem *item in self.audioPlayer.items) {
        [item seekToTime:kCMTimeZero];
        if (item != self.audioPlayer.currentItem) {
            @try {
                [item removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
                [item removeObserver:self forKeyPath:@"status" context:nil];
            } @catch(id anException) {
            }
        }
    }
    
    self.playerItems = [self isMemoryCached] ? [NSArray array] : nil;
    [self.audioPlayer removeAllItems];
}

- (void)removeQueuesAtPlayer
{
    while (self.audioPlayer.items.count > 1) {
        HysteriaItem *item = [self.audioPlayer.items objectAtIndex:1];
        @try {
            [item removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
            [item removeObserver:self forKeyPath:@"status" context:nil];
        } @catch(id anException) {
        }
        [self.audioPlayer removeItem:item];
    }
}

- (void)removeItemAtIndex:(NSInteger)index
{
    if ([self isMemoryCached]) {
        for (HysteriaItem *item in [NSArray arrayWithArray:self.playerItems]) {
            NSInteger checkIndex = item.index;
            if (checkIndex == index) {
                NSMutableArray *playerItems = [NSMutableArray arrayWithArray:self.playerItems];
                [playerItems removeObject:item];
                self.playerItems = playerItems;
                
                if ([self.audioPlayer.items indexOfObject:item] != NSNotFound) {
                    if (item != self.audioPlayer.currentItem) {
                        @try {
                            [item removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
                            [item removeObserver:self forKeyPath:@"status" context:nil];
                        } @catch(id anException) {
                        }
                    }
                    [self.audioPlayer removeItem:item];
                }
            } else if (checkIndex > index) {
                item.index = checkIndex - 1;
            }
        }
    } else {
        for (HysteriaItem *item in self.audioPlayer.items) {
            NSInteger checkIndex = item.index;
            if (checkIndex == index) {
                [self.audioPlayer removeItem:item];
            } else if (checkIndex > index) {
                item.index = checkIndex - 1;
            }
        }
    }
}

- (void)moveItemFromIndex:(NSInteger)from toIndex:(NSInteger)to
{
    for (HysteriaItem *item in self.playerItems) {
        [self resetItemIndexIfNeeds:item fromIndex:from toIndex:to];
    }
    
    for (HysteriaItem *item in self.audioPlayer.items) {
        if ([self resetItemIndexIfNeeds:item fromIndex:from toIndex:to]) {
            [self removeQueuesAtPlayer];
        }
    }
}

- (BOOL)resetItemIndexIfNeeds:(HysteriaItem *)item fromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)destinationIndex
{
    NSInteger checkIndex = item.index;
    BOOL found = NO;
    NSInteger replaceOrder = 0;
    if (checkIndex == sourceIndex) {
        replaceOrder = destinationIndex;
        found = YES;
    } else if (checkIndex == destinationIndex) {
        replaceOrder = sourceIndex > checkIndex ? checkIndex + 1 : checkIndex - 1;
        found = YES;
    } else if (checkIndex > destinationIndex && checkIndex < sourceIndex) {
        replaceOrder = checkIndex + 1;
        found = YES;
    } else if (checkIndex < destinationIndex && checkIndex > sourceIndex) {
        replaceOrder = checkIndex - 1;
        found = YES;
    }
    
    if (found) {
        item.index = replaceOrder;
        if (self.lastItemIndex == checkIndex) {
            self.lastItemIndex = replaceOrder;
        }
    }
    return found;
}

- (void)seekToTime:(double)seconds
{
    [self.audioPlayer seekToTime:CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC)];
}

- (void)seekToTime:(double)seconds withCompletionBlock:(void (^)(BOOL))completionBlock
{
    [self.audioPlayer seekToTime:CMTimeMakeWithSeconds(seconds, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
        if (completionBlock) {
            completionBlock(finished);
        }
    }];
}

- (NSInteger)getLastItemIndex
{
    return self.lastItemIndex;
}

- (HysteriaItem *)getCurrentItem
{
    return [self.audioPlayer currentItem];
}

- (void)play
{
    _pauseReason = PauseReasonNone;
    
    if (self.audioPlayer.status != AVPlayerStatusReadyToPlay) {
        return;
    }
    
    HysteriaItem *currentItem = self.audioPlayer.currentItem;
    if (currentItem.offsetTime) {
        
        [self.audioPlayer seekToTime:CMTimeMakeWithSeconds(currentItem.offsetTime, NSEC_PER_SEC) completionHandler:^(BOOL finished) {
            currentItem.offsetTime = 0;
            [self.audioPlayer play];
        }];
        
    } else {
        [self.audioPlayer play];
    }
}

- (void)pause
{
    _pauseReason = PauseReasonForced;
    [self.audioPlayer pause];
}

- (void)playNext
{
    if (_shuffleMode == HysteriaPlayerShuffleModeOn) {
        NSInteger nextIndex = [self randomIndex];
        if (nextIndex != NSNotFound) {
            [self fetchAndPlayPlayerItem:nextIndex];
        } else {
            _pauseReason = PauseReasonForced;
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                [self.delegate hysteriaPlayerDidReachEnd];
            }
        }
    } else {
        HysteriaItem *item = self.audioPlayer.currentItem;
        NSInteger nowIndex = item ? item.index : self.lastItemIndex;
        if (nowIndex + 1 < [self hysteriaPlayerItemsCount]) {
            if (self.audioPlayer.items.count > 1) {
                [self willPlayPlayerItemAtIndex:nowIndex + 1];
                [self.audioPlayer advanceToNextItem];
                
                if (![self isPlaying]) {
                    [self play];
                }
                
            } else {
                [self fetchAndPlayPlayerItem:(nowIndex + 1)];
            }
        } else {
            if (_repeatMode == HysteriaPlayerRepeatModeOff) {
                _pauseReason = PauseReasonForced;
                if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                    [self.delegate hysteriaPlayerDidReachEnd];
                }
            } else {
                [self fetchAndPlayPlayerItem:0];
            }
        }
    }
}

- (void)playPrevious
{
    HysteriaItem *item = self.audioPlayer.currentItem;
    NSInteger nowIndex = item.index;
    
    if (nowIndex == 0)
    {
        if (_repeatMode == HysteriaPlayerRepeatModeOn) {
            [self fetchAndPlayPlayerItem:[self hysteriaPlayerItemsCount] - 1];
        } else {
            [self.audioPlayer.currentItem seekToTime:kCMTimeZero];
        }
    } else {
        [self fetchAndPlayPlayerItem:(nowIndex - 1)];
    }
}

- (CMTime)playerItemDuration
{
    NSError *err = nil;
    if ([self.audioPlayer.currentItem.asset statusOfValueForKey:@"duration" error:&err] == AVKeyValueStatusLoaded) {
        HysteriaItem *playerItem = [self.audioPlayer currentItem];
        NSArray *loadedRanges = playerItem.seekableTimeRanges;
        if (loadedRanges.count > 0)
        {
            CMTimeRange range = [[loadedRanges objectAtIndex:0] CMTimeRangeValue];
            //Float64 duration = CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration);
            return (range.duration);
        } else {
            return (kCMTimeInvalid);
        }
    } else {
        return (kCMTimeInvalid);
    }
}

- (void)setPlayerRepeatMode:(HysteriaPlayerRepeatMode)mode
{
    _repeatMode = mode;
}

- (HysteriaPlayerRepeatMode)getPlayerRepeatMode
{
    return _repeatMode;
}

- (void)setPlayerShuffleMode:(HysteriaPlayerShuffleMode)mode
{
    switch (mode) {
        case HysteriaPlayerShuffleModeOff:
            _shuffleMode = HysteriaPlayerShuffleModeOff;
            [_playedItems removeAllObjects];
            _playedItems = nil;
            break;
        case HysteriaPlayerShuffleModeOn:
            _shuffleMode = HysteriaPlayerShuffleModeOn;
            _playedItems = [NSMutableSet set];
            if (self.audioPlayer.currentItem) {
                HysteriaItem *item = self.audioPlayer.currentItem;
                NSInteger nowIndex = item.index;
                [self.playedItems addObject:@(nowIndex)];
            }
            break;
        default:
            break;
    }
}

- (HysteriaPlayerShuffleMode)getPlayerShuffleMode
{
    return _shuffleMode;
}

- (void)pausePlayerForcibly:(BOOL)forcibly {}

#pragma mark -
#pragma mark ===========  Player info  =========
#pragma mark -

- (BOOL)isPlaying
{
    return self.emptySoundPlaying ? NO : self.audioPlayer.rate != 0.f;
}

- (HysteriaPlayerStatus)getHysteriaPlayerStatus
{
    if ([self isPlaying]) {
        return HysteriaPlayerStatusPlaying;
    } else {
        switch (_pauseReason) {
            case PauseReasonForced:
                return HysteriaPlayerStatusForcePause;
            case PauseReasonBuffering:
                return HysteriaPlayerStatusBuffering;
            default:
                return HysteriaPlayerStatusUnknown;
        }
    }
}

- (float)getPlayingItemCurrentTime
{
    CMTime itemCurrentTime = [[self.audioPlayer currentItem] currentTime];
    float current = CMTimeGetSeconds(itemCurrentTime);
    if (CMTIME_IS_INVALID(itemCurrentTime) || !isfinite(current))
        return 0.0f;
    else
        return current >= 0 ? current : 0;
}

- (float)getPlayingItemDurationTime
{
    CMTime itemDurationTime = [self playerItemDuration];
    float duration = CMTimeGetSeconds(itemDurationTime);
    if (CMTIME_IS_INVALID(itemDurationTime) || !isfinite(duration))
        return 0.0f;
    else
        return duration;
}

- (id)addBoundaryTimeObserverForTimes:(NSArray *)times queue:(dispatch_queue_t)queue usingBlock:(void (^)(void))block
{
    id boundaryObserver = [self.audioPlayer addBoundaryTimeObserverForTimes:times queue:queue usingBlock:block];
    return boundaryObserver;
}

- (id)addPeriodicTimeObserverForInterval:(CMTime)interval
                                   queue:(dispatch_queue_t)queue
                              usingBlock:(void (^)(CMTime time))block
{
    id mTimeObserver = [self.audioPlayer addPeriodicTimeObserverForInterval:interval queue:queue usingBlock:block];
    return mTimeObserver;
}

- (void)removeTimeObserver:(id)observer
{
    [self.audioPlayer removeTimeObserver:observer];
}

#pragma mark -
#pragma mark ===========  Interruption, Route changed  =========
#pragma mark -

- (void)interruption:(NSNotification*)notification
{
#if TARGET_OS_IPHONE
    NSDictionary *interuptionDict = notification.userInfo;
    NSInteger interuptionType = [[interuptionDict valueForKey:AVAudioSessionInterruptionTypeKey] integerValue];
    
    if (interuptionType == AVAudioSessionInterruptionTypeBegan && _pauseReason != PauseReasonForced) {
        interruptedWhilePlaying = YES;
        [self pause];
    } else if (interuptionType == AVAudioSessionInterruptionTypeEnded && interruptedWhilePlaying) {
        interruptedWhilePlaying = NO;
        
        if ([interuptionDict[AVAudioSessionInterruptionOptionKey] integerValue] == AVAudioSessionInterruptionOptionShouldResume
            && self.audioPlayer.currentItem.status == AVPlayerStatusReadyToPlay) {
            [self play];
        }
    }
    if (!self.disableLogs) {
        NSLog(@"HysteriaPlayer: HysteriaPlayer interruption: %@", interuptionType == AVAudioSessionInterruptionTypeBegan ? @"began" : @"end");
    }
#endif
}

- (void)routeChange:(NSNotification *)notification
{
#if TARGET_OS_IPHONE
    NSDictionary *routeChangeDict = notification.userInfo;
    NSInteger routeChangeType = [[routeChangeDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue];
    
    if (routeChangeType == AVAudioSessionRouteChangeReasonOldDeviceUnavailable && _pauseReason != PauseReasonForced) {
        routeChangedWhilePlaying = YES;
        [self pause];
    } else if (routeChangeType == AVAudioSessionRouteChangeReasonNewDeviceAvailable && routeChangedWhilePlaying) {
        routeChangedWhilePlaying = NO;
        
        if (self.audioPlayer.currentItem.status == AVPlayerStatusReadyToPlay) {
            [self play];
        }
    }
    if (!self.disableLogs) {
        NSLog(@"HysteriaPlayer: HysteriaPlayer routeChanged: %@", routeChangeType == AVAudioSessionRouteChangeReasonNewDeviceAvailable ? @"New Device Available" : @"Old Device Unavailable");
    }
#endif
}

#pragma mark -
#pragma mark ===========  KVO  =========
#pragma mark -

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (object == self.audioPlayer && [keyPath isEqualToString:@"status"]) {
        if (self.audioPlayer.status == AVPlayerStatusReadyToPlay) {
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerReadyToPlay:)]) {
                [self.delegate hysteriaPlayerReadyToPlay:HysteriaPlayerReadyToPlayPlayer];
            }
            if (![self isPlaying]) {
                [self play];
            }
        } else if (self.audioPlayer.status == AVPlayerStatusFailed) {
            if (!self.disableLogs) {
                NSLog(@"HysteriaPlayer: %@", self.audioPlayer.error);
            }
            
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidFailed:error:)]) {
                [self.delegate hysteriaPlayerDidFailed:HysteriaPlayerFailedPlayer error:self.audioPlayer.error];
            }
        }
    }
    
    if (object == self.audioPlayer && [keyPath isEqualToString:@"rate"]) {
        if (!self.emptySoundPlaying) {
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerRateChanged:)]) {
                [self.delegate hysteriaPlayerRateChanged:[self isPlaying]];
            }
        }
    }
    
    if (object == self.audioPlayer && [keyPath isEqualToString:@"currentItem"]) {
        HysteriaItem *newPlayerItem = [change objectForKey:NSKeyValueChangeNewKey];
        HysteriaItem *lastPlayerItem = [change objectForKey:NSKeyValueChangeOldKey];
        if (lastPlayerItem != (id)[NSNull null]) {
            @try {
                [lastPlayerItem removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
                [lastPlayerItem removeObserver:self forKeyPath:@"status" context:nil];
            } @catch(id anException) {
                //do nothing, obviously it wasn't attached because an exception was thrown
            }
        }
        if (newPlayerItem != (id)[NSNull null]) {
            [newPlayerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
            [newPlayerItem addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
            
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerCurrentItemChanged:)]) {
                [self.delegate hysteriaPlayerCurrentItemChanged:newPlayerItem];
            }
            self.emptySoundPlaying = NO;
            
            if (newPlayerItem.status == AVPlayerItemStatusFailed) {
                if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidFailed:error:)]) {
                    [self.delegate hysteriaPlayerDidFailed:HysteriaPlayerFailedCurrentItem error:self.audioPlayer.currentItem.error];
                }
            }
        }
    }
    
    if (object == self.audioPlayer.currentItem && [keyPath isEqualToString:@"status"]) {
        isPreBuffered = NO;
        
        AVPlayerItemStatus newStatus = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
        
        if (newStatus == AVPlayerItemStatusFailed) {
            
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidFailed:error:)]) {
                [self.delegate hysteriaPlayerDidFailed:HysteriaPlayerFailedCurrentItem error:self.audioPlayer.currentItem.error];
            }
        } else if (newStatus == AVPlayerItemStatusReadyToPlay) {
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerReadyToPlay:)]) {
                [self.delegate hysteriaPlayerReadyToPlay:HysteriaPlayerReadyToPlayCurrentItem];
            }
            if (![self isPlaying] && _pauseReason != PauseReasonForced) {
                [self play];
            }
        }
    }
    
    if (self.audioPlayer.items.count > 1 && object == [self.audioPlayer.items objectAtIndex:1] && [keyPath isEqualToString:@"loadedTimeRanges"]) {
        isPreBuffered = YES;
    }
    
    if (object == self.audioPlayer.currentItem && [keyPath isEqualToString:@"loadedTimeRanges"]) {
        if (self.audioPlayer.currentItem.hash != prepareingItemHash) {
            prepareingItemHash = self.audioPlayer.currentItem.hash;
        }
        
        NSArray *timeRanges = (NSArray *)[change objectForKey:NSKeyValueChangeNewKey];
        if (timeRanges && [timeRanges count]) {
            CMTimeRange timerange = [[timeRanges objectAtIndex:0] CMTimeRangeValue];
            CMTime preloadedTime = CMTimeAdd(timerange.start, timerange.duration);
            HysteriaItem *item = object;
            item.bufferedTime = CMTimeGetSeconds(preloadedTime);
            
            if ([self.delegate respondsToSelector:@selector(hysteriaPlayerCurrentItemPreloaded:)]) {
                [self.delegate hysteriaPlayerCurrentItemPreloaded:preloadedTime];
            }
            
            if (self.audioPlayer.rate == 0 && _pauseReason != PauseReasonForced) {
                _pauseReason = PauseReasonBuffering;
                [self longTimeBufferBackground];
                
                CMTime bufferdTime = CMTimeAdd(timerange.start, timerange.duration);
                CMTime milestone = CMTimeAdd(self.audioPlayer.currentTime, CMTimeMakeWithSeconds(5.0f, timerange.duration.timescale));
                
                if (CMTIME_COMPARE_INLINE(bufferdTime , >, milestone) && self.audioPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay && !interruptedWhilePlaying && !routeChangedWhilePlaying) {
                    if (![self isPlaying]) {
                        if (!self.disableLogs) {
                            NSLog(@"HysteriaPlayer: resume from buffering..");
                        }
                        [self play];
                        [self longTimeBufferBackgroundCompleted];
                    }
                }
            }
        }
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
    HysteriaItem *item = [notification object];
    HysteriaItem *currentItem = self.audioPlayer.currentItem;
    
    if (!currentItem
        || ![item isEqual:currentItem]) {
        return;
    }
    
    NSTimeInterval itemDuration = [self getPlayingItemDurationTime];
    NSTimeInterval currentTime = [self getPlayingItemCurrentTime];
    BOOL isAtTheEndOfTheItem = itemDuration <= (currentTime + HyseriaPlayerFinishedPlaybackStallingEpsilon);
    BOOL isFullyBuffered = itemDuration <= (item.bufferedTime + HyseriaPlayerFinishedPlaybackStallingEpsilon);
    
    if (isAtTheEndOfTheItem || isFullyBuffered) {
        
        NSInteger currentItemIndex = currentItem.index;
        
        if (_repeatMode == HysteriaPlayerRepeatModeOnce) {
            [self fetchAndPlayPlayerItem:currentItemIndex];
        } else if (_shuffleMode == HysteriaPlayerShuffleModeOn) {
            NSInteger nextIndex = [self randomIndex];
            if (nextIndex != NSNotFound) {
                [self fetchAndPlayPlayerItem:[self randomIndex]];
            } else {
                _pauseReason = PauseReasonForced;
                if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                    [self.delegate hysteriaPlayerDidReachEnd];
                }
            }
        } else {
            if (self.audioPlayer.items.count == 1 || !isPreBuffered) {
                if (currentItemIndex + 1 < [self hysteriaPlayerItemsCount]) {
                    [self playNext];
                } else {
                    if (_repeatMode == HysteriaPlayerRepeatModeOff) {
                        _pauseReason = PauseReasonForced;
                        if ([self.delegate respondsToSelector:@selector(hysteriaPlayerDidReachEnd)]) {
                            [self.delegate hysteriaPlayerDidReachEnd];
                        }
                    } else {
                        [self fetchAndPlayPlayerItem:0];
                    }
                }
            }
        }
    } else {
        NSLog(@"Hysteria stalled on time %f with item of duration %f currentTime %f", item.bufferedTime, itemDuration, currentItem);
        if ([self.delegate respondsToSelector:@selector(hysteriaPlayerItemPlaybackStall:)]) {
            [self.delegate hysteriaPlayerItemPlaybackStall:notification.object];
        }
        return;
    }
}

- (void)playerItemFailedToPlayEndTime:(NSNotification *)notification {
    HysteriaItem *item = [notification object];
    if (![item isEqual:self.audioPlayer.currentItem]) {
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(hysteriaPlayerItemFailedToPlayEndTime:error:)]) {
        [self.delegate hysteriaPlayerItemFailedToPlayEndTime:notification.object error:notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]];
    }
}

- (void)playerItemPlaybackStall:(NSNotification *)notification {
    HysteriaItem *item = [notification object];
    if (![item isEqual:self.audioPlayer.currentItem]) {
        return;
    }
    
    if ([self.delegate respondsToSelector:@selector(hysteriaPlayerItemPlaybackStall:)]) {
        [self.delegate hysteriaPlayerItemPlaybackStall:notification.object];
    }
}

- (NSInteger)randomIndex
{
    NSInteger itemsCount = [self hysteriaPlayerItemsCount];
    if ([self.playedItems count] == itemsCount) {
        self.playedItems = [NSMutableSet set];
        if (_repeatMode == HysteriaPlayerRepeatModeOff) {
            return NSNotFound;
        }
    }
    
    NSInteger index;
    do {
        index = arc4random() % itemsCount;
    } while ([_playedItems containsObject:[NSNumber numberWithInteger:index]]);
    
    return index;
}

#pragma mark -
#pragma mark ===========   Deprecation  =========
#pragma mark -

- (void)deprecatePlayer
{
    NSError *error;
    tookAudioFocus = NO;
#if TARGET_OS_IPHONE
    [[AVAudioSession sharedInstance] setActive:NO error:&error];
    [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self.audioPlayer removeObserver:self forKeyPath:@"status" context:nil];
    [self.audioPlayer removeObserver:self forKeyPath:@"rate" context:nil];
    [self.audioPlayer removeObserver:self forKeyPath:@"currentItem" context:nil];
    
    [self removeAllItems];
    
    [self.audioPlayer pause];
    self.delegate = nil;
    self.datasource = nil;
    self.audioPlayer = nil;
    
    onceToken = 0;
}

- (void)resetPlayer
{
    if (!self.audioPlayer) {
        return;
    }
    
    @try {
        [self.audioPlayer removeObserver:self forKeyPath:@"status" context:nil];
        [self.audioPlayer removeObserver:self forKeyPath:@"rate" context:nil];
        [self.audioPlayer removeObserver:self forKeyPath:@"currentItem" context:nil];
    } @catch(id anException) {
        //do nothing, obviously it wasn't attached because an exception was thrown
    }
    
    @try {
        [self.audioPlayer.currentItem removeObserver:self forKeyPath:@"loadedTimeRanges" context:nil];
        [self.audioPlayer.currentItem removeObserver:self forKeyPath:@"status" context:nil];
    } @catch(id anException) {
        //do nothing, obviously it wasn't attached because an exception was thrown
    }
    
    [self removeAllItems];
    
    [self.audioPlayer pause];
    self.audioPlayer = nil;
    
    [self createAudioPlayer];
}

#pragma mark -
#pragma mark ===========   Memory cached  =========
#pragma mark -

- (BOOL)isMemoryCached
{
    return self.playerItems != nil;
}

- (void)enableMemoryCached:(BOOL)memoryCache
{
    if (self.playerItems == nil && memoryCache) {
        self.playerItems = [NSArray array];
    } else if (self.playerItems != nil && !memoryCache) {
        self.playerItems = nil;
    }
}

#pragma mark -
#pragma mark ===========   Delegation  =========
#pragma mark -

- (void)addDelegate:(id<HysteriaPlayerDelegate>)delegate{}

- (void)removeDelegate:(id<HysteriaPlayerDelegate>)delegate{}

#pragma mark -
#pragma mark ===========   Index  =========
#pragma mark -

- (NSInteger)getHysteriaIndex:(HysteriaItem *)item
{
    return item.index;
}

@end
