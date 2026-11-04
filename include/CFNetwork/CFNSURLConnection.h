#ifndef _CFNSURLCONNECTION_H_
#define _CFNSURLCONNECTION_H_

// not sure what's going on here
// `SecCAIssuerRequest.m` imports this file
// let's just include the main header for now
#include <CFNetwork/CFNetwork.h>

#import <Foundation/Foundation.h>

// What NSURLSession measured for one task. Darling's transport keeps no per-transaction
// timings, so transactionMetrics is empty; taskInterval spans resume to completion.
@interface NSURLSessionTaskMetrics : NSObject {
    NSDateInterval *_taskInterval;
    NSUInteger _redirectCount;
}

@property (readonly, copy) NSArray *transactionMetrics;
@property (readonly, copy) NSDateInterval* taskInterval;
@property (readonly, assign) NSUInteger redirectCount;

- (id)_initWithTaskInterval:(NSDateInterval *)taskInterval redirectCount:(NSUInteger)redirectCount;

@end

@interface NSURLSessionConfiguration (CFNSPrivateStuff)

@property (readwrite) NSData* _sourceApplicationAuditTokenData;
@property (readwrite) BOOL _requiresPowerPluggedIn;

@end

#endif // _CFNSURLCONNECTION_H_
