//
//  RokuService.m
//  ConnectSDK
//
//  Created by Jeremy White on 2/14/14.
//  Copyright (c) 2014 LG Electronics.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <UIKit/UIKit.h>
#import "RokuService_Private.h"
#import "ConnectError.h"
#import "CTXMLReader.h"
#import "ConnectUtil.h"
#import "DeviceServiceReachability.h"
#import "DiscoveryManager.h"
#import "SubtitleInfo.h"

#import "NSObject+FeatureNotSupported_Private.h"

@interface RokuService () <ServiceCommandDelegate, DeviceServiceReachabilityDelegate>
{
    DIALService *_dialService;
    DeviceServiceReachability *_serviceReachability;
    /// The channel the last launch went to; decides how controls are sent.
    NSString *_activeChannel;
}
@end

static NSMutableArray *registeredApps = nil;

/// The Roku Media Player — a free store channel (not firmware; a Roku Express
/// out of the box has none), used when no LocalCast receiver is installed.
static NSString *const kRokuMediaPlayerChannel = @"2213";

/// The `videoFormat`/`songFormat` the Roku Media Player expects: a short
/// container/codec name, not a MIME type. HLS is "hls", DASH is "dash"; for
/// progressive files the MIME subtype or the URL extension.
static NSString *rokuMediaFormat(NSString *mimeType, NSURL *url)
{
    NSString *m = [mimeType lowercaseString] ?: @"";
    // A manifest URL wins over the MIME: the bridge defaults to video/mp4
    // when the app names nothing, and the receiver then parsed an HLS
    // master as MP4 (device test 2026-10-22).
    NSString *pathExt = [url.pathExtension lowercaseString];
    if ([pathExt isEqualToString:@"m3u8"]) return @"hls";
    if ([pathExt isEqualToString:@"mpd"]) return @"dash";
    if ([m containsString:@"mpegurl"]) return @"hls";
    if ([m containsString:@"dash+xml"]) return @"dash";
    if ([m containsString:@"x-matroska"]) return @"mkv";
    if ([m containsString:@"quicktime"]) return @"mov";
    if ([m isEqualToString:@"video/mp4"] || [m isEqualToString:@"audio/mp4"]) return @"mp4";
    if ([m isEqualToString:@"audio/mpeg"] || [m isEqualToString:@"audio/mp3"]) return @"mp3";
    if ([m containsString:@"x-m4a"]) return @"m4a";
    if ([m containsString:@"aac"]) return @"aac";
    if ([m containsString:@"flac"]) return @"flac";
    if ([m containsString:@"wav"]) return @"wav";
    if ([m containsString:@"mp2t"]) return @"ts";
    NSString *ext = [url.pathExtension lowercaseString];
    if (ext.length > 0 && ext.length <= 4) {
        if ([ext isEqualToString:@"m3u8"]) return @"hls";
        if ([ext isEqualToString:@"mpd"]) return @"dash";
        return ext;
    }
    NSRange slash = [m rangeOfString:@"/"];
    if (slash.location != NSNotFound && slash.location + 1 < m.length) {
        return [m substringFromIndex:slash.location + 1];
    }
    return @"mp4";
}

/// Milliseconds of `<position>12345 ms</position>` / `<duration>…`, or -1.
static NSTimeInterval rokuMediaPlayerMillis(NSString *xml, NSString *tag)
{
    if (xml.length == 0) return -1;
    NSString *pattern = [NSString stringWithFormat:@"<%@>\\s*(\\d+)\\s*ms\\s*</%@>", tag, tag];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (!match || match.numberOfRanges < 2) return -1;
    return [[xml substringWithRange:[match rangeAtIndex:1]] doubleValue];
}

/// The `state` attribute of `<player state="play" …>`, or nil.
static NSString *rokuMediaPlayerState(NSString *xml)
{
    if (xml.length == 0) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<player[^>]*\\sstate=\"([^\"]*)\"" options:0 error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [xml substringWithRange:[match rangeAtIndex:1]];
}

@implementation RokuService

+ (void) initialize
{
    registeredApps = [NSMutableArray arrayWithArray:@[
            @"YouTube",
            @"Netflix",
            @"Amazon"
    ]];
}

+ (NSDictionary *)discoveryParameters
{
    return @{
            @"serviceId" : kConnectSDKRokuServiceId,
            @"ssdp" : @{
                    @"filter" : @"roku:ecp"
            }
    };
}

