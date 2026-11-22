// Private QuartzCore API for cross-process layer hosting. Chromium declares the
// same symbols in ui/base/cocoa/remote_layer_api.h; WebKit uses them too.
#ifndef BOWSER_REMOTE_API_H
#define BOWSER_REMOTE_API_H

#import <QuartzCore/QuartzCore.h>

typedef uint32_t CAContextID;
typedef uint32_t CGSConnectionID;
CGSConnectionID CGSMainConnectionID(void);
extern NSString *const kCAContextCIFilterBehavior;

@interface CAContext : NSObject
+ (instancetype)contextWithCGSConnection:(CGSConnectionID)cid options:(NSDictionary *)opts;
@property(readonly) CAContextID contextId;
@property(retain) CALayer *layer;
@end

@interface CALayerHost : CALayer
@property CAContextID contextId;
@end

#endif
