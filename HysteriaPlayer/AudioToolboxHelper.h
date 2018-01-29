//
//  ZVQAudioToolboxHelper.h
//  Zvooq
//
//  Created by User on 15/03/17.
//  Copyright © 2017 Dream Industries. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface AudioToolboxHelper : NSObject

/// An issue can be faced:
/// kAudioQueueErr_CannotStart
///
/// Printing description of ((NSError *)0x0000000172850b00):
/// Error Domain=AVFoundationErrorDomain Code=-11800 "Не удалось выполнить операцию" UserInfo={NSUnderlyingError=0x1716547c0
/// {Error Domain=NSOSStatusErrorDomain Code=-66681 "(null)"}, NSLocalizedFailureReason=Произошла неизвестная ошибка (-66681),
/// NSLocalizedRecoverySuggestion=XXXXDEFAULTVALUEXXXX, NSLocalizedDescription=Не удалось выполнить операцию}
///
/// To fix this we need to reset AudioQueue BEFORE AVAudioSession set up (done in AppDelegate).

+ (void)resetAudioQueue;

@end
