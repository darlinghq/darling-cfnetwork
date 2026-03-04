//
//  NSURLSession.m
//  Foundation
//
//  Copyright (c) 2014 Apportable. All rights reserved.
//

#import <Foundation/NSURLSession.h>
#import <objc/runtime.h>

const int64_t NSURLSessionTransferSizeUnknown = -1LL;
NSString* const NSURLSessionDownloadTaskResumeData = @"NSURLSessionDownloadTaskResumeData";

const float NSURLSessionTaskPriorityDefault = 0.5;
const float NSURLSessionTaskPriorityLow = 0.25;
const float NSURLSessionTaskPriorityHigh = 0.75;

@implementation NSURLSession

+ (void)initialize
{
    static dispatch_once_t once = 0L;
    dispatch_once(&once, ^{
        Class cls = objc_lookUpClass("__NSCFURLSession");
        assert(cls != Nil);
        class_setSuperclass(self, cls);
    });
}

@end

@implementation NSURLSessionTask
@end

@implementation NSURLSessionDataTask
@end

@implementation NSURLSessionDownloadTask
@end

@implementation NSURLSessionUploadTask
@end

@implementation NSURLSessionConfiguration

static NSURLSessionConfiguration *_defaultSessionConfiguration = nil;

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
	if (_defaultSessionConfiguration == nil) {
		_defaultSessionConfiguration = [[NSURLSessionConfiguration alloc] init];
	}

	return _defaultSessionConfiguration;
}

@end