- (void) updateCapabilities
{
    NSArray *capabilities = @[
        kLauncherAppList,
        kLauncherApp,
        kLauncherAppParams,
        kLauncherAppStore,
        kLauncherAppStoreParams,
        kLauncherAppClose,

        kMediaPlayerDisplayImage,
        kMediaPlayerPlayVideo,
        kMediaPlayerPlayAudio,
        kMediaPlayerClose,
        kMediaPlayerMetaDataTitle,

        kMediaControlPlay,
        kMediaControlPause,
        kMediaControlStop,
        kMediaControlRewind,
        kMediaControlFastForward,
        // From ECP query/media-player (Roku OS 7+)
        kMediaControlPosition,
        kMediaControlDuration,
        kMediaControlPlayState,

        kTextInputControlSendText,
        kTextInputControlSendEnter,
        kTextInputControlSendDelete
    ];

    capabilities = [capabilities arrayByAddingObjectsFromArray:kKeyControlCapabilities];

    [self setCapabilities:capabilities];
}

+ (void) registerApp:(NSString *)appId
{
    if (![registeredApps containsObject:appId])
        [registeredApps addObject:appId];
}

- (void) probeForApps
{
    [registeredApps enumerateObjectsUsingBlock:^(NSString *appName, NSUInteger idx, BOOL *stop)
    {
        [self hasApp:appName success:^(AppInfo *appInfo)
        {
            NSString *capability = [NSString stringWithFormat:@"Launcher.%@", appName];
            NSString *capabilityParams = [NSString stringWithFormat:@"Launcher.%@.Params", appName];

            [self addCapabilities:@[capability, capabilityParams]];
        } failure:nil];
    }];
}

- (BOOL) isConnectable
{
    return YES;
}

- (void) connect
{
    NSString *targetPath = [NSString stringWithFormat:@"http://%@:%@/", self.serviceDescription.address, @(self.serviceDescription.port)];
    NSURL *targetURL = [NSURL URLWithString:targetPath];

    _serviceReachability = [DeviceServiceReachability reachabilityWithTargetURL:targetURL];
    _serviceReachability.delegate = self;
    [_serviceReachability start];

    self.connected = YES;

    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceServiceConnectionSuccess:)])
        dispatch_on_main(^{ [self.delegate deviceServiceConnectionSuccess:self]; });
    [self announceConnection:YES];
}

/// ECP has no session, so the app tells our receiver that it is here: on
/// connect, launch the LocalCast channel (if installed) with
/// cmd=connected&name=<phone> — it drops its "get the app" QR and names the
/// phone — and on disconnect send cmd=disconnected. Best effort.
- (void)announceConnection:(BOOL)nowConnected
{
    if (!nowConnected) {
        if ([self ownReceiverActive])
            [self sendReceiverCommand:@"cmd=disconnected" success:nil failure:nil];
        return;
    }
    [self getAppListWithSuccess:^(NSArray *appList) {
        NSString *own = localCastChannelIn(appList);
        if (!own) return;
        NSString *name = [UIDevice currentDevice].name ?: @"iPhone";
        self->_activeChannel = own;
        NSString *path = [NSString stringWithFormat:@"%@/launch/%@?cmd=connected&name=%@",
                          self.serviceDescription.commandURL.absoluteString, own, [ConnectUtil urlEncode:name]];
        ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:[NSURL URLWithString:path] payload:nil];
        command.HTTPMethod = @"POST";
        [command send];
    } failure:nil];
}

- (void) disconnect
{
    [self announceConnection:NO];
    self.connected = NO;

    [_serviceReachability stop];

    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)])
        dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:nil]; });
}

- (void) didLoseReachability:(DeviceServiceReachability *)reachability
{
    if (self.connected)
        [self disconnect];
    else
        [_serviceReachability stop];
}

- (void)setServiceDescription:(ServiceDescription *)serviceDescription
{
    [super setServiceDescription:serviceDescription];

    self.serviceDescription.port = 8060;
    NSString *commandPath = [NSString stringWithFormat:@"http://%@:%@", self.serviceDescription.address, @(self.serviceDescription.port)];
    self.serviceDescription.commandURL = [NSURL URLWithString:commandPath];

    [self probeForApps];
}

- (DIALService *) dialService
{
    if (!_dialService)
    {
        ConnectableDevice *device = [[DiscoveryManager sharedManager].allDevices objectForKey:self.serviceDescription.address];
        __block DIALService *foundService;

        [device.services enumerateObjectsUsingBlock:^(DeviceService *service, NSUInteger idx, BOOL *stop)
        {
            if ([service isKindOfClass:[DIALService class]])
            {
                foundService = (DIALService *) service;
                *stop = YES;
            }
        }];

        if (foundService)
            _dialService = foundService;
    }

    return _dialService;
}

#pragma mark - Getters & Setters

