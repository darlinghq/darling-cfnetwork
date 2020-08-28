#ifndef _CFNSURLCONNECTION_H_
#define _CFNSURLCONNECTION_H_

// not sure what's going on here
// `SecCAIssuerRequest.m` imports this file
// let's just include the main header for now
#include <CFNetwork/CFNetwork.h>

#import <Foundation/Foundation.h>

@interface NSURLSessionTaskMetrics : NSObject

@property (readonly, copy) NSDateInterval* taskInterval;

@end

@interface NSURLSessionConfiguration (CFNSPrivateStuff)

@property (readwrite) NSData* _sourceApplicationAuditTokenData;
@property (readwrite) BOOL _requiresPowerPluggedIn;

@end

#endif // _CFNSURLCONNECTION_H_
