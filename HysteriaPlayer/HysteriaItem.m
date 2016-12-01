//
//  HysteriaItem.m
//  Pods
//
//  Created by User on 15/11/16.
//
//

#import "HysteriaItem.h"

@implementation HysteriaItem

- (instancetype)initWithAsset:(AVAsset *)asset index:(NSUInteger)index
{
    self = [super initWithAsset:asset];
    
    if (self) {
        _index = index;
    }
    
    return self;
}

@end