/// Returns the set delegate property value or self.
- (id<ServiceCommandDelegate>)serviceCommandDelegate {
    return _serviceCommandDelegate ?: self;
}

#pragma mark - ServiceCommandDelegate

- (int) sendCommand:(ServiceCommand *)command withPayload:(NSDictionary *)payload toURL:(NSURL *)URL
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData];
    [request setTimeoutInterval:6];
    [request addValue:@"text/plain;charset=\"utf-8\"" forHTTPHeaderField:@"Content-Type"];

    if (payload || [command.HTTPMethod isEqualToString:@"POST"])
    {
        [request setHTTPMethod:@"POST"];

        if (payload)
        {
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
            [request addValue:[NSString stringWithFormat:@"%i", (unsigned int) [jsonData length]] forHTTPHeaderField:@"Content-Length"];
            [request setHTTPBody:jsonData];
        }
    } else
    {
        [request setHTTPMethod:@"GET"];
        [request addValue:@"0" forHTTPHeaderField:@"Content-Length"];
    }

    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError)
    {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        
        if (connectionError)
        {
            if (command.callbackError)
                dispatch_on_main(^{ command.callbackError(connectionError); });
        } else
        {
            if ([httpResponse statusCode] < 200 || [httpResponse statusCode] >= 300)
            {
                NSError *error = [ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil];
                
                if (command.callbackError)
                    command.callbackError(error);
                
                return;
            }
            
            NSString *dataString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

            if (command.callbackComplete)
                dispatch_on_main(^{ command.callbackComplete(dataString); });
        }
    }];

    // TODO: need to implement callIds in here
    return 0;
}

#pragma mark - Launcher

- (id <Launcher>)launcher
{
    return self;
}

- (CapabilityPriorityLevel)launcherPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)launchApp:(NSString *)appId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (!appId)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide an appId."]);
        return;
    }

    AppInfo *appInfo = [AppInfo appInfoForId:appId];

    [self launchAppWithInfo:appInfo params:nil success:success failure:failure];
}

- (void)launchAppWithInfo:(AppInfo *)appInfo success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchAppWithInfo:appInfo params:nil success:success failure:failure];
}

- (void)launchAppWithInfo:(AppInfo *)appInfo params:(NSDictionary *)params success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (!appInfo || !appInfo.id)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid AppInfo object."]);
        return;
    }

    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"launch"];
    targetURL = [targetURL URLByAppendingPathComponent:appInfo.id];
    
    if (params)
    {
        __block NSString *queryParams = @"";
        __block int count = 0;
        
        [params enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            NSString *prefix = (count == 0) ? @"?" : @"&";
            
            NSString *urlSafeKey = [ConnectUtil urlEncode:key];
            NSString *urlSafeValue = [ConnectUtil urlEncode:value];
            
            NSString *appendString = [NSString stringWithFormat:@"%@%@=%@", prefix, urlSafeKey, urlSafeValue];
            queryParams = [queryParams stringByAppendingString:appendString];
            
            count++;
        }];
        
        NSString *targetPath = [NSString stringWithFormat:@"%@%@", targetURL.absoluteString, queryParams];
        targetURL = [NSURL URLWithString:targetPath];
    }

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self target:targetURL payload:nil];
    command.callbackComplete = ^(id responseObject)
    {
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:appInfo.id];
        launchSession.name = appInfo.name;
        launchSession.sessionType = LaunchSessionTypeApp;
        launchSession.service = self;

        if (success)
            success(launchSession);
    };
    command.callbackError = failure;
    [command send];
}

- (void)launchYouTube:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchYouTube:contentId startTime:0.0 success:success failure:failure];
}

- (void) launchYouTube:(NSString *)contentId startTime:(float)startTime success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (self.dialService)
        [self.dialService.launcher launchYouTube:contentId startTime:startTime success:success failure:failure];
    else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:@"Cannot reach DIAL service for launching with provided start time"]);
    }
}

- (void) launchAppStore:(NSString *)appId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    AppInfo *appInfo = [AppInfo appInfoForId:@"11"];
    appInfo.name = @"Channel Store";

    NSDictionary *params;

    if (appId && appId.length > 0)
        params = @{ @"contentId" : appId };

    [self launchAppWithInfo:appInfo params:params success:success failure:failure];
}

