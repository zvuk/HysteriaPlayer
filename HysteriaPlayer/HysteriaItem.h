//
//  HysteriaItem.h
//  Pods
//
//  Created by User on 15/11/16.
//
//

#import <AVFoundation/AVFoundation.h>

@interface HysteriaItem : AVPlayerItem

- (instancetype)initWithAsset:(AVAsset *)asset index:(NSUInteger)index;

@property (nonatomic) NSInteger index;
@property (nonatomic) NSTimeInterval bufferedTime;
@property (nonatomic) NSTimeInterval offsetTime;

@end
