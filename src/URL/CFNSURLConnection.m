#import <CFNetwork/CFNSURLConnection.h>

@implementation NSURLSessionTaskMetrics

@synthesize taskInterval = _taskInterval;
@synthesize redirectCount = _redirectCount;

- (id)_initWithTaskInterval:(NSDateInterval *)taskInterval redirectCount:(NSUInteger)redirectCount
{
	self = [super init];
	if (self)
	{
		_taskInterval = [taskInterval copy];
		_redirectCount = redirectCount;
	}
	return self;
}

- (void)dealloc
{
	[_taskInterval release];
	[super dealloc];
}

- (NSArray *)transactionMetrics
{
	return [NSArray array];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@: %p> (Task Interval) %@ (Redirect Count) %lu", [self class], self, _taskInterval, (unsigned long)_redirectCount];
}

@end