- (void)launchBrowser:(NSURL *)target success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)launchHulu:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (void)launchNetflix:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self getAppListWithSuccess:^(NSArray *appList)
    {
        __block AppInfo *foundAppInfo;

        [appList enumerateObjectsUsingBlock:^(AppInfo *appInfo, NSUInteger idx, BOOL *stop)
        {
            if ([appInfo.name isEqualToString:@"Netflix"])
            {
                foundAppInfo = appInfo;
                *stop = YES;
            }
        }];

        if (foundAppInfo)
        {
            NSMutableDictionary *params = [NSMutableDictionary new];
            params[@"mediaType"] = @"movie";
            if (contentId && contentId.length > 0) params[@"contentId"] = contentId;

            [self launchAppWithInfo:foundAppInfo params:params success:success failure:failure];
        } else
        {
            if (failure)
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Netflix app could not be found on TV"]);
        }
    } failure:failure];
}

- (void)closeApp:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self.keyControl homeWithSuccess:success failure:failure];
}

- (void)getAppListWithSuccess:(AppListSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"query"];
    targetURL = [targetURL URLByAppendingPathComponent:@"apps"];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:targetURL payload:nil];
    command.HTTPMethod = @"GET";
    command.callbackComplete = ^(NSString *responseObject)
    {
        NSError *xmlError;
        NSDictionary *appListDictionary = [CTXMLReader dictionaryForXMLString:responseObject error:&xmlError];

        if (appListDictionary) {
            NSArray *apps;
            id appsObject = [appListDictionary valueForKeyPath:@"apps.app"];
            if ([appsObject isKindOfClass:[NSDictionary class]]) {
                apps = @[appsObject];
            } else if ([appsObject isKindOfClass:[NSArray class]]) {
                apps = appsObject;
            }

            NSMutableArray *appList = [NSMutableArray new];

            [apps enumerateObjectsUsingBlock:^(NSDictionary *appInfoDictionary, NSUInteger idx, BOOL *stop)
            {
                AppInfo *appInfo = [self appInfoFromDictionary:appInfoDictionary];
                [appList addObject:appInfo];
            }];

            if (success)
                success([NSArray arrayWithArray:appList]);
        } else {
            if (failure) {
                NSString *details = [NSString stringWithFormat:
                    @"Couldn't parse apps XML (%@)", xmlError.localizedDescription];
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                                 andDetails:details]);
            }
        }
    };
    command.callbackError = failure;
    [command send];
}

- (void)getAppState:(LaunchSession *)launchSession success:(AppStateSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeAppState:(LaunchSession *)launchSession success:(AppStateSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)getRunningAppWithSuccess:(AppInfoSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeRunningAppWithSuccess:(AppInfoSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

#pragma mark - MediaPlayer

- (id <MediaPlayer>)mediaPlayer
{
    return self;
}

- (CapabilityPriorityLevel)mediaPlayerPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)displayImage:(NSURL *)imageURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    MediaInfo *mediaInfo = [[MediaInfo alloc] initWithURL:imageURL mimeType:mimeType];
    mediaInfo.title = title;
    mediaInfo.description = description;
    ImageInfo *imageInfo = [[ImageInfo alloc] initWithURL:iconURL type:ImageTypeThumb];
    [mediaInfo addImage:imageInfo];
    
    [self displayImageWithMediaInfo:mediaInfo success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) displayImage:(MediaInfo *)mediaInfo
              success:(MediaPlayerDisplaySuccessBlock)success
              failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    
    [self displayImage:mediaInfo.url iconURL:iconURL title:mediaInfo.title description:mediaInfo.description mimeType:mediaInfo.mimeType success:success failure:failure];
}

/// The Roku Media Player is a free store channel, not firmware: a Roku Express
/// fresh from the box does not have it (device test 2026-10-22, `query/apps`
/// listed four channels, 2213 absent → `launch/2213` 404). ECP `install/2213`
/// opens its store page on the TV with an "Add channel" prompt; once the user
/// confirms, the launch goes through. So: check `query/apps`, prompt if
/// missing, poll until it appears (or give up with a message), then run `launch`.
/// LocalCast's own Roku channel (store id) and its sideloaded developer copy.
static NSString *const kLocalCastRokuChannel = @"569533";
static NSString *const kRokuDevChannel = @"dev";

/// Our own receiver, if a usable one is installed: the sideloaded `dev` copy
/// first, then the store channel 569533 — but only from major version 2, the
/// SceneGraph rewrite of 2026-10-22 that speaks the t/u/videoName/videoFormat
/// deep link (localcast_roku repo). The 2019 1.0.x channel launches and then
/// plays nothing. nil → use the Roku Media Player path.
static NSString *localCastChannelIn(NSArray *appList)
{
    for (NSString *wanted in @[kRokuDevChannel, kLocalCastRokuChannel]) {
        for (AppInfo *app in appList) {
            if (![app.id isEqualToString:wanted]) continue;
            // appInfoFromDictionary keeps the <app> attributes in rawData; "version" is one of them.
            NSString *version = [app.rawData isKindOfClass:[NSDictionary class]] ? [app.rawData objectForKey:@"version"] : nil;
            NSInteger major = [[version componentsSeparatedByString:@"."].firstObject integerValue];
            if (major >= 2 && [[app.name lowercaseString] containsString:@"localcast"]) return wanted;
        }
    }
    return nil;
}

- (void)ensureReceiverThen:(void (^)(NSString *channel))launch failure:(FailureBlock)failure
{
    [self getAppListWithSuccess:^(NSArray *appList) {
        NSString *own = localCastChannelIn(appList);
        if (own) {
            DLog(@"Roku: using the LocalCast receiver channel %@", own);
            launch(own);
            return;
        }
        for (AppInfo *app in appList) {
            if ([app.id isEqualToString:kRokuMediaPlayerChannel]) {
                launch(kRokuMediaPlayerChannel);
                return;
            }
        }
        DLog(@"Roku: Media Player (2213) not installed — asking the TV to add it");
        NSURL *installURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"install"];
        installURL = [installURL URLByAppendingPathComponent:kRokuMediaPlayerChannel];
        ServiceCommand *install = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:installURL payload:nil];
        install.HTTPMethod = @"POST";
        install.callbackComplete = ^(id responseObject) {
            [self waitForMediaPlayerUntil:[NSDate dateWithTimeIntervalSinceNow:60]
                                     then:^{ launch(kRokuMediaPlayerChannel); }
                                  failure:failure];
        };
        install.callbackError = ^(NSError *error) {
            if (failure)
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                                 andDetails:@"roku_media_player_not_installed: install prompt failed"]);
        };
        [install send];
    } failure:^(NSError *error) {
        // Can't tell — try the launch anyway, the old behaviour.
        launch(kRokuMediaPlayerChannel);
    }];
}

