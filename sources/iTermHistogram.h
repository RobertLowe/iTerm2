//
//  iTermHistogram.h
//  iTerm2SharedARC
//
//  Created by George Nachman on 12/19/17.
//

#import <Foundation/Foundation.h>

@interface iTermHistogram : NSObject

@property (nonatomic, readonly) NSString *stringValue;
@property (nonatomic, readonly) NSString *sparklines;

- (void)addValue:(double)value;

@end