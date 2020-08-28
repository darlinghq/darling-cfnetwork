#import <CFNetwork/CFNSURLConnection.h>

@implementation NSURLSessionTaskMetrics

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
	return [NSMethodSignature signatureWithObjCTypes: "v@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
	// would require Foundation
	//NSLog(@"Stub called: %@ in %@", NSStringFromSelector([anInvocation selector]), [self class]);
}

@end