- (void)waitForMediaPlayerUntil:(NSDate *)deadline then:(dispatch_block_t)launch failure:(FailureBlock)failure
{
    if ([deadline timeIntervalSinceNow] <= 0) {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError
                                             andDetails:@"roku_media_player_not_installed: confirm 'Add channel' on the Roku and cast again"]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self getAppListWithSuccess:^(NSArray *appList) {
            for (AppInfo *app in appList) {
                if ([app.id isEqualToString:kRokuMediaPlayerChannel]) {
                    DLog(@"Roku: Media Player installed — launching");
                    launch();
                    return;
                }
            }
            [self waitForMediaPlayerUntil:deadline then:launch failure:failure];
        } failure:^(NSError *error) {
            [self waitForMediaPlayerUntil:deadline then:launch failure:failure];
        }];
    });
}

- (void) displayImageWithMediaInfo:(MediaInfo *)mediaInfo success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    [self ensureReceiverThen:^(NSString *channel) {
        [self launchChannel:channel imageWithMediaInfo:mediaInfo success:success failure:failure];
    } failure:failure];
}

- (void) launchChannel:(NSString *)channel imageWithMediaInfo:(MediaInfo *)mediaInfo success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *imageURL = mediaInfo.url;
    if (!imageURL)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You need to provide a video URL"]);
        
        return;
    }
    
    // Deep-link the built-in Roku Media Player (channel 2213) via ECP
    // `launch`; see playMediaWithMediaInfo for why not `input` into 15985.
    NSString *applicationPath = [NSString stringWithFormat:@"%@?t=p&u=%@&tr=crossfade",
                                 channel,
                                 [ConnectUtil urlEncode:imageURL.absoluteString] // content path
                                 ];

    NSString *commandPath = [NSString pathWithComponents:@[
                                                           self.serviceDescription.commandURL.absoluteString,
                                                           @"launch",
                                                           applicationPath
                                                           ]];

    NSURL *targetURL = [NSURL URLWithString:commandPath];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:targetURL payload:nil];
    command.HTTPMethod = @"POST";
    command.callbackComplete = ^(id responseObject)
    {
        self->_activeChannel = channel;
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:channel];
        launchSession.name = @"Roku Media Player";
        launchSession.sessionType = LaunchSessionTypeMedia;
        launchSession.service = self;
        
        MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:launchSession andMediaControl:self.mediaControl];
        if(success){
            success(launchObject);
        }
    };
    command.callbackError = failure;
    [command send];
}

