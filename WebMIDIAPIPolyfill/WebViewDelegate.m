/*
 
 Copyright 2014 Takashi Mizuhiki
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

#import <mach/mach_time.h>

#import "WebViewDelegate.h"

static NSString *kURLScheme_RequestSetup = @"webmidi-onready://";
static NSString *kURLScheme_RequestSend  = @"webmidi-send://";

@implementation WebViewDelegate

- (void)invokeJSCallback_onNotReady:(UIWebView *)webView
{
    [webView stringByEvaluatingJavaScriptFromString:@"_callback_onNotReady();"];
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType
{
    // Process informal URL schemes.
    NSString *urlStr = request.URL.absoluteString;
    if ([urlStr hasPrefix:kURLScheme_RequestSetup]) {
        __block uint64_t timestampOrigin = 0;

        mach_timebase_info_data_t base;
        mach_timebase_info(&base);

        if (_midiDriver.isAvailable == NO) {
            [self invokeJSCallback_onNotReady:webView];
            return NO;
        }
        
        // Setup the callback for receiving MIDI message.
        _midiDriver.onMessageReceived = ^(ItemCount index, NSData *receivedData, uint64_t timestamp) {
            NSMutableArray *array = [NSMutableArray arrayWithCapacity:[receivedData length]];
            for (int i = 0; i < [receivedData length]; i++) {
                [array addObject:[NSNumber numberWithUnsignedChar:((unsigned char *)[receivedData bytes])[i]]];
            }
            NSData *dataJSON = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
            NSString *dataJSONStr = [[NSString alloc] initWithData:dataJSON encoding:NSUTF8StringEncoding];

            double deltaTime_ms = (double)(timestamp - timestampOrigin) * base.numer / base.denom / 1000000.0;
            [webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"_callback_receiveMIDIMessage(%lu, %f, %@);", index, deltaTime_ms, dataJSONStr]];
        };

        __weak MIDIDriver *midiDriver = _midiDriver;
        _midiDriver.onDestinationPortAdded = ^(ItemCount index) {
            NSDictionary *info = [midiDriver portinfoFromDestinationEndpointIndex:index];
            NSData *JSON = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
            NSString *JSONStr = [[NSString alloc] initWithData:JSON encoding:NSUTF8StringEncoding];

            [webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"_callback_addDestination(%lu, %@);", index, JSONStr]];
        };

        _midiDriver.onSourcePortAdded = ^(ItemCount index) {
            NSDictionary *info = [midiDriver portinfoFromSourceEndpointIndex:index];
            NSData *JSON = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
            NSString *JSONStr = [[NSString alloc] initWithData:JSON encoding:NSUTF8StringEncoding];
            
            [webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"_callback_addSource(%lu, %@);", index, JSONStr]];
        };
        
        _midiDriver.onDestinationPortRemoved = ^(ItemCount index) {
            [webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"_callback_removeDestination(%lu);", index]];
        };
        
        _midiDriver.onSourcePortRemoved = ^(ItemCount index) {
            [webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"_callback_removeSource(%lu);", index]];
        };
        
        // Send all MIDI ports information when the setup request is received.
        ItemCount srcCount  = [_midiDriver numberOfSources];
        ItemCount destCount = [_midiDriver numberOfDestinations];

        NSMutableArray *srcs  = [NSMutableArray arrayWithCapacity:srcCount];
        NSMutableArray *dests = [NSMutableArray arrayWithCapacity:destCount];


        for (ItemCount srcIndex = 0; srcIndex < srcCount; srcIndex++) {
            NSDictionary *info = [_midiDriver portinfoFromSourceEndpointIndex:srcIndex];
            if (info == nil) {
                [self invokeJSCallback_onNotReady:webView];
                return NO;
            }
            [srcs addObject:info];
        }

        for (ItemCount destIndex = 0; destIndex < destCount; destIndex++) {
            NSDictionary *info = [_midiDriver portinfoFromDestinationEndpointIndex:destIndex];
            if (info == nil) {
                [self invokeJSCallback_onNotReady:webView];
                return NO;
            }
            [dests addObject:info];
        }

        
        NSData *srcsJSON = [NSJSONSerialization dataWithJSONObject:srcs options:0 error:nil];
        if (srcsJSON == nil) {
            [self invokeJSCallback_onNotReady:webView];
            return NO;
        }
        NSString *srcsJSONStr = [[NSString alloc] initWithData:srcsJSON encoding:NSUTF8StringEncoding];

        NSData *destsJSON = [NSJSONSerialization dataWithJSONObject:dests options:0 error:nil];
        if (destsJSON == nil) {
            [self invokeJSCallback_onNotReady:webView];
            return NO;
        }
        NSString *destsJSONStr = [[NSString alloc] initWithData:destsJSON encoding:NSUTF8StringEncoding];

        timestampOrigin = mach_absolute_time();

        [webView stringByEvaluatingJavaScriptFromString:[NSString stringWithFormat:@"_callback_onReady(%@, %@);", srcsJSONStr, destsJSONStr]];
        
        return NO;

    } else if ([urlStr hasPrefix:kURLScheme_RequestSend]) {
        NSString *jsonStr = [[urlStr substringFromIndex:[kURLScheme_RequestSend length]] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

        NSArray *array = dict[@"data"];

        NSMutableData *message = [NSMutableData dataWithCapacity:[array count]];
        for (NSNumber *number in array) {
            uint8_t byte = [number unsignedIntegerValue];
            [message appendBytes:&byte length:1];
        }

        ItemCount outputIndex = [dict[@"outputPortIndex"] unsignedLongValue];
        float deltatime = [dict[@"deltaTime"] floatValue];
        [_midiDriver sendMessage:message toDestinationIndex:outputIndex deltatime:deltatime];

        return NO;
    }
    
    return YES;
}

@end
