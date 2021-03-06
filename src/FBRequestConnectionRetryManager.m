/*
 * Copyright 2010-present Facebook.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <Foundation/NSThread.h>

#import "FBRequestConnectionRetryManager.h"
#import "FBRequestConnection+Internal.h"
#import "FBRequest+Internal.h"
#import "FBSession+Internal.h"
#import "FBUtility.h"

// An INTERNAL "light-weight" structure for presenting an alertview and assigning a completion block to call after
// the alert has been dismissed. The alert will be dispatched to the main queue. The callback will also be dispatched
// to the the main thread after the alert has been dismissed.
@interface FBRequestConnectionRetryManagerAlertViewHelper : NSObject<UIAlertViewDelegate>

-(void) show:(NSString *)title message:(NSString *)message cancelButtonTitle:(NSString *)cancelButtonTitle
     handler:(void(^)(void)) callback;

@end

@interface FBRequestConnectionRetryManagerAlertViewHelper()

@property (nonatomic, copy) void(^callback)(void);

@end

@implementation FBRequestConnectionRetryManagerAlertViewHelper

// Note this may require refactoring if you plan on presenting multiple dialogs.
-(void) show:(NSString *)title message:(NSString *)message cancelButtonTitle:(NSString *)cancelButtonTitle
    handler:(void(^)(void)) callback {

    self.callback = callback;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[[UIAlertView alloc] initWithTitle:title message:message delegate:self cancelButtonTitle:cancelButtonTitle otherButtonTitles:nil] show];
    });
}

-(void) alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (self.callback) {
        dispatch_async(dispatch_get_main_queue(), self.callback);
    }
}

-(void) dealloc {
    self.callback = nil;
    
    [super dealloc];
}
@end

@interface FBRequestConnectionRetryManager()

@property (nonatomic, retain) NSMutableArray *requestMetadatas;
@property (nonatomic, retain) FBRequestConnectionRetryManagerAlertViewHelper *alertViewHelper;
@property (atomic, assign) int expectedPerformRetryCount;

@end


@implementation FBRequestConnectionRetryManager

-(id) initWithFBRequestConnection:(FBRequestConnection *)requestConnection {
    if (self = [super init]){
        self.requestConnection = requestConnection;
        _requestMetadatas = [[NSMutableArray alloc] init];
        _alertViewHelper = [[FBRequestConnectionRetryManagerAlertViewHelper alloc] init];
    }
    return self;
}

-(void) addRequestMetadata:(FBRequestMetadata *)metadata {
    [self.requestMetadatas addObject:metadata];
}

-(void) performRetries {
    if (self.expectedPerformRetryCount > 0) {
        // As noted in `expectedPerformRetryCount` declaration, this condition
        // is to help deal with the async callbacks in FBRequestConnection. Specifically,
        // the async ios 6 calls need to be processed before any attempt at performRetries.
        // So before issuing the async calls, we increment the counter so that at the end
        // of the callback, we can call performRetries. The performRetries will no-op
        // if the counter is still positive; otherwise it decrements the counter. This
        // allows the "last" performRetries invocation to actually do its work (since
        // there a performRetries call at the end of FBRequestConnection completeWithResults
        // that is _not_ paired with a counter increment).
        // Note this is still not 100% thread-safe but since all the counter increments
        // happen beforehand and on the same thread (the completeWithResults loop), it
        // should be fine albeit fragile until we refactor the async callbacks.
        self.expectedPerformRetryCount--;
        return;
    }
    
    if (self.alertMessage.length > 0) {
        [_requestConnection retain];
        NSString *buttonText = [FBUtility localizedStringForKey:@"FBE:AlertMessageButton" withDefault:@"OK"];
        [self.alertViewHelper show:nil message:self.alertMessage cancelButtonTitle:buttonText
                      handler:^{
                                  self.alertMessage = nil;
                                  [self performRetries];
                                  [_requestConnection release];
                             }];
        return;
    }
    
    if (self.requestMetadatas.count > 0) {
        switch (self.state) {
            case FBRequestConnectionRetryManagerStateNormal : {
                FBRequestConnection *connectionToRetry = [[[FBRequestConnection alloc] initWithMetadata:self.requestMetadatas] autorelease];
                [connectionToRetry start];
                break;
            }
            case FBRequestConnectionRetryManagerStateAbortRetries : {
                for (FBRequestMetadata *metadata in self.requestMetadatas) {
                    [metadata invokeCompletionHandlerForConnection:self.requestConnection withResults:metadata.originalResult error:metadata.originalError];
                }
                break;
            }
            case FBRequestConnectionRetryManagerStateRepairSession : {
                [_requestConnection retain];
                NSThread *thread = self.sessionToReconnect.affinitizedThread ?: [NSThread mainThread];
                FBSessionRequestPermissionResultHandler handler = [[^(FBSession *session, NSError *sessionError) {
                    if (session.isOpen && !sessionError) {
                        [self repairSuccess];
                    } else {
                        [self repairFailed];
                    }
                    [_requestConnection release];
                } copy] autorelease];

                [self.sessionToReconnect performSelector:@selector(repairWithHandler:) onThread:thread withObject:handler waitUntilDone:NO];
                
                break;
            }
        }
    }
}

-(void) repairSuccess {
    if (self.requestMetadatas.count > 0) {
        // Construct new request connection and re-add the requests, but removing
        // the "autoreconnect" behavior (though we still allow the simpler retry)
        // and alerts (since those would have already been surfaced prior to the repair attempt).
        FBRequestConnection *connectionToRetry = [[[FBRequestConnection alloc] init] autorelease];
        connectionToRetry.errorBehavior = self.requestConnection.errorBehavior
            & ~FBRequestConnectionErrorBehaviorReconnectSession
            & ~FBRequestConnectionErrorBehaviorAlertUser;
        for (FBRequestMetadata *metadata in self.requestMetadatas) {
            metadata.request.canCloseSessionOnError = YES;
            [connectionToRetry addRequest:metadata.request
                        completionHandler:metadata.originalCompletionHandler
                           batchEntryName:metadata.batchEntryName];
        }
        [connectionToRetry start];
    }
}

-(void) repairFailed {
    if (self.requestMetadatas.count > 0) {
        for (FBRequestMetadata *metadata in self.requestMetadatas) {
            // Since we were unable to repair the session, we will close it now since that is the existing behavior for
            // errors that would have caused a repair attempt.
            if (metadata.request.session.isOpen && !metadata.request.session.isRepairing) {
                [metadata.request.session closeAndClearTokenInformation:metadata.originalError];
            }
            metadata.originalCompletionHandler(self.requestConnection, metadata.originalResult, metadata.originalError);
        }
    }
}

-(void) incrementExpectedPerformRetryCount {
    self.expectedPerformRetryCount++;
}

-(void) dealloc {
    self.sessionToReconnect = nil;
    self.alertMessage = nil;
    self.requestMetadatas = nil;
    self.alertViewHelper = nil;
    
    [super dealloc];
}
@end
