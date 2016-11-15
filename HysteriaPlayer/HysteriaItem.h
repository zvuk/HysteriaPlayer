//
//  HysteriaItem.h
//  Pods
//
//  Created by User on 15/11/16.
//
//

#import <AVFoundation/AVFoundation.h>

@interface HysteriaItem : AVPlayerItem

@property (nonatomic) NSInteger index;
@property (nonatomic) NSTimeInterval bufferedTime;

@end