- (void) playMedia:(NSURL *)mediaURL iconURL:(NSURL *)iconURL title:(NSString *)title description:(NSString *)description mimeType:(NSString *)mimeType shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    MediaInfo *mediaInfo = [[MediaInfo alloc] initWithURL:mediaURL mimeType:mimeType];
    mediaInfo.title = title;
    mediaInfo.description = description;
    ImageInfo *imageInfo = [[ImageInfo alloc] initWithURL:iconURL type:ImageTypeThumb];
    [mediaInfo addImage:imageInfo];
    
    [self playMediaWithMediaInfo:mediaInfo shouldLoop:shouldLoop success:^(MediaLaunchObject *mediaLanchObject) {
        success(mediaLanchObject.session,mediaLanchObject.mediaControl);
    } failure:failure];
}

- (void) playMedia:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerDisplaySuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    [self playMedia:mediaInfo.url iconURL:iconURL title:mediaInfo.title description:mediaInfo.description mimeType:mediaInfo.mimeType shouldLoop:shouldLoop success:success failure:failure];
}

- (void) playMediaWithMediaInfo:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    [self ensureReceiverThen:^(NSString *channel) {
        [self launchChannel:channel withMediaInfo:mediaInfo shouldLoop:shouldLoop success:success failure:failure];
    } failure:failure];
}

- (void) launchChannel:(NSString *)channel withMediaInfo:(MediaInfo *)mediaInfo shouldLoop:(BOOL)shouldLoop success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *iconURL;
    if(mediaInfo.images){
        ImageInfo *imageInfo = [mediaInfo.images firstObject];
        iconURL = imageInfo.url;
    }
    NSURL *mediaURL = mediaInfo.url;
    NSString *mimeType = mediaInfo.mimeType;
    NSString *title = mediaInfo.title;
    NSString *description = mediaInfo.description;
    if (!mediaURL)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You need to provide a media URL"]);
        
        return;
    }
    
    // Deep-link the receiver's built-in Roku Media Player (channel 2213) via
    // ECP `launch`. Connect SDK used to `input` into channel 15985 — its own
    // long-gone receiver app — which every Roku answers 404 (field: 0
    // successes, 2026-10). 2213 ships on every Roku OS and takes the same
    // t/u/videoName/videoFormat/songname parameters; `launch` (not `input`)
    // starts it when it is not running.
    NSString *mediaType = rokuMediaFormat(mimeType, mediaURL);
    NSString *lowerMime = [mimeType lowercaseString] ?: @"";
    BOOL isVideo = [lowerMime hasPrefix:@"video"]
        || [lowerMime containsString:@"mpegurl"]
        || [lowerMime containsString:@"dash+xml"];

    NSString *applicationPath;

    if (isVideo)
    {
        applicationPath = [NSString stringWithFormat:@"%@?t=v&u=%@&k=(null)&videoName=%@&videoFormat=%@",
                           channel,
                           [ConnectUtil urlEncode:mediaURL.absoluteString], // content path
                           title ? [ConnectUtil urlEncode:title] : @"(null)", // video name
                           ensureString(mediaType) // video format
                           ];
    } else
    {
        applicationPath = [NSString stringWithFormat:@"%@?t=a&u=%@&k=(null)&songname=%@&artistname=%@&songformat=%@&albumarturl=%@",
                           channel,
                           [ConnectUtil urlEncode:mediaURL.absoluteString], // content path
                           title ? [ConnectUtil urlEncode:title] : @"(null)", // song name
                           description ? [ConnectUtil urlEncode:description] : @"(null)", // artist name
                           ensureString(mediaType), // audio format
                           iconURL ? [ConnectUtil urlEncode:iconURL.absoluteString] : @"(null)"
                           ];
    }
    // Only the LocalCast receiver reads these (s=, loop=).
    if ([channel isEqualToString:kRokuDevChannel] || [channel isEqualToString:kLocalCastRokuChannel]) {
        NSString *subtitleUrl = mediaInfo.subtitleInfo.url.absoluteString;
        if (subtitleUrl.length > 0) {
            applicationPath = [applicationPath stringByAppendingFormat:@"&s=%@", [ConnectUtil urlEncode:subtitleUrl]];
        }
        if (shouldLoop) applicationPath = [applicationPath stringByAppendingString:@"&loop=1"];
    }

    NSString *commandPath = [NSString pathWithComponents:@[
                                                           self.serviceDescription.commandURL.absoluteString,
                                                           @"launch",
                                                           applicationPath
                                                           ]];

    NSURL *targetURL = [NSURL URLWithString:commandPath];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:targetURL payload:nil];
    command.HTTPMethod = @"POST";
    command.callbackComplete = ^(id responseObject)
    {
        self->_activeChannel = channel;
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:channel];
        launchSession.name = @"Roku Media Player";
        launchSession.sessionType = LaunchSessionTypeMedia;
        launchSession.service = self;
         MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:launchSession andMediaControl:self.mediaControl];
         if(success){
            success(launchObject);
         }
    };
    command.callbackError = failure;
    [command send];
}

