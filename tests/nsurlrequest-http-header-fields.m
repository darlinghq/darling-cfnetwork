#import <Foundation/Foundation.h>

// HTTP header field names are case-insensitive and a nil value removes the field (VibeDarling/darling#966).
// The nil cases run last: before the fix they terminate the process.

static int failures = 0;

static void expect(BOOL condition, NSString *message)
{
    if (!condition)
    {
        NSLog(@"FAIL: %@", message);
        failures++;
    }
}

int main(void)
{
    @autoreleasepool
    {
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/"]];

        [r setValue:@"a" forHTTPHeaderField:@"X-A"];
        expect([[r valueForHTTPHeaderField:@"x-a"] isEqualToString:@"a"], @"lookup ignores case");
        [r setValue:@"b" forHTTPHeaderField:@"x-a"];
        expect([[r allHTTPHeaderFields] count] == 1, @"replacing with another case keeps one field");
        expect([[r valueForHTTPHeaderField:@"X-A"] isEqualToString:@"b"], @"replacement is visible under the original case");
        [r addValue:@"c" forHTTPHeaderField:@"X-a"];
        expect([[r allHTTPHeaderFields] count] == 1, @"addValue with another case joins the existing field");
        expect([[r valueForHTTPHeaderField:@"x-A"] isEqualToString:@"b,c"], @"addValue appends with a comma");

        [r setValue:@"keep" forHTTPHeaderField:@"X-Keep"];
        [r setValue:nil forHTTPHeaderField:@"x-a"];
        expect([r valueForHTTPHeaderField:@"X-A"] == nil, @"nil removes the field, matched case-insensitively");
        expect([[r allHTTPHeaderFields] count] == 1, @"nil removal leaves other fields");
        expect([[r valueForHTTPHeaderField:@"X-Keep"] isEqualToString:@"keep"], @"unrelated field survives");

        [r setValue:nil forHTTPHeaderField:@"X-Absent"];
        expect([[r allHTTPHeaderFields] count] == 1, @"nil on an absent field adds nothing");
        expect([[r allHTTPHeaderFields] objectForKey:@"X-Absent"] == nil, @"absent field stays absent");
    }
    if (failures)
    {
        NSLog(@"FAILED: %d check(s)", failures);
        return 1;
    }
    NSLog(@"PASS: HTTP header fields are case-insensitive and nil removes");
    return 0;
}