- (void)closeMedia:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self.keyControl homeWithSuccess:success failure:failure];
}

#pragma mark - MediaControl

- (id <MediaControl>)mediaControl
{
    return self;
}

- (CapabilityPriorityLevel)mediaControlPriority
{
    return CapabilityPriorityLevelHigh;
}

/// True while playback runs in LocalCast's own receiver (dev sideload or 569533 v2+).
- (BOOL)ownReceiverActive
{
    return [_activeChannel isEqualToString:kRokuDevChannel] || [_activeChannel isEqualToString:kLocalCastRokuChannel];
}

/// LocalCast receiver command over ECP `input` (the channel reads them through
/// roInput): cmd=play|pause|stop|seek&pos=<s>|subtitle. ECP's own keypresses
/// only toggle play/pause and cannot seek.
- (void)sendReceiverCommand:(NSString *)query success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSString *target = [NSString stringWithFormat:@"%@/input?%@", self.serviceDescription.commandURL.absoluteString, query];
    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:[NSURL URLWithString:target] payload:nil];
    command.HTTPMethod = @"POST";
    command.callbackComplete = ^(id responseObject) { if (success) success(responseObject); };
    command.callbackError = failure;
    [command send];
}

- (void)playWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if ([self ownReceiverActive]) {
        [self sendReceiverCommand:@"cmd=play" success:success failure:failure];
        return;
    }
    [self sendKeyCode:RokuKeyCodePlay success:success failure:failure];
}

- (void)pauseWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if ([self ownReceiverActive]) {
        [self sendReceiverCommand:@"cmd=pause" success:success failure:failure];
        return;
    }
    // Roku does not have pause, it only has play/pause
    [self sendKeyCode:RokuKeyCodePlay success:success failure:failure];
}

- (void)stopWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if ([self ownReceiverActive]) {
        [self sendReceiverCommand:@"cmd=stop" success:success failure:failure];
        return;
    }
    // The Roku Media Player leaves playback on Back (its own menu stays up);
    // Home would also work but drops the user out of the channel.
    [self sendKeyCode:RokuKeyCodeBack success:success failure:failure];
}

- (void)rewindWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeRewind success:success failure:failure];
}

- (void)fastForwardWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeFastForward success:success failure:failure];
}

- (void)seek:(NSTimeInterval)position success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if ([self ownReceiverActive]) {
        [self sendReceiverCommand:[NSString stringWithFormat:@"cmd=seek&pos=%.3f", position] success:success failure:failure];
        return;
    }
    // The Roku Media Player has no ECP seek.
    [self sendNotSupportedFailure:failure];
}

- (void)getPlayStateWithSuccess:(MediaPlayStateSuccessBlock)success failure:(FailureBlock)failure
{
    [self queryMediaPlayerWithSuccess:^(NSString *xml) {
        NSString *state = rokuMediaPlayerState(xml);
        MediaControlPlayState playState = MediaControlPlayStateUnknown;
        if ([state isEqualToString:@"play"]) playState = MediaControlPlayStatePlaying;
        else if ([state isEqualToString:@"pause"]) playState = MediaControlPlayStatePaused;
        else if ([state isEqualToString:@"buffer"] || [state isEqualToString:@"open"]) playState = MediaControlPlayStateBuffering;
        else if ([state isEqualToString:@"stop"] || [state isEqualToString:@"close"] || [state isEqualToString:@"none"]) playState = MediaControlPlayStateFinished;
        if (success) success(playState);
    } failure:failure];
}

- (ServiceSubscription *)subscribePlayStateWithSuccess:(MediaPlayStateSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)getDurationWithSuccess:(MediaPositionSuccessBlock)success
                       failure:(FailureBlock)failure {
    [self queryMediaPlayerWithSuccess:^(NSString *xml) {
        NSTimeInterval ms = rokuMediaPlayerMillis(xml, @"duration");
        if (ms < 0) {
            if (failure) failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"No duration in media-player response"]);
            return;
        }
        if (success) success(ms / 1000.0);
    } failure:failure];
}

- (void)getPositionWithSuccess:(MediaPositionSuccessBlock)success failure:(FailureBlock)failure
{
    [self queryMediaPlayerWithSuccess:^(NSString *xml) {
        NSTimeInterval ms = rokuMediaPlayerMillis(xml, @"position");
        if (ms < 0) {
            if (failure) failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"No position in media-player response"]);
            return;
        }
        if (success) success(ms / 1000.0);
    } failure:failure];
}

/// `GET /query/media-player`: the receiver's current playback — state
/// attribute (play/pause/stop/buffer/none), position and duration as
/// "12345 ms". Works for whatever channel is playing, so for the Roku
/// Media Player we launched.
- (void)queryMediaPlayerWithSuccess:(void (^)(NSString *xml))success failure:(FailureBlock)failure
{
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"query"];
    targetURL = [targetURL URLByAppendingPathComponent:@"media-player"];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.serviceCommandDelegate target:targetURL payload:nil];
    command.HTTPMethod = @"GET";
    command.callbackComplete = ^(id responseObject)
    {
        NSString *xml = [responseObject isKindOfClass:[NSString class]] ? responseObject
            : ([responseObject isKindOfClass:[NSData class]]
               ? [[NSString alloc] initWithData:responseObject encoding:NSUTF8StringEncoding] : @"");
        if (success) success(xml ?: @"");
    };
    command.callbackError = failure;
    [command send];
}

- (void)getMediaMetaDataWithSuccess:(SuccessBlock)success
                            failure:(FailureBlock)failure {
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeMediaInfoWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

#pragma mark - Key Control

- (id <KeyControl>) keyControl
{
    return self;
}

- (CapabilityPriorityLevel) keyControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)upWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeUp success:success failure:failure];
}

- (void)downWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeDown success:success failure:failure];
}

- (void)leftWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeLeft success:success failure:failure];
}

- (void)rightWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeRight success:success failure:failure];
}

- (void)homeWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeHome success:success failure:failure];
}

- (void)backWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeBack success:success failure:failure];
}

- (void)okWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeSelect success:success failure:failure];
}

- (void)sendKeyCode:(RokuKeyCode)keyCode success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (keyCode > kRokuKeyCodes.count)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:nil]);
        return;
    }

    NSString *keyCodeString = kRokuKeyCodes[keyCode];

    [self sendKeyPress:keyCodeString success:success failure:failure];
}

#pragma mark - Text Input Control

- (id <TextInputControl>) textInputControl
{
    return self;
}

- (CapabilityPriorityLevel) textInputControlPriority
{
    return CapabilityPriorityLevelNormal;
}

- (void) sendText:(NSString *)input success:(SuccessBlock)success failure:(FailureBlock)failure
{
    // TODO: optimize this with queueing similiar to webOS and Netcast services
    NSMutableArray *stringToSend = [NSMutableArray new];

    [input enumerateSubstringsInRange:NSMakeRange(0, input.length) options:(NSStringEnumerationByComposedCharacterSequences) usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop)
    {
        [stringToSend addObject:substring];
    }];

    [stringToSend enumerateObjectsUsingBlock:^(NSString *charToSend, NSUInteger idx, BOOL *stop)
    {

        NSString *codeToSend = [NSString stringWithFormat:@"%@%@", kRokuKeyCodes[RokuKeyCodeLiteral], [ConnectUtil urlEncode:charToSend]];

        [self sendKeyPress:codeToSend success:success failure:failure];
    }];
}

- (void)sendEnterWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeEnter success:success failure:failure];
}

- (void)sendDeleteWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendKeyCode:RokuKeyCodeBackspace success:success failure:failure];
}

- (ServiceSubscription *) subscribeTextInputStatusWithSuccess:(TextInputStatusInfoSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

#pragma mark - Helper methods

- (void) sendKeyPress:(NSString *)keyCode success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *targetURL = [self.serviceDescription.commandURL URLByAppendingPathComponent:@"keypress"];
    targetURL = [NSURL URLWithString:[targetURL.absoluteString stringByAppendingPathComponent:keyCode]];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self target:targetURL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (AppInfo *)appInfoFromDictionary:(NSDictionary *)appDictionary
{
    NSString *id = [appDictionary objectForKey:@"id"];
    NSString *name = [appDictionary objectForKey:@"text"];

    AppInfo *appInfo = [AppInfo appInfoForId:id];
    appInfo.name = name;
    appInfo.rawData = [appDictionary copy];

    return appInfo;
}

- (void) hasApp:(NSString *)appName success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self.launcher getAppListWithSuccess:^(NSArray *appList)
    {
        if (appList)
        {
            __block AppInfo *foundAppInfo;

            [appList enumerateObjectsUsingBlock:^(AppInfo *appInfo, NSUInteger idx, BOOL *stop)
            {
                if ([appInfo.name isEqualToString:appName])
                {
                    foundAppInfo = appInfo;
                    *stop = YES;
                }
            }];

            if (foundAppInfo)
            {
                if (success)
                    success(foundAppInfo);
            } else
            {
                if (failure)
                    failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Could not find this app on the TV"]);
            }
        } else
        {
            if (failure)
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:@"Could not find any apps on the TV."]);
        }
    } failure:failure];
}

@end
