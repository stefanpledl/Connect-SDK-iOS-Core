//
//  WebOSService.m
//  Connect SDK
//
//  Created by Jeremy White on 12/2/13.
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

#import "WebOSTVService_Private.h"
#import "ConnectError.h"
#import "DiscoveryManager.h"
#import "ServiceAsyncCommand.h"
#import "WebOSWebAppSession.h"
#import "WebOSTVServiceSocketClient.h"
#import "CTGuid.h"
#import "CommonMacros.h"
#import "NSMutableDictionary+NilSafe.h"
#import "NSObject+FeatureNotSupported_Private.h"
#import "CTXMLReader.h"
#import "RemoteCameraService.h"
#import "ScreenMirroringService.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#define kKeyboardEnter @"\x1b ENTER \x1b"
#define kKeyboardDelete @"\x1b DELETE \x1b"

@interface WebOSTVService () <UIAlertViewDelegate, WebOSTVServiceSocketClientDelegate, RemoteCameraServiceDelegate, ScreenMirroringServiceDelegate>
{
    NSArray *_permissions;

    NSMutableDictionary *_webAppSessions;
    NSMutableDictionary *_appToAppIdMappings;

    NSTimer *_pairingTimer;
    UIAlertView *_pairingAlert;

    NSMutableArray *_keyboardQueue;
    BOOL _keyboardQueueProcessing;

    BOOL _mouseInit;
    UIAlertView *_pinAlertView;

    __weak id<RemoteCameraControlDelegate> _remoteCameraDelegate;
    __weak id<ScreenMirroringControlDelegate> _screenMirroringDelegate;

    NSURL *_avTransportControlURL;
    NSDate *_playbackStartTime;
    NSTimeInterval _playbackPausedPosition;
    BOOL _playbackPaused;
}

@end

@implementation WebOSTVService

@synthesize serviceDescription = _serviceDescription, pairingType = _pairingType;

#pragma mark - Setup

- (instancetype) initWithServiceConfig:(ServiceConfig *)serviceConfig
{
    self = [super init];

    if (self)
    {
        [self setServiceConfig:serviceConfig];
    }

    return self;
}

#pragma mark - Getters & Setters

- (void) setPairingType:(DeviceServicePairingType)pairingType {
    _pairingType = pairingType;
}

- (DeviceServicePairingType)pairingType{
    DeviceServicePairingType pairingType = DeviceServicePairingTypeNone;
    if ([DiscoveryManager sharedManager].pairingLevel == DeviceServicePairingLevelOn)
    {
        pairingType = _pairingType!=DeviceServicePairingTypeNone ? _pairingType : DeviceServicePairingTypeFirstScreen;
    }
    return pairingType;
}

- (WebOSTVServiceConfig *)webOSTVServiceConfig {
    return ([self.serviceConfig isKindOfClass:[WebOSTVServiceConfig class]] ?
            (WebOSTVServiceConfig *)self.serviceConfig :
            nil);
}

- (id<ServiceCommandDelegate>)serviceCommandDelegate {
    return _serviceCommandDelegate ?: self.socket;
}

#pragma mark - Inherited methods

- (void) setServiceConfig:(ServiceConfig *)serviceConfig
{
    const BOOL oldServiceConfigHasKey = (self.webOSTVServiceConfig.clientKey != nil);
    if ([serviceConfig isKindOfClass:[WebOSTVServiceConfig class]])
    {
        const BOOL newServiceConfigHasKey = (((WebOSTVServiceConfig *)serviceConfig).clientKey != nil);
        const BOOL wouldLoseKey = oldServiceConfigHasKey && !newServiceConfigHasKey;
        _assert_state(!wouldLoseKey, @"Losing important data!");

        [super setServiceConfig:serviceConfig];
    } else
    {
        _assert_state(!oldServiceConfigHasKey, @"Losing important data!");

        [super setServiceConfig:[[WebOSTVServiceConfig alloc] initWithServiceConfig:serviceConfig]];
    }
}

- (void) setServiceDescription:(ServiceDescription *)serviceDescription
{
    _serviceDescription = serviceDescription;

    if (!self.serviceConfig.UUID)
        self.serviceConfig.UUID = serviceDescription.UUID;

    if (!_serviceDescription.locationResponseHeaders)
        return;

    NSString *serverInfo = [_serviceDescription.locationResponseHeaders objectForKey:@"Server"];
    NSString *systemOS = [[serverInfo componentsSeparatedByString:@" "] firstObject];
    NSString *systemVersion = [[systemOS componentsSeparatedByString:@"/"] lastObject];

    _serviceDescription.version = systemVersion;

    [self updateCapabilities];
    [self updateAVTransportControlURL];
}

- (DeviceService *)dlnaService
{
    NSDictionary *allDevices = [[DiscoveryManager sharedManager] allDevices];
    ConnectableDevice *device;
    DeviceService *service;

    if (allDevices && allDevices.count > 0)
        device = [allDevices objectForKey:self.serviceDescription.address];

    if (device)
        service = [device serviceWithName:@"DLNA"];

    return service;
}

#pragma mark - AVTransport (Direct SOAP)

- (void)updateAVTransportControlURL
{
    _avTransportControlURL = nil;

    // Try 1: Parse from the device description's service list
    NSArray *serviceList = self.serviceDescription.serviceList;
    NSLog(@"[WebOS_AVT] serviceList count: %lu, commandURL: %@",
          (unsigned long)serviceList.count, self.serviceDescription.commandURL);

    if (serviceList) {
        for (NSDictionary *service in serviceList) {
            NSString *serviceId = service[@"serviceId"][@"text"];
            NSString *serviceType = service[@"serviceType"][@"text"];
            NSLog(@"[WebOS_AVT]   service: id=%@, type=%@", serviceId, serviceType);
            if ((serviceId && [serviceId rangeOfString:@":AVTransport"].location != NSNotFound) ||
                (serviceType && [serviceType rangeOfString:@":AVTransport"].location != NSNotFound))
            {
                NSString *controlPath = service[@"controlURL"][@"text"];
                if (controlPath) {
                    if (![controlPath hasPrefix:@"/"])
                        controlPath = [NSString stringWithFormat:@"/%@", controlPath];
                    NSURL *commandURL = self.serviceDescription.commandURL;
                    if (commandURL) {
                        NSString *urlString = [NSString stringWithFormat:@"http://%@:%@%@",
                                               commandURL.host, commandURL.port, controlPath];
                        _avTransportControlURL = [NSURL URLWithString:urlString];
                        NSLog(@"[WebOS_AVT] Found AVTransport from serviceList: %@", _avTransportControlURL);
                    }
                }
                break;
            }
        }
    }

    // Try 2: Parse embedded devices in locationXML for AVTransport
    if (!_avTransportControlURL && self.serviceDescription.locationXML) {
        NSLog(@"[WebOS_AVT] Parsing locationXML for embedded MediaRenderer...");
        NSError *xmlError;
        NSDictionary *xmlDict = [CTXMLReader dictionaryForXMLString:self.serviceDescription.locationXML error:&xmlError];
        if (!xmlError) {
            NSDictionary *root = xmlDict[@"root"];
            id device = root[@"device"];
            // Check root device
            NSString *controlPath = [self findAVTransportControlInDevice:device];
            // Check embedded devices
            if (!controlPath) {
                id devices = device[@"deviceList"][@"device"];
                NSArray *deviceArray = nil;
                if ([devices isKindOfClass:[NSArray class]]) deviceArray = devices;
                else if ([devices isKindOfClass:[NSDictionary class]]) deviceArray = @[devices];
                for (NSDictionary *embeddedDevice in deviceArray) {
                    NSString *deviceType = embeddedDevice[@"deviceType"][@"text"];
                    NSLog(@"[WebOS_AVT]   Embedded device: %@", deviceType);
                    controlPath = [self findAVTransportControlInDevice:embeddedDevice];
                    if (controlPath) break;
                }
            }
            if (controlPath) {
                if (![controlPath hasPrefix:@"/"]) controlPath = [@"/" stringByAppendingString:controlPath];
                NSString *host = self.serviceDescription.address;
                NSURL *cmdURL = self.serviceDescription.commandURL;
                NSString *urlStr = [NSString stringWithFormat:@"http://%@:%@%@",
                                    host, cmdURL.port ?: @(3001), controlPath];
                _avTransportControlURL = [NSURL URLWithString:urlStr];
                NSLog(@"[WebOS_AVT] Found AVTransport from locationXML: %@", _avTransportControlURL);
            } else {
                NSLog(@"[WebOS_AVT] No AVTransport in locationXML embedded devices");
            }
        }
    }

    // Note: SSDP-based discovery of DLNA renderer happens in socketDidConnect
    // after the WebSocket connects, via discoverDLNARendererViaSsdp
}

// Send a unicast SSDP M-SEARCH to the TV to discover its DLNA MediaRenderer
- (void)discoverDLNARendererViaSsdp
{
    NSString *address = self.serviceDescription.address;
    NSLog(@"[WebOS_AVT] Starting SSDP M-SEARCH for MediaRenderer on %@", address);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock < 0) {
            NSLog(@"[WebOS_AVT] Failed to create UDP socket");
            return;
        }

        // Set receive timeout to 4 seconds
        struct timeval tv;
        tv.tv_sec = 4;
        tv.tv_usec = 0;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        // Send unicast M-SEARCH to the TV's IP
        struct sockaddr_in destAddr;
        memset(&destAddr, 0, sizeof(destAddr));
        destAddr.sin_family = AF_INET;
        destAddr.sin_port = htons(1900);
        inet_pton(AF_INET, [address UTF8String], &destAddr.sin_addr);

        NSString *search = [NSString stringWithFormat:
            @"M-SEARCH * HTTP/1.1\r\n"
            @"HOST: %@:1900\r\n"
            @"MAN: \"ssdp:discover\"\r\n"
            @"MX: 3\r\n"
            @"ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n",
            address];

        const char *msg = [search UTF8String];
        sendto(sock, msg, strlen(msg), 0, (struct sockaddr *)&destAddr, sizeof(destAddr));

        // Also try multicast
        struct sockaddr_in mcastAddr;
        memset(&mcastAddr, 0, sizeof(mcastAddr));
        mcastAddr.sin_family = AF_INET;
        mcastAddr.sin_port = htons(1900);
        inet_pton(AF_INET, "239.255.255.250", &mcastAddr.sin_addr);

        NSString *mcastSearch =
            @"M-SEARCH * HTTP/1.1\r\n"
            @"HOST: 239.255.255.250:1900\r\n"
            @"MAN: \"ssdp:discover\"\r\n"
            @"MX: 3\r\n"
            @"ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
        const char *mcastMsg = [mcastSearch UTF8String];
        sendto(sock, mcastMsg, strlen(mcastMsg), 0, (struct sockaddr *)&mcastAddr, sizeof(mcastAddr));

        // Read responses — filter by TV's IP address
        char buffer[4096];
        NSString *foundLocation = nil;
        struct sockaddr_in senderAddr;
        socklen_t senderLen = sizeof(senderAddr);

        for (int i = 0; i < 10; i++) {
            senderLen = sizeof(senderAddr);
            memset(&senderAddr, 0, sizeof(senderAddr));
            ssize_t received = recvfrom(sock, buffer, sizeof(buffer) - 1, 0,
                                        (struct sockaddr *)&senderAddr, &senderLen);
            if (received <= 0) break;
            buffer[received] = '\0';

            // Get sender IP
            char senderIP[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &senderAddr.sin_addr, senderIP, sizeof(senderIP));
            NSString *senderIPStr = [NSString stringWithUTF8String:senderIP];
            NSString *response = [NSString stringWithUTF8String:buffer];

            NSLog(@"[WebOS_AVT] SSDP response from %@ (looking for %@)", senderIPStr, address);

            // CRITICAL: Only accept responses from the TV's IP address
            if (![senderIPStr isEqualToString:address]) {
                // Also check LOCATION URL host as secondary filter
                NSRegularExpression *locRegex = [NSRegularExpression
                    regularExpressionWithPattern:@"LOCATION:\\s*(http[^\\r\\n]*)"
                    options:NSRegularExpressionCaseInsensitive error:nil];
                NSTextCheckingResult *locMatch = [locRegex firstMatchInString:response
                    options:0 range:NSMakeRange(0, response.length)];
                if (locMatch && locMatch.numberOfRanges > 1) {
                    NSString *loc = [response substringWithRange:[locMatch rangeAtIndex:1]];
                    NSURL *locURL = [NSURL URLWithString:loc];
                    if ([locURL.host isEqualToString:address]) {
                        NSLog(@"[WebOS_AVT] LOCATION host matches TV — accepting");
                    } else {
                        NSLog(@"[WebOS_AVT] Ignoring response from %@ (LOCATION: %@)", senderIPStr, loc);
                        continue;
                    }
                } else {
                    NSLog(@"[WebOS_AVT] Ignoring response from %@ (not TV)", senderIPStr);
                    continue;
                }
            }

            NSLog(@"[WebOS_AVT] SSDP response from TV:\n%@", response);

            // Extract LOCATION header
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"LOCATION:\\s*(http[^\\r\\n]*)"
                options:NSRegularExpressionCaseInsensitive error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:response
                options:0 range:NSMakeRange(0, response.length)];
            if (match && match.numberOfRanges > 1) {
                foundLocation = [response substringWithRange:[match rangeAtIndex:1]];
                NSLog(@"[WebOS_AVT] Found MediaRenderer location from TV: %@", foundLocation);
                break;
            }
        }
        close(sock);

        if (foundLocation) {
            NSURL *locationURL = [NSURL URLWithString:foundLocation];
            [self fetchMediaRendererDescription:locationURL];
        } else {
            NSLog(@"[WebOS_AVT] No MediaRenderer found via SSDP from TV at %@", address);
        }
    });
}

- (void)fetchMediaRendererDescription:(NSURL *)locationURL
{
    NSLog(@"[WebOS_AVT] Fetching MediaRenderer description from %@", locationURL);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:locationURL
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) {
                NSLog(@"[WebOS_AVT] Failed to fetch MediaRenderer description: %@", error);
                return;
            }

            NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"[WebOS_AVT] MediaRenderer XML (first 500 chars): %@",
                  [xml substringToIndex:MIN(500, xml.length)]);

            // Parse the XML to find AVTransport controlURL
            NSError *parseError;
            NSDictionary *dict = [CTXMLReader dictionaryForXMLString:xml error:&parseError];
            if (parseError) {
                NSLog(@"[WebOS_AVT] XML parse error: %@", parseError);
                return;
            }

            // Navigate: root > device > serviceList > service
            NSDictionary *root = dict[@"root"];
            id device = root[@"device"];

            // Check root device services
            NSString *controlPath = [self findAVTransportControlInDevice:device];

            // Check embedded devices if not found
            if (!controlPath) {
                id devices = device[@"deviceList"][@"device"];
                NSArray *deviceArray = nil;
                if ([devices isKindOfClass:[NSArray class]]) deviceArray = devices;
                else if ([devices isKindOfClass:[NSDictionary class]]) deviceArray = @[devices];

                for (NSDictionary *embeddedDevice in deviceArray) {
                    controlPath = [self findAVTransportControlInDevice:embeddedDevice];
                    if (controlPath) break;
                }
            }

            if (controlPath) {
                // Construct full URL relative to the location URL
                if (![controlPath hasPrefix:@"/"]) controlPath = [@"/" stringByAppendingString:controlPath];
                NSString *urlStr = [NSString stringWithFormat:@"http://%@:%@%@",
                                    locationURL.host, locationURL.port, controlPath];
                NSURL *avtURL = [NSURL URLWithString:urlStr];

                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_avTransportControlURL = avtURL;
                    NSLog(@"[WebOS_AVT] SSDP discovery SUCCESS! AVTransport URL: %@", avtURL);
                });
            } else {
                NSLog(@"[WebOS_AVT] No AVTransport service found in MediaRenderer description");
            }
        }];
    [task resume];
}

- (NSString *)findAVTransportControlInDevice:(NSDictionary *)device
{
    id services = device[@"serviceList"][@"service"];
    NSArray *serviceArray = nil;
    if ([services isKindOfClass:[NSArray class]]) serviceArray = services;
    else if ([services isKindOfClass:[NSDictionary class]]) serviceArray = @[services];

    for (NSDictionary *svc in serviceArray) {
        NSString *serviceType = svc[@"serviceType"][@"text"];
        if (serviceType && [serviceType containsString:@"AVTransport"]) {
            return svc[@"controlURL"][@"text"];
        }
    }
    return nil;
}

- (void)sendAVTransportSOAP:(NSString *)action
                 soapAction:(NSString *)soapAction
                   extraXML:(NSString *)extraXML
                    success:(void (^)(NSString *responseXML))success
                    failure:(FailureBlock)failure
{
    if (!_avTransportControlURL) {
        if (failure) failure([ConnectError generateErrorWithCode:ConnectStatusCodeNotSupported andDetails:@"AVTransport URL not available"]);
        return;
    }

    NSString *soapXML = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        @"<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
        @"s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
        @"<s:Body>"
        @"<u:%@ xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
        @"<InstanceID>0</InstanceID>"
        @"%@"
        @"</u:%@>"
        @"</s:Body>"
        @"</s:Envelope>",
        action, extraXML ?: @"", action];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_avTransportControlURL];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"text/xml; charset=\"utf-8\"" forHTTPHeaderField:@"Content-Type"];
    [request setValue:soapAction forHTTPHeaderField:@"SOAPAction"];
    [request setHTTPBody:[soapXML dataUsingEncoding:NSUTF8StringEncoding]];
    [request setTimeoutInterval:5.0];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    if (failure) failure(error);
                    return;
                }
                NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (success) success(xml);
            });
        }];
    [task resume];
}

- (NSString *)extractXMLValue:(NSString *)tagName fromXML:(NSString *)xml
{
    // Match <tagName>value</tagName> or <namespace:tagName>value</namespace:tagName>
    NSString *pattern = [NSString stringWithFormat:@"<(?:[^:>]*:)?%@[^>]*>([^<]*)</(?:[^:>]*:)?%@>", tagName, tagName];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (match && match.numberOfRanges > 1) {
        return [xml substringWithRange:[match rangeAtIndex:1]];
    }
    return nil;
}

- (NSTimeInterval)avtTimeIntervalFromString:(NSString *)timeString
{
    if (!timeString || [timeString isEqualToString:@"NOT_IMPLEMENTED"]) return 0;
    NSArray *parts = [timeString componentsSeparatedByString:@":"];
    if (parts.count != 3) return 0;
    return [parts[0] doubleValue] * 3600.0 + [parts[1] doubleValue] * 60.0 + [parts[2] doubleValue];
}

- (NSString *)avtStringFromTimeInterval:(NSTimeInterval)interval
{
    int hours = (int)(interval / 3600);
    int minutes = (int)((interval - hours * 3600) / 60);
    int seconds = (int)(interval - hours * 3600 - minutes * 60);
    return [NSString stringWithFormat:@"%02d:%02d:%02d", hours, minutes, seconds];
}

- (NSTimeInterval)estimatedPlaybackPosition
{
    if (!_playbackStartTime) return 0;
    if (_playbackPaused) return _playbackPausedPosition;
    return -[_playbackStartTime timeIntervalSinceNow];
}

typedef NSTimeInterval (^SSAPMediaExtractor)(NSDictionary *response);

- (void)trySSAPMediaQuery:(NSArray<NSString *> *)uris
                  atIndex:(NSUInteger)index
                extractor:(SSAPMediaExtractor)extractor
                  success:(void (^)(NSTimeInterval))success
                  failure:(FailureBlock)failure
{
    if (index >= uris.count) {
        // All endpoints failed
        if (success) success(0);
        return;
    }

    NSURL *URL = [NSURL URLWithString:uris[index]];
    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *response) {
        NSTimeInterval value = extractor(response);
        if (success) success(value);
    };
    command.callbackError = ^(NSError *error) {
        NSLog(@"[WebOS_AVT] SSAP query failed: %@ — %@", uris[index], error.localizedDescription);
        [self trySSAPMediaQuery:uris atIndex:index + 1 extractor:extractor success:success failure:failure];
    };
    [command send];
}

- (void) updateCapabilities
{
    NSArray *capabilities = [NSArray array];

    if ([DiscoveryManager sharedManager].pairingLevel == DeviceServicePairingLevelOn)
    {
        capabilities = [capabilities arrayByAddingObjectsFromArray:@[
                kKeyControlSendKeyCode,
                kKeyControlUp,
                kKeyControlDown,
                kKeyControlLeft,
                kKeyControlRight,
                kKeyControlHome,
                kKeyControlBack,
                kKeyControlOK
        ]];

        capabilities = [capabilities arrayByAddingObjectsFromArray:kMouseControlCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kTextInputControlCapabilities];
        capabilities = [capabilities arrayByAddingObject:kPowerControlOff];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kMediaPlayerCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kLauncherCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kTVControlCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kExternalInputControlCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kVolumeControlCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kToastControlCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kMediaControlCapabilities];
    } else
    {
        capabilities = [capabilities arrayByAddingObjectsFromArray:kMediaPlayerCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kMediaControlCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:kVolumeControlCapabilities];
        capabilities = [capabilities arrayByAddingObjectsFromArray:@[
                kLauncherApp,
                kLauncherAppParams,
                kLauncherAppStore,
                kLauncherAppStoreParams
                kLauncherAppClose,
                kLauncherBrowser,
                kLauncherBrowserParams,
                kLauncherHulu,
                kLauncherNetflix,
                kLauncherNetflixParams,
                kLauncherYouTube,
                kLauncherYouTubeParams,
                kLauncherAppState,
                kLauncherAppStateSubscribe
        ]];
    }

    if (_serviceDescription && _serviceDescription.version)
    {
        const BOOL isVersion400 = [_serviceDescription.version rangeOfString:@"4.0.0"].location != NSNotFound;
        const BOOL isVersion401 = [_serviceDescription.version rangeOfString:@"4.0.1"].location != NSNotFound;
        const BOOL isLegacyVersion = isVersion400 || isVersion401;
        if (!isLegacyVersion)
        {
            capabilities = [capabilities arrayByAddingObjectsFromArray:kWebAppLauncherCapabilities];
            capabilities = [capabilities arrayByAddingObjectsFromArray:kMediaControlCapabilities];
            capabilities = [capabilities arrayByAddingObjectsFromArray:kPlayListControlCapabilities];
            capabilities = [capabilities arrayByAddingObjectsFromArray:@[kMediaPlayerPlayPlaylist,kMediaPlayerLoop]];
            capabilities = [capabilities arrayByAddingObject:kMediaPlayerSubtitleWebVTT];
        } else
        {
            capabilities = [capabilities arrayByAddingObjectsFromArray:@[
                    kWebAppLauncherLaunch,
                    kWebAppLauncherLaunchParams,

                    kMediaControlPlay,
                    kMediaControlPause,
                    kMediaControlStop,
                    kMediaControlSeek,
                    kMediaControlPosition,
                    kMediaControlDuration,
                    kMediaControlPlayState,

                    kWebAppLauncherClose
            ]];

            if (self.dlnaService) {
                capabilities = [capabilities arrayByAddingObject:kMediaPlayerSubtitleSRT];
            }
        }

        if (_serviceDescription.locationXML) {
            NSError *locationXMLParseError;
            NSDictionary *locationXMLDic = [CTXMLReader dictionaryForXMLString:_serviceDescription.locationXML error:&locationXMLParseError];

            if (!locationXMLParseError) {
                NSDictionary *deviceDic = [[locationXMLDic objectForKey:@"root"] objectForKey:@"device"];
                NSString *appCastingFeature = [[deviceDic objectForKey:@"supportAppcastingFeatures"] objectForKey:@"text"];

                if (!appCastingFeature) {
                    NSString *appCasting = [[deviceDic objectForKey:@"appCasting"] objectForKey:@"text"];
                    if ([@"support" isEqualToString:appCasting]) {
                        capabilities = [capabilities arrayByAddingObject:kScreenMirroringControlScreenMirroring];
                    }
                } else {
                    if ([appCastingFeature rangeOfString:@"mirroring"].location != NSNotFound) {
                        capabilities = [capabilities arrayByAddingObject:kScreenMirroringControlScreenMirroring];
                    }
                    if ([appCastingFeature rangeOfString:@"remote-camera"].location != NSNotFound) {
                        capabilities = [capabilities arrayByAddingObject:kRemoteCameraControlRemoteCamera];
                    }
                }
            }
        }
    } else {
        capabilities = [capabilities arrayByAddingObject:kMediaPlayerSubtitleWebVTT];
    }

    [self setCapabilities:capabilities];
}

+ (NSDictionary *) discoveryParameters
{
    return @{
             @"serviceId": kConnectSDKWebOSTVServiceId,
             @"ssdp":@{
                     @"filter":@"urn:lge-com:service:webos-second-screen:1"
                  }
             };
}

- (BOOL) isConnectable
{
    return YES;
}

- (BOOL) connected
{
    if ([DiscoveryManager sharedManager].pairingLevel == DeviceServicePairingLevelOn)
        return self.socket.connected && (self.webOSTVServiceConfig.clientKey != nil);
    else
        return self.socket.connected;
}

- (void) connect
{
    if (!self.socket)
    {
        _socket = [[WebOSTVServiceSocketClient alloc] initWithService:self];
        _socket.delegate = self;
    }

    if (!self.connected)
        [self.socket connect];
}

- (void) disconnect
{
    [self disconnectWithError:nil];
}

- (void) disconnectWithError:(NSError *)error
{
    [self.socket disconnectWithError:error];

    [_webAppSessions enumerateKeysAndObjectsUsingBlock:^(id key, WebOSWebAppSession *session, BOOL *stop) {
        [session disconnectFromWebApp];
    }];

    _webAppSessions = [NSMutableDictionary new];
}

#pragma mark - Initial connection & pairing

- (BOOL) requiresPairing
{
    return [DiscoveryManager sharedManager].pairingLevel == DeviceServicePairingLevelOn;
}

#pragma mark - Paring alert

-(void) showAlert
{
    NSString *title = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_Title" value:@"Pairing with device" table:@"ConnectSDK"];
    NSString *message = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_Request" value:@"Please confirm the connection on your device" table:@"ConnectSDK"];
    NSString *ok = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_OK" value:@"OK" table:@"ConnectSDK"];
    NSString *cancel = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_Cancel" value:@"Cancel" table:@"ConnectSDK"];
    
    _pairingAlert = [[UIAlertView alloc] initWithTitle:title message:message delegate:self cancelButtonTitle:cancel otherButtonTitles:ok, nil];
    if(self.pairingType == DeviceServicePairingTypePinCode || self.pairingType == DeviceServicePairingTypeMixed){
        _pairingAlert.alertViewStyle = UIAlertViewStylePlainTextInput;
        _pairingAlert.message = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_Request_Pin" value:@"Please enter the pin code" table:@"ConnectSDK"];
    }
    dispatch_on_main(^{ [_pairingAlert show]; });
}

-(void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    if(alertView == _pairingAlert){
        if (buttonIndex == 0){
            [self disconnect];
        }else
            if((self.pairingType == DeviceServicePairingTypePinCode || self.pairingType == DeviceServicePairingTypeMixed) && buttonIndex == 1){
                NSString *pairingCode = [alertView textFieldAtIndex:0].text;
                [self sendPairingKey:pairingCode success:nil failure:nil];
            }
    }
}

-(void) showAlertWithTitle:(NSString *)title andMessage:(NSString *)message
{
    NSString *alertTitle = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_Title" value:title table:@"ConnectSDK"];
    NSString *alertMessage = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_Request" value:message table:@"ConnectSDK"];
    NSString *ok = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Pair_OK" value:@"OK" table:@"ConnectSDK"];
    if(!_pinAlertView){
        _pinAlertView = [[UIAlertView alloc] initWithTitle:alertTitle message:alertMessage delegate:self cancelButtonTitle:nil otherButtonTitles:ok, nil];
    }
    dispatch_on_main(^{ [_pinAlertView show]; });
}

-(void)dismissPinAlertView{
    if (_pinAlertView && _pinAlertView.isVisible){
        [_pinAlertView dismissWithClickedButtonIndex:0 animated:NO];
    }
}

#pragma mark - WebOSTVServiceSocketClientDelegate

- (void) socketWillRegister:(WebOSTVServiceSocketClient *)socket
{
    _pairingTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(showAlert) userInfo:nil repeats:NO];
}

- (void) socket:(WebOSTVServiceSocketClient *)socket registrationFailed:(NSError *)error
{
    if (_pairingAlert && _pairingAlert.isVisible)
        dispatch_on_main(^{ [_pairingAlert dismissWithClickedButtonIndex:0 animated:NO]; });

    if (self.delegate && [self.delegate respondsToSelector:@selector(deviceService:pairingFailedWithError:)])
        dispatch_on_main(^{ [self.delegate deviceService:self pairingFailedWithError:error]; });

    [self disconnect];
}

- (void) socketDidConnect:(WebOSTVServiceSocketClient *)socket
{
    [_pairingTimer invalidate];

    if (_pairingAlert && _pairingAlert.visible)
        dispatch_on_main(^{ [_pairingAlert dismissWithClickedButtonIndex:1 animated:YES]; });

    if ([self.delegate respondsToSelector:@selector(deviceServicePairingSuccess:)])
        dispatch_on_main(^{ [self.delegate deviceServicePairingSuccess:self]; });

    if ([self.delegate respondsToSelector:@selector(deviceServiceConnectionSuccess:)])
        dispatch_on_main(^{ [self.delegate deviceServiceConnectionSuccess:self]; });

    // Log available SSAP services for media control discovery
    [self discoverSSAPMediaEndpoints];

    // Discover the TV's DLNA MediaRenderer via SSDP M-SEARCH (for position/duration)
    if (!_avTransportControlURL) {
        [self discoverDLNARendererViaSsdp];
    }
}

- (void)discoverSSAPMediaEndpoints
{
    NSURL *URL = [NSURL URLWithString:@"ssap://api/getServiceList"];
    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *response) {
        NSArray *services = response[@"services"];
        NSLog(@"[WebOS_AVT] === Available SSAP services (%lu) ===", (unsigned long)services.count);
        for (NSDictionary *svc in services) {
            NSString *name = svc[@"name"];
            // Log media-related services
            if ([name containsString:@"media"] || [name containsString:@"Media"] ||
                [name containsString:@"play"] || [name containsString:@"Play"] ||
                [name containsString:@"avt"] || [name containsString:@"AVT"] ||
                [name containsString:@"transport"] || [name containsString:@"dmr"] ||
                [name containsString:@"controller"])
            {
                NSLog(@"[WebOS_AVT]   ** %@", svc);
            }
        }
        NSLog(@"[WebOS_AVT] === All services: %@ ===", [services valueForKey:@"name"]);
    };
    command.callbackError = ^(NSError *error) {
        NSLog(@"[WebOS_AVT] getServiceList error: %@", error);
    };
    [command send];
}

- (void) socket:(WebOSTVServiceSocketClient *)socket didFailWithError:(NSError *)error
{
    if (_pairingAlert && _pairingAlert.visible)
        dispatch_on_main(^{ [_pairingAlert dismissWithClickedButtonIndex:0 animated:YES]; });

    if ([self.delegate respondsToSelector:@selector(deviceService:didFailConnectWithError:)])
        dispatch_on_main(^{ [self.delegate deviceService:self didFailConnectWithError:error]; });
}

- (void) socket:(WebOSTVServiceSocketClient *)socket didCloseWithError:(NSError *)error
{
    if ([self.delegate respondsToSelector:@selector(deviceService:disconnectedWithError:)])
        dispatch_on_main(^{ [self.delegate deviceService:self disconnectedWithError:error]; });
}

// closeByResponse 추가: remoteCameraErrorDidOccur 참고함
- (void) closeByResponse:(NSError *)error
{
    if(_remoteCameraDelegate != nil && [_remoteCameraDelegate respondsToSelector:@selector(remoteCameraAccessDenied)]){
        [_remoteCameraDelegate remoteCameraAccessDenied];
    }
}

#pragma mark - Helper methods

- (NSArray *)permissions
{
    if (_permissions)
        return _permissions;

    NSMutableArray *defaultPermissions = [[NSMutableArray alloc] init];
    [defaultPermissions addObjectsFromArray:kWebOSTVServiceOpenPermissions];

    if ([DiscoveryManager sharedManager].pairingLevel == DeviceServicePairingLevelOn)
    {
        [defaultPermissions addObjectsFromArray:kWebOSTVServiceProtectedPermissions];
        [defaultPermissions addObjectsFromArray:kWebOSTVServicePersonalActivityPermissions];
    }

    return [NSArray arrayWithArray:defaultPermissions];
}

- (void)setPermissions:(NSArray *)permissions
{
    _permissions = permissions;

    if (self.webOSTVServiceConfig.clientKey)
    {
        self.webOSTVServiceConfig.clientKey = nil;

        if (self.connected)
        {
            NSError *error = [ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Permissions changed -- you will need to re-pair to the TV."];
            [self disconnectWithError:error];
        }
    }
}

+ (ChannelInfo *)channelInfoFromDictionary:(NSDictionary *)info
{
    ChannelInfo *channelInfo = [[ChannelInfo alloc] init];
    channelInfo.id = [info objectForKey:@"channelId"];
    channelInfo.name = [info objectForKey:@"channelName"];
    channelInfo.number = [info objectForKey:@"channelNumber"];
    channelInfo.majorNumber = [[info objectForKey:@"majorNumber"] intValue];
    channelInfo.minorNumber = [[info objectForKey:@"minorNumber"] intValue];
    channelInfo.rawData = [info copy];

    return channelInfo;
}

+ (AppInfo *)appInfoFromDictionary:(NSDictionary *)info
{
    AppInfo *appInfo = [[AppInfo alloc] init];
    appInfo.name = [info objectForKey:@"title"];
    appInfo.id = [info objectForKey:@"id"];
    appInfo.rawData = [info copy];

    return appInfo;
}

+ (ExternalInputInfo *)externalInputInfoFromDictionary:(NSDictionary *)info
{
    ExternalInputInfo *externalInputInfo = [[ExternalInputInfo alloc] init];
    externalInputInfo.name = [info objectForKey:@"label"];
    externalInputInfo.id = [info objectForKey:@"id"];
    externalInputInfo.connected = [[info objectForKey:@"connected"] boolValue];
    externalInputInfo.iconURL = [NSURL URLWithString:[info objectForKey:@"icon"]];
    externalInputInfo.rawData = [info copy];

    return externalInputInfo;
}

#pragma mark - Launcher

- (id <Launcher>)launcher
{
    return self;
}

- (CapabilityPriorityLevel) launcherPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)getAppListWithSuccess:(AppListSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://com.webos.applicationManager/listApps"];

    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *responseDic)
    {
        NSArray *foundApps = [responseDic objectForKey:@"apps"];
        NSMutableArray *appList = [[NSMutableArray alloc] init];

        [foundApps enumerateObjectsUsingBlock:^(NSDictionary *appInfo, NSUInteger idx, BOOL *stop)
        {
            [appList addObject:[WebOSTVService appInfoFromDictionary:appInfo]];
        }];

        if (success)
            success(appList);
    };
    command.callbackError = failure;
    [command send];
}

- (void)launchApp:(NSString *)appId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchApplication:appId withParams:nil success:success failure:failure];
}

- (void)launchApplication:(NSString *)appId withParams:(NSDictionary *)params success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://system.launcher/launch"];
    
    NSMutableDictionary *payload = [NSMutableDictionary new];

    [payload setValue:appId forKey:@"id"];

    if (params) {
        [payload setValue:params forKey:@"params"];

        NSString *contentId = [params objectForKey:@"contentId"];

        if (contentId)
            [payload setValue:contentId forKey:@"contentId"];
    }

    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:appId];
        launchSession.sessionId = [responseObject objectForKey:@"sessionId"];
        launchSession.sessionType = LaunchSessionTypeApp;
        launchSession.service = self;
        launchSession.rawData = [responseObject copy];

        if (success)
            success(launchSession);
    };
    command.callbackError = failure;
    [command send];
}

- (void)launchAppWithInfo:(AppInfo *)appInfo success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchApp:appInfo.id success:success failure:failure];
}

- (void)launchAppWithInfo:(AppInfo *)appInfo params:(NSDictionary *)params success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchApplication:appInfo.id withParams:params success:success failure:failure];
}

- (void) launchAppStore:(NSString *)appId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    AppInfo *appInfo = [AppInfo appInfoForId:@"com.webos.app.discovery"];
    appInfo.name = @"LG Store";

    NSDictionary *params;

    if (appId && appId.length > 0)
    {
        NSString *query = [NSString stringWithFormat:@"category/GAME_APPS/%@", appId];
        params = @{ @"query" : query };
    }

    [self launchAppWithInfo:appInfo params:params success:success failure:failure];
}

- (void)launchBrowser:(NSURL *)target success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://system.launcher/open"];
    NSDictionary *params = @{ @"target" : target.absoluteString };

    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.socket target:URL payload:params];
    command.callbackComplete = ^(NSDictionary * responseObject)
    {
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:[responseObject objectForKey:@"id"]];
        launchSession.sessionId = [responseObject objectForKey:@"sessionId"];
        launchSession.sessionType = LaunchSessionTypeApp;
        launchSession.service = self;
        launchSession.rawData = [responseObject copy];

        if (success)
            success(launchSession);
    };
    command.callbackError = failure;
    [command send];
}

- (void)launchHulu:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    NSDictionary *params = @{ @"hulu" : contentId };
    
    [self launchApplication:@"hulu" withParams:params success:success failure:failure];
}

- (void)launchNetflix:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    NSString *netflixContentId = [NSString stringWithFormat:@"m=http%%3A%%2F%%2Fapi.netflix.com%%2Fcatalog%%2Ftitles%%2Fmovies%%2F%@&source_type=4", contentId];

    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    [params setValue:netflixContentId forKey:@"contentId"];

    [self launchApplication:@"netflix" withParams:params success:success failure:failure];
}

- (void)launchYouTube:(NSString *)contentId success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self.launcher launchYouTube:contentId startTime:0.0 success:success failure:failure];
}

- (void) launchYouTube:(NSString *)contentId startTime:(float)startTime success:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    NSDictionary *params;

    if (contentId && contentId.length > 0)
    {
        if (startTime < 0.0)
        {
            if (failure)
                failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"Start time may not be negative"]);

            return;
        }

        params = @{
            @"contentId" : [NSString stringWithFormat:@"%@&pairingCode=%@&t=%.1f", contentId, [[CTGuid randomGuid] stringValue], startTime]
        };
    }

    [self launchApplication:@"youtube.leanback.v4" withParams:params success:success failure:failure];
}

- (void) connectToApp:(NSString *)appId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    LaunchSession *launchSession = [LaunchSession launchSessionForAppId:appId];
    launchSession.service = self;
    launchSession.sessionType = LaunchSessionTypeApp;

    WebOSWebAppSession *webAppSession = [self webAppSessionForLaunchSession:launchSession];

    [self connectToApp:webAppSession joinOnly:NO success:^(id responseObject)
    {
        if (success)
            success(webAppSession);
    } failure:failure];
}

- (void) joinApp:(NSString *)appId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    LaunchSession *launchSession = [LaunchSession launchSessionForAppId:appId];
    launchSession.service = self;
    launchSession.sessionType = LaunchSessionTypeApp;

    WebOSWebAppSession *webAppSession = [self webAppSessionForLaunchSession:launchSession];

    [self connectToApp:webAppSession joinOnly:YES success:^(id responseObject)
    {
        if (success)
            success(webAppSession);
    } failure:failure];
}

- (void) connectToApp:(WebOSWebAppSession *)webAppSession joinOnly:(BOOL)joinOnly success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self connectToWebApp:webAppSession joinOnly:joinOnly success:success failure:failure];
}

- (ServiceSubscription *)subscribeRunningAppWithSuccess:(AppInfoSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://com.webos.applicationManager/getForegroundAppInfo"];

    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:nil success:^(NSDictionary *responseObject)
    {
        AppInfo *appInfo = [[AppInfo alloc] init];
        appInfo.id = [responseObject objectForKey:@"appId"];
        appInfo.rawData = [responseObject copy];

        if (success)
            success(appInfo);
    } failure:failure];

    return subscription;
}

- (void)getRunningAppWithSuccess:(AppInfoSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://com.webos.applicationManager/getForegroundAppInfo"];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        AppInfo *appInfo = [[AppInfo alloc] init];
        appInfo.id = [responseObject objectForKey:@"appId"];
        appInfo.name = [responseObject objectForKey:@"appName"];
        appInfo.rawData = [responseObject copy];

        if (success)
            success(appInfo);
    };
    command.callbackError = failure;
    [command send];
}

- (void)getAppState:(LaunchSession *)launchSession success:(AppStateSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://system.launcher/getAppState"];

    NSMutableDictionary *params = [NSMutableDictionary new];
    if (launchSession && launchSession.appId) [params setValue:launchSession.appId forKey:@"appId"];
    if (launchSession && launchSession.sessionId) [params setValue:launchSession.sessionId forKey:@"sessionId"];

    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.socket target:URL payload:params];
    command.callbackComplete = ^(NSDictionary * responseObject)
    {
        BOOL running = [[responseObject objectForKey:@"running"] boolValue];
        BOOL visible = [[responseObject objectForKey:@"visible"] boolValue];

        if (success)
            success(running, visible);
    };
    command.callbackError = failure;
    [command send];
}

- (ServiceSubscription *)subscribeAppState:(LaunchSession *)launchSession success:(AppStateSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://system.launcher/getAppState"];

    NSMutableDictionary *params = [NSMutableDictionary new];
    if (launchSession && launchSession.appId) [params setValue:launchSession.appId forKey:@"appId"];
    if (launchSession && launchSession.sessionId) [params setValue:launchSession.sessionId forKey:@"sessionId"];

    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:params success:^(NSDictionary *responseObject)
    {
        BOOL running = [[responseObject objectForKey:@"running"] boolValue];
        BOOL visible = [[responseObject objectForKey:@"visible"] boolValue];

        if (success)
            success(running, visible);
    } failure:failure];

    return subscription;
}

- (void)closeApp:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://system.launcher/close"];

    NSMutableDictionary *payload = [NSMutableDictionary new];
    if (launchSession.appId) [payload setValue:launchSession.appId forKey:@"id"]; // yes, this is id not appId (groan)
    if (launchSession.sessionId) [payload setValue:launchSession.sessionId forKey:@"sessionId"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

#pragma mark - External Input Control

- (id<ExternalInputControl>)externalInputControl
{
    return self;
}

- (CapabilityPriorityLevel)externalInputControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)launchInputPickerWithSuccess:(AppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self launchApp:@"com.webos.app.inputpicker" success:success failure:^(NSError *error) {
        [self launchApp:@"com.webos.app.inputmgr" success:success failure:failure];
    }];
}

- (void)closeInputPicker:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self.launcher closeApp:launchSession success:success failure:failure];
}

- (void)getExternalInputListWithSuccess:(ExternalInputListSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/getExternalInputList"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        NSArray *externalInputsData = [responseObject objectForKey:@"devices"];
        NSMutableArray *externalInputs = [[NSMutableArray alloc] init];

        [externalInputsData enumerateObjectsUsingBlock:^(NSDictionary *externalInputData, NSUInteger idx, BOOL *stop)
        {
            [externalInputs addObject:[WebOSTVService externalInputInfoFromDictionary:externalInputData]];
        }];

        if (success)
            success(externalInputs);
    };
    command.callbackError = failure;
    [command send];
}

- (void)setExternalInput:(ExternalInputInfo *)externalInputInfo success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/switchInput"];

    NSMutableDictionary *payload = [NSMutableDictionary new];
    if (externalInputInfo && externalInputInfo.id) [payload setValue:externalInputInfo.id forKey:@"inputId"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

#pragma mark - Media Player

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

- (void) displayImageWithMediaInfo:(MediaInfo *)mediaInfo success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    if (self.dlnaService)
    {
        id<MediaPlayer> mediaPlayer;

        if ([self.dlnaService respondsToSelector:@selector(mediaPlayer)])
            mediaPlayer = [self.dlnaService performSelector:@selector(mediaPlayer)];

        if (mediaPlayer && [mediaPlayer respondsToSelector:@selector(displayImageWithMediaInfo:success:failure:)])
        {
            [mediaPlayer displayImageWithMediaInfo:mediaInfo success:success failure:failure];
            return;
        }
    }

    [self launchNativeMediaPlayerWithMediaInfo:mediaInfo mediaType:@"PHOTO" success:success failure:failure];
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
    // Prefer DLNA (UPnP AVTransport): gives position/duration/seek tracking
    // and opens the TV's native media player. Fall back to SSAP native app
    // launch if DLNA service is unavailable.
    if (self.dlnaService)
    {
        id<MediaPlayer> mediaPlayer;

        if ([self.dlnaService respondsToSelector:@selector(mediaPlayer)])
            mediaPlayer = [self.dlnaService performSelector:@selector(mediaPlayer)];

        if (mediaPlayer && [mediaPlayer respondsToSelector:@selector(playMediaWithMediaInfo:shouldLoop:success:failure:)])
        {
            [mediaPlayer playMediaWithMediaInfo:mediaInfo shouldLoop:shouldLoop success:success failure:failure];
            return;
        }
    }

    // Fallback: launch native media player app via SSAP
    NSString *mediaType = @"VIDEO";
    if (mediaInfo.mimeType) {
        if ([mediaInfo.mimeType hasPrefix:@"audio"]) mediaType = @"MUSIC";
    }

    [self launchNativeMediaPlayerWithMediaInfo:mediaInfo mediaType:mediaType success:success failure:failure];
}

- (void)displayMediaWithParams:(NSDictionary *)params success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://media.viewer/open"];

    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.serviceCommandDelegate target:URL payload:params];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:[responseObject objectForKey:@"id"]];
        launchSession.sessionId = [responseObject objectForKey:@"sessionId"];
        launchSession.sessionType = LaunchSessionTypeMedia;
        launchSession.service = self;
        launchSession.rawData = [responseObject copy];

        MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:launchSession andMediaControl:self.mediaControl];
        if(success){
            success(launchObject);
        }
    };
    command.callbackError = failure;
    [command send];
}

- (void)launchNativeMediaPlayerWithMediaInfo:(MediaInfo *)mediaInfo mediaType:(NSString *)mediaType success:(MediaPlayerSuccessBlock)success failure:(FailureBlock)failure
{
    // Launch the native media player app via ssap://system.launcher/launch.
    // This works on all webOS versions (3.x–7.x+). The app ID varies by version:
    //   webOS 3-5: com.webos.app.photovideo
    //   webOS 6+:  com.webos.app.mediadiscovery
    // We try mediadiscovery first; if it fails, fall back to photovideo.

    NSString *fileName = mediaInfo.title ?: @"Media";

    // Build the DLNA-style protocolInfo based on MIME type
    NSString *mimeType = mediaInfo.mimeType ?: @"video/mp4";
    NSString *protocolInfo = [NSString stringWithFormat:@"http-get:*:%@:DLNA.ORG_OP=01", mimeType];

    NSDictionary *mediaItem = @{
        @"fullPath"  : ensureString(mediaInfo.url.absoluteString),
        @"fileName"  : fileName,
        @"mediaType" : mediaType,
        @"deviceType": @"DMR",
        @"dlnaInfo"  : @{
            @"flagVal"     : @4096,
            @"opVal"       : @1,
            @"protocolInfo": protocolInfo
        }
    };

    NSString *primaryAppId = @"com.webos.app.mediadiscovery";
    NSString *fallbackAppId = @"com.webos.app.photovideo";

    NSDictionary *payload = @{
        @"id"     : primaryAppId,
        @"params" : @{ @"payload" : @[ mediaItem ] }
    };

    NSURL *URL = [NSURL URLWithString:@"ssap://system.launcher/launch"];

    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.serviceCommandDelegate target:URL payload:payload];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        // Track playback start time for position estimation
        self->_playbackStartTime = [NSDate date];
        self->_playbackPausedPosition = 0;
        self->_playbackPaused = NO;
        NSLog(@"[WebOS_AVT] Media launched, tracking playback start time");

        LaunchSession *launchSession = [LaunchSession launchSessionForAppId:[responseObject objectForKey:@"id"]];
        launchSession.sessionId = [responseObject objectForKey:@"sessionId"];
        launchSession.sessionType = LaunchSessionTypeMedia;
        launchSession.service = self;
        launchSession.rawData = [responseObject copy];

        MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:launchSession andMediaControl:self.mediaControl];
        if (success) {
            success(launchObject);
        }
    };
    command.callbackError = ^(NSError *error)
    {
        // Primary app not found — try fallback app ID (older webOS)
        NSDictionary *fallbackPayload = @{
            @"id"     : fallbackAppId,
            @"params" : @{ @"payload" : @[ mediaItem ] }
        };

        ServiceCommand *fallbackCommand = [[ServiceCommand alloc] initWithDelegate:self.serviceCommandDelegate target:URL payload:fallbackPayload];
        fallbackCommand.callbackComplete = ^(NSDictionary *responseObject)
        {
            // Track playback start time for position estimation
            self->_playbackStartTime = [NSDate date];
            self->_playbackPausedPosition = 0;
            self->_playbackPaused = NO;
            NSLog(@"[WebOS_AVT] Media launched (fallback), tracking playback start time");

            LaunchSession *launchSession = [LaunchSession launchSessionForAppId:[responseObject objectForKey:@"id"]];
            launchSession.sessionId = [responseObject objectForKey:@"sessionId"];
            launchSession.sessionType = LaunchSessionTypeMedia;
            launchSession.service = self;
            launchSession.rawData = [responseObject copy];

            MediaLaunchObject *launchObject = [[MediaLaunchObject alloc] initWithLaunchSession:launchSession andMediaControl:self.mediaControl];
            if (success) {
                success(launchObject);
            }
        };
        fallbackCommand.callbackError = failure;
        [fallbackCommand send];
    };
    [command send];
}

- (void)closeMedia:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self closeApp:launchSession success:success failure:failure];
}

#pragma mark - Media Control

- (id <MediaControl>)mediaControl
{
    return self;
}

- (CapabilityPriorityLevel)mediaControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)playWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://media.controls/play"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(id response) {
        // Resume from paused position
        if (self->_playbackPaused && self->_playbackPausedPosition > 0) {
            self->_playbackStartTime = [NSDate dateWithTimeIntervalSinceNow:-self->_playbackPausedPosition];
            self->_playbackPaused = NO;
        }
        if (success) success(response);
    };
    command.callbackError = failure;
    [command send];
}

- (void)pauseWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://media.controls/pause"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(id response) {
        // Save current position estimate
        if (self->_playbackStartTime && !self->_playbackPaused) {
            self->_playbackPausedPosition = -[self->_playbackStartTime timeIntervalSinceNow];
            self->_playbackPaused = YES;
        }
        if (success) success(response);
    };
    command.callbackError = failure;
    [command send];
}

- (void)stopWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://media.controls/stop"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(id response) {
        self->_playbackStartTime = nil;
        self->_playbackPaused = NO;
        if (success) success(response);
    };
    command.callbackError = failure;
    [command send];
}

- (void)rewindWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://media.controls/rewind"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)fastForwardWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://media.controls/fastForward"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)seek:(NSTimeInterval)position success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (_avTransportControlURL) {
        NSString *timeStr = [self avtStringFromTimeInterval:position];
        NSString *extraXML = [NSString stringWithFormat:@"<Unit>REL_TIME</Unit><Target>%@</Target>", timeStr];
        [self sendAVTransportSOAP:@"Seek"
                       soapAction:@"\"urn:schemas-upnp-org:service:AVTransport:1#Seek\""
                         extraXML:extraXML
                          success:^(NSString *xml) { if (success) success(nil); }
                          failure:failure];
        return;
    }

    // Update position tracker for the seek
    if (_playbackPaused) {
        _playbackPausedPosition = position;
    } else {
        _playbackStartTime = [NSDate dateWithTimeIntervalSinceNow:-position];
    }

    DeviceService *dlna = self.dlnaService;
    if (dlna && [dlna conformsToProtocol:@protocol(MediaControl)]) {
        [(id<MediaControl>)dlna seek:position success:success failure:failure];
    } else {
        // No seek capability via SSAP — but we've updated the position tracker
        if (success) success(nil);
    }
}

- (void)getPlayStateWithSuccess:(MediaPlayStateSuccessBlock)success failure:(FailureBlock)failure
{
    if (_avTransportControlURL) {
        [self sendAVTransportSOAP:@"GetTransportInfo"
                       soapAction:@"\"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo\""
                         extraXML:nil
                          success:^(NSString *xml) {
            NSString *state = [self extractXMLValue:@"CurrentTransportState" fromXML:xml];
            MediaControlPlayState playState = MediaControlPlayStateUnknown;
            if ([state isEqualToString:@"PLAYING"])           playState = MediaControlPlayStatePlaying;
            else if ([state isEqualToString:@"PAUSED_PLAYBACK"]) playState = MediaControlPlayStatePaused;
            else if ([state isEqualToString:@"STOPPED"])         playState = MediaControlPlayStateFinished;
            else if ([state isEqualToString:@"TRANSITIONING"])   playState = MediaControlPlayStateIdle;
            else if ([state isEqualToString:@"NO_MEDIA_PRESENT"])playState = MediaControlPlayStateIdle;
            if (success) success(playState);
        } failure:failure];
        return;
    }

    // Use foreground app info + local pause tracking for play state
    // IMPORTANT: Must use ServiceCommand (not ServiceAsyncCommand) to wait for SSAP response
    NSURL *URL = [NSURL URLWithString:@"ssap://com.webos.applicationManager/getForegroundAppInfo"];
    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *response) {
        NSString *appId = response[@"appId"];
        BOOL isMediaApp = ([appId isEqualToString:@"com.webos.app.mediadiscovery"] ||
                           [appId isEqualToString:@"com.webos.app.photovideo"] ||
                           [appId isEqualToString:@"com.webos.app.mediaviewer"]);

        if (isMediaApp) {
            if (self->_playbackPaused) {
                if (success) success(MediaControlPlayStatePaused);
            } else {
                if (success) success(MediaControlPlayStatePlaying);
            }
        } else {
            // Media app not in foreground — playback finished or user exited
            self->_playbackStartTime = nil;
            if (success) success(MediaControlPlayStateFinished);
        }
    };
    command.callbackError = ^(NSError *error) {
        NSLog(@"[WebOS_AVT] getForegroundAppInfo error: %@", error);
        if (success) success(MediaControlPlayStateUnknown);
    };
    [command send];
}

- (void)getDurationWithSuccess:(MediaDurationSuccessBlock)success
                       failure:(FailureBlock)failure {
    if (_avTransportControlURL) {
        [self sendAVTransportSOAP:@"GetPositionInfo"
                       soapAction:@"\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\""
                         extraXML:nil
                          success:^(NSString *xml) {
            NSString *durationStr = [self extractXMLValue:@"TrackDuration" fromXML:xml];
            NSTimeInterval duration = [self avtTimeIntervalFromString:durationStr];
            if (success) success(duration);
        } failure:failure];
        return;
    }

    // Try SSAP mediacontroller for duration
    [self queryMediaControllerForValue:@"duration" success:^(NSTimeInterval value) {
        NSLog(@"[WebOS_AVT] Duration from mediacontroller: %.1f", value);
        if (success) success(value);
    } failure:^(NSError *error) {
        NSLog(@"[WebOS_AVT] Duration query failed: %@", error.localizedDescription);
        if (success) success(0);
    }];
}

- (void)getPositionWithSuccess:(MediaPositionSuccessBlock)success failure:(FailureBlock)failure
{
    if (_avTransportControlURL) {
        [self sendAVTransportSOAP:@"GetPositionInfo"
                       soapAction:@"\"urn:schemas-upnp-org:service:AVTransport:1#GetPositionInfo\""
                         extraXML:nil
                          success:^(NSString *xml) {
            NSString *relTime = [self extractXMLValue:@"RelTime" fromXML:xml];
            NSTimeInterval position = [self avtTimeIntervalFromString:relTime];
            if (success) success(position);
        } failure:failure];
        return;
    }

    // Try SSAP mediacontroller, then fall back to time-based estimation
    [self queryMediaControllerForValue:@"position" success:^(NSTimeInterval value) {
        if (value > 0) {
            if (success) success(value);
        } else {
            // Fallback: estimate from playback start time
            NSTimeInterval estimated = [self estimatedPlaybackPosition];
            NSLog(@"[WebOS_AVT] Position estimated from elapsed time: %.1f", estimated);
            if (success) success(estimated);
        }
    } failure:^(NSError *error) {
        // Fallback: estimate from playback start time
        NSTimeInterval estimated = [self estimatedPlaybackPosition];
        NSLog(@"[WebOS_AVT] Position estimated (after error): %.1f", estimated);
        if (success) success(estimated);
    }];
}

// Query com.webos.service.mediacontroller for position or duration
- (void)queryMediaControllerForValue:(NSString *)valueType
                             success:(void (^)(NSTimeInterval))success
                             failure:(FailureBlock)failure
{
    // Step 1: Get active media sessions (no params required)
    NSURL *sessionsURL = [NSURL URLWithString:@"ssap://com.webos.service.mediacontroller/getActiveMediaSessions"];
    ServiceCommand *sessionsCmd = [ServiceAsyncCommand commandWithDelegate:self.socket target:sessionsURL payload:nil];
    sessionsCmd.callbackComplete = ^(NSDictionary *response) {
        NSLog(@"[WebOS_AVT] getActiveMediaSessions: %@", response);

        NSArray *sessions = response[@"mediaSessionList"];
        if (!sessions) sessions = response[@"activeMediaSessions"];

        NSString *mediaId = sessions.firstObject;
        if (!mediaId) {
            NSLog(@"[WebOS_AVT] No active media sessions");
            if (success) success(0);
            return;
        }

        // Step 2: Query for the specific value using the mediaId
        if ([valueType isEqualToString:@"position"]) {
            // Try receiveMediaPlaybackInfo with subscribe for position
            NSURL *statusURL = [NSURL URLWithString:@"ssap://com.webos.service.mediacontroller/getMediaPlayStatus"];
            NSDictionary *payload = @{@"mediaId": mediaId};
            ServiceCommand *statusCmd = [ServiceAsyncCommand commandWithDelegate:self.socket target:statusURL payload:payload];
            statusCmd.callbackComplete = ^(NSDictionary *statusResponse) {
                NSLog(@"[WebOS_AVT] getMediaPlayStatus: %@", statusResponse);
                // Position might be in playPosition field
                NSTimeInterval pos = [statusResponse[@"playPosition"] doubleValue];
                if (pos <= 0) pos = [statusResponse[@"position"] doubleValue];
                if (pos <= 0) pos = [statusResponse[@"currentTime"] doubleValue];
                if (success) success(pos);
            };
            statusCmd.callbackError = ^(NSError *error) {
                NSLog(@"[WebOS_AVT] getMediaPlayStatus error: %@", error.localizedDescription);
                if (success) success(0);
            };
            [statusCmd send];
        } else {
            // Duration - try getMediaSessionInfo which includes metadata
            NSURL *infoURL = [NSURL URLWithString:@"ssap://com.webos.service.mediacontroller/getMediaSessionInfo"];
            NSDictionary *payload = @{@"mediaId": mediaId};
            ServiceCommand *infoCmd = [ServiceAsyncCommand commandWithDelegate:self.socket target:infoURL payload:payload];
            infoCmd.callbackComplete = ^(NSDictionary *infoResponse) {
                NSLog(@"[WebOS_AVT] getMediaSessionInfo: %@", infoResponse);
                NSTimeInterval dur = [infoResponse[@"duration"] doubleValue];
                if (dur <= 0) dur = [infoResponse[@"totalTime"] doubleValue];
                if (dur <= 0) {
                    // Try nested in metadata
                    NSDictionary *meta = infoResponse[@"metaData"];
                    dur = [meta[@"duration"] doubleValue];
                }
                if (success) success(dur);
            };
            infoCmd.callbackError = ^(NSError *error) {
                NSLog(@"[WebOS_AVT] getMediaSessionInfo error: %@", error.localizedDescription);
                if (success) success(0);
            };
            [infoCmd send];
        }
    };
    sessionsCmd.callbackError = ^(NSError *error) {
        NSLog(@"[WebOS_AVT] getActiveMediaSessions error: %@", error.localizedDescription);
        if (success) success(0);
    };
    [sessionsCmd send];
}

- (ServiceSubscription *)subscribePlayStateWithSuccess:(MediaPlayStateSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)getMediaMetaDataWithSuccess:(SuccessBlock)success
                            failure:(FailureBlock)failure {
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeMediaInfoWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

#pragma mark - Playlist Control

- (id <PlayListControl>)playListControl
{
    return self;
}

- (CapabilityPriorityLevel) playListControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)playNextWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure{
    [self sendNotSupportedFailure:failure];
}

- (void)playPreviousWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure{
    [self sendNotSupportedFailure:failure];
}

- (void)jumpToTrackWithIndex:(NSInteger)index success:(SuccessBlock)success failure:(FailureBlock)failure{
    [self sendNotSupportedFailure:failure];
}

#pragma mark - Volume

- (id <VolumeControl>)volumeControl
{
    return self;
}

- (CapabilityPriorityLevel)volumeControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)getMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/getMute"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];

    command.callbackComplete = ^(NSDictionary *responseDic)
    {
        BOOL mute = [[responseDic objectForKey:@"mute"] boolValue];

        if (success)
            success(mute);
    };

    command.callbackError = failure;
    [command send];
}

- (void)setMute:(BOOL)mute success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/setMute"];
    NSDictionary *payload = @{ @"mute" : @(mute) };

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];

    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)getVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/getVolume"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];

    command.callbackComplete = (^(NSDictionary *responseDic)
    {
        int fromString = 0;
        if ([responseDic objectForKey:@"volume"])
        {
            fromString = [[responseDic objectForKey:@"volume"] intValue];
        }
        else
        {
            fromString = [[[responseDic objectForKey:@"volumeStatus"] objectForKey:@"volume"] intValue];
        }
        float volVal = fromString / 100.0;

        if (success)
            success(volVal);
    });

    command.callbackError = failure;
    [command send];
}

- (void)setVolume:(float)volume success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/setVolume"];
    NSDictionary *payload = @{ @"volume" : @(roundf(volume * 100.0f)) };

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];

    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)volumeUpWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/volumeUp"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)volumeDownWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/volumeDown"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (ServiceSubscription *)subscribeMuteWithSuccess:(MuteSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/getMute"];

    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:nil success:^(NSDictionary *responseObject)
    {
        BOOL muteValue = [[responseObject valueForKey:@"mute"] boolValue];

        if (success)
            success(muteValue);
    } failure:failure];

    return subscription;
}

- (ServiceSubscription *)subscribeVolumeWithSuccess:(VolumeSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://audio/getVolume"];

    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:nil success:^(NSDictionary *responseObject)
    {
        float volumeValue = 0;
        if ([responseObject valueForKey:@"volume"])
        {
            volumeValue = [[responseObject valueForKey:@"volume"] floatValue] / 100.0;
        }
        else
        {
            volumeValue = [[[responseObject valueForKey:@"volumeStatus"] valueForKey:@"volume"] floatValue] / 100.0;
        }

        if (success)
            success(volumeValue);
    } failure:failure];

    return subscription;
}

#pragma mark - TV

- (id <TVControl>)tvControl
{
    return self;
}

- (CapabilityPriorityLevel)tvControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)getCurrentChannelWithSuccess:(CurrentChannelSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/getCurrentChannel"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *responseDic)
    {
        if (success)
            success([WebOSTVService channelInfoFromDictionary:responseDic]);
    };
    command.callbackError = failure;
    [command send];
}

- (void)getChannelListWithSuccess:(ChannelListSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/getChannelList"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];

    command.callbackComplete = (^(NSDictionary *responseDic)
    {
        NSArray *channels = [responseDic objectForKey:@"channelList"];
        NSMutableArray *channelList = [[NSMutableArray alloc] init];

        [channels enumerateObjectsUsingBlock:^(NSDictionary *channelInfo, NSUInteger idx, BOOL *stop)
        {
            [channelList addObject:[WebOSTVService channelInfoFromDictionary:channelInfo]];
        }];

        if (success)
            success([NSArray arrayWithArray:channelList]);
    });

    command.callbackError = failure;
    [command send];
}

- (ServiceSubscription *)subscribeCurrentChannelWithSuccess:(CurrentChannelSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/getCurrentChannel"];

    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:nil success:^(NSDictionary *responseObject)
    {
        ChannelInfo *channelInfo = [WebOSTVService channelInfoFromDictionary:responseObject];

        if (success)
            success(channelInfo);
    } failure:failure];

    return subscription;
}

- (void)channelUpWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/channelUp"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)channelDownWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/channelDown"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)setChannel:(ChannelInfo *)channelInfo success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!channelInfo)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"channelInfo cannot be empty"]);
        return;
    }
    NSURL *URL = [NSURL URLWithString:@"ssap://tv/openChannel"];

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    if(channelInfo.id){
        [payload setNullableObject:channelInfo.id forKey:@"channelId"];
    }
    
    if(channelInfo.number){
        [payload setNullableObject:channelInfo.number forKey:@"channelNumber"];
    }
    
    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)getProgramInfoWithSuccess:(ProgramInfoSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeProgramInfoWithSuccess:(ProgramInfoSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)getProgramListWithSuccess:(ProgramListSuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

- (ServiceSubscription *)subscribeProgramListWithSuccess:(ProgramListSuccessBlock)success failure:(FailureBlock)failure
{
    return [self sendNotSupportedFailure:failure];
}

- (void)get3DEnabledWithSuccess:(TV3DEnabledSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://com.webos.service.tv.display/get3DStatus"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        NSDictionary *status3D = [responseObject objectForKey:@"status3D"];
        BOOL status = [[status3D objectForKey:@"status"] boolValue];

        if (success)
            success(status);
    };
    command.callbackError = failure;
    [command send];
}

- (void)set3DEnabled:(BOOL)enabled success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL;

    if (enabled)
        URL = [NSURL URLWithString:@"ssap://com.webos.service.tv.display/set3DOn"];
    else
        URL = [NSURL URLWithString:@"ssap://com.webos.service.tv.display/set3DOff"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (ServiceSubscription *)subscribe3DEnabledWithSuccess:(TV3DEnabledSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://com.webos.service.tv.display/get3DStatus"];

    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:nil success:^(NSDictionary *responseObject)
    {
        NSDictionary *status3D = [responseObject objectForKey:@"status3D"];
        BOOL status = [[status3D objectForKey:@"status"] boolValue];

        if (success)
            success(status);
    } failure:failure];

    return subscription;
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

- (void) sendMouseButton:(WebOSTVMouseButton)button success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (self.mouseSocket)
    {
        [self.mouseSocket button:button];

        if (success)
            success(nil);
    } else
    {
        [self.mouseControl connectMouseWithSuccess:^(id responseObject)
        {
            [self.mouseSocket button:button];

            if (success)
                success(nil);
        } failure:failure];
    }
}

- (void)upWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendMouseButton:WebOSTVMouseButtonUp success:success failure:failure];
}

- (void)downWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendMouseButton:WebOSTVMouseButtonDown success:success failure:failure];
}

- (void)leftWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendMouseButton:WebOSTVMouseButtonLeft success:success failure:failure];
}

- (void)rightWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendMouseButton:WebOSTVMouseButtonRight success:success failure:failure];
}

- (void)okWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (self.mouseSocket)
    {
        [self.mouseSocket click];

        if (success)
            success(nil);
    } else
    {
        [self.mouseControl connectMouseWithSuccess:^(id responseObject)
        {
            [self.mouseSocket click];

            if (success)
                success(nil);
        } failure:failure];
    }
}

- (void)backWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendMouseButton:WebOSTVMouseButtonBack success:success failure:failure];
}

- (void)homeWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendMouseButton:WebOSTVMouseButtonHome success:success failure:failure];
}

- (void)sendKeyCode:(NSUInteger)keyCode success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

#pragma mark - Mouse

- (id<MouseControl>)mouseControl
{
    return self;
}

- (CapabilityPriorityLevel)mouseControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)connectMouseWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (_mouseSocket || _mouseInit)
        return;

    _mouseInit = YES;

    NSURL *commandURL = [NSURL URLWithString:@"ssap://com.webos.service.networkinput/getPointerInputSocket"];
    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.socket target:commandURL payload:nil];

    command.callbackComplete = (^(NSDictionary *responseDic)
    {
        NSString *socket = [responseDic objectForKey:@"socketPath"];
        _mouseSocket = [[WebOSTVServiceMouse alloc] initWithSocket:socket success:success failure:failure];
    });
    command.callbackError = ^(NSError *error)
    {
        _mouseInit = NO;
        _mouseSocket = nil;

        if (failure)
            failure(error);
    };
    [command send];
}

- (void)disconnectMouse
{
    [_mouseSocket disconnect];
    _mouseSocket = nil;

    _mouseInit = NO;
}

- (void) move:(CGVector)distance success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (self.mouseSocket)
    {
        [self.mouseSocket move:distance];

        if (success)
            success(nil);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"MouseControl socket is not yet initialized."]);
    }
}

- (void) scroll:(CGVector)distance success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (self.mouseSocket)
    {
        [self.mouseSocket scroll:distance];

        if (success)
            success(nil);
    } else
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"MouseControl socket is not yet initialized."]);
    }
}

- (void)clickWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self okWithSuccess:success failure:failure];
}

#pragma mark - Power

- (id<PowerControl>)powerControl
{
    return self;
}

- (CapabilityPriorityLevel)powerControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)powerOffWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://system/turnOff"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:nil];

    command.callbackComplete = (^(NSDictionary *responseDic)
    {
        BOOL didTurnOff = [[responseDic objectForKey:@"returnValue"] boolValue];

        if (didTurnOff && success)
            success(nil);
        else if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeTvError andDetails:nil]);
    });

    command.callbackError = failure;
    [command send];
}

- (void) powerOnWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [self sendNotSupportedFailure:failure];
}

#pragma mark - Web App Launcher

- (id <WebAppLauncher>)webAppLauncher
{
    return self;
}

- (CapabilityPriorityLevel)webAppLauncherPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)launchWebApp:(NSString *)webAppId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self.webAppLauncher launchWebApp:webAppId params:nil relaunchIfRunning:YES success:success failure:failure];
}

- (void)launchWebApp:(NSString *)webAppId relaunchIfRunning:(BOOL)relaunchIfRunning success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    [self.webAppLauncher launchWebApp:webAppId params:nil relaunchIfRunning:relaunchIfRunning success:success failure:failure];
}

- (void)launchWebApp:(NSString *)webAppId params:(NSDictionary *)params success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (!webAppId || webAppId.length == 0)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid web app id"]);

        return;
    }

    __block WebOSWebAppSession *webAppSession = _webAppSessions[webAppId];

    NSURL *URL = [NSURL URLWithString:@"ssap://webapp/launchWebApp"];

    NSMutableDictionary *payload = [NSMutableDictionary new];
    if (webAppId) [payload setObject:webAppId forKey:@"webAppId"];
    if (params) [payload setObject:params forKey:@"urlParams"];

    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        LaunchSession *launchSession;

        if (webAppSession)
            launchSession = webAppSession.launchSession;
        else
        {
            launchSession = [LaunchSession launchSessionForAppId:webAppId];
            webAppSession = [[WebOSWebAppSession alloc] initWithLaunchSession:launchSession service:self];
            _webAppSessions[webAppId] = webAppSession;
        }

        launchSession.sessionType = LaunchSessionTypeWebApp;
        launchSession.service = self;
        launchSession.sessionId = [responseObject objectForKey:@"sessionId"];
        launchSession.rawData = [responseObject copy];

        if (success)
            success(webAppSession);
    };
    command.callbackError = failure;
    [command send];
}

- (void)launchWebApp:(NSString *)webAppId params:(NSDictionary *)params relaunchIfRunning:(BOOL)relaunchIfRunning success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    if (!webAppId || webAppId.length == 0)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You need to provide a valid webAppId."]);

        return;
    }

    if (relaunchIfRunning)
        [self.webAppLauncher launchWebApp:webAppId params:params success:success failure:failure];
    else
    {
        [self.launcher getRunningAppWithSuccess:^(AppInfo *appInfo)
        {
            // TODO: this will only work on native apps, currently
            if ([appInfo.id hasSuffix:webAppId])
            {
                LaunchSession *launchSession = [LaunchSession launchSessionForAppId:webAppId];
                launchSession.sessionType = LaunchSessionTypeWebApp;
                launchSession.service = self;
                launchSession.rawData = appInfo.rawData;

                WebOSWebAppSession *webAppSession = [self webAppSessionForLaunchSession:launchSession];

                if (success)
                    success(webAppSession);
            } else
            {
                [self.webAppLauncher launchWebApp:webAppId params:params success:success failure:failure];
            }
        } failure:failure];
    }
}

- (void)closeWebApp:(LaunchSession *)launchSession success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!launchSession || !launchSession.appId || launchSession.appId.length == 0)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"Must provide a valid launch session object"]);

        return;
    }

    WebOSWebAppSession *webAppSession = _webAppSessions[launchSession.appId];

    if (webAppSession){
        [webAppSession disconnectFromWebApp];
    }
    
    NSURL *URL = [NSURL URLWithString:@"ssap://webapp/closeWebApp"];
    
    NSMutableDictionary *payload = [NSMutableDictionary new];
    if (launchSession.appId) [payload setValue:launchSession.appId forKey:@"webAppId"];
    if (launchSession.sessionId) [payload setValue:launchSession.sessionId forKey:@"sessionId"];
    
    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

- (void)joinWebApp:(LaunchSession *)webAppLaunchSession success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    WebOSWebAppSession *webAppSession = [self webAppSessionForLaunchSession:webAppLaunchSession];

    [webAppSession joinWithSuccess:^(id responseObject)
    {
        if (success)
            success(webAppSession);
    } failure:failure];
}

- (void)joinWebAppWithId:(NSString *)webAppId success:(WebAppLaunchSuccessBlock)success failure:(FailureBlock)failure
{
    LaunchSession *launchSession = [LaunchSession launchSessionForAppId:webAppId];
    launchSession.sessionType = LaunchSessionTypeWebApp;
    launchSession.service = self;

    [self joinWebApp:launchSession success:success failure:failure];
}

- (void) connectToWebApp:(WebOSWebAppSession *)webAppSession joinOnly:(BOOL)joinOnly success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!_webAppSessions)
        _webAppSessions = [NSMutableDictionary new];

    if (!_appToAppIdMappings)
        _appToAppIdMappings = [NSMutableDictionary new];

    if (!webAppSession || !webAppSession.launchSession)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid LaunchSession object."]);
        return;
    }

    NSString *appId = webAppSession.launchSession.appId;
    NSString *idKey;

    if (webAppSession.launchSession.sessionType == LaunchSessionTypeWebApp)
        idKey = @"webAppId";
    else
        idKey = @"appId";

    if (!appId || appId.length == 0)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid web app session"]);

        return;
    }

    NSURL *URL = [NSURL URLWithString:@"ssap://webapp/connectToApp"];

    NSMutableDictionary *payload = [NSMutableDictionary new];
    [payload setValue:appId forKey:idKey];

    FailureBlock connectFailure = ^(NSError *error)
    {
        [webAppSession disconnectFromWebApp];

        BOOL appChannelDidClose = [error.localizedDescription rangeOfString:@"app channel closed"].location != NSNotFound;

        if (appChannelDidClose)
        {
            if (webAppSession && webAppSession.delegate && [webAppSession.delegate respondsToSelector:@selector(webAppSessionDidDisconnect:)])
                [webAppSession.delegate webAppSessionDidDisconnect:webAppSession];
        } else
        {
            if (failure)
                failure(error);
        }
    };

    SuccessBlock connectSuccess = ^(id responseObject) {
        NSString *state = [responseObject objectForKey:@"state"];

        if (![state isEqualToString:@"CONNECTED"])
        {
            if (joinOnly && [state isEqualToString:@"WAITING_FOR_APP"])
            {
                if (connectFailure)
                    connectFailure([ConnectError generateErrorWithCode:ConnectStatusCodeError andDetails:@"Web app is not currently running"]);
            }

            return;
        }

        NSString *fullAppId = responseObject[@"appId"];

        if (fullAppId)
        {
            if (webAppSession.launchSession.sessionType == LaunchSessionTypeWebApp)
                _appToAppIdMappings[fullAppId] = appId;

            webAppSession.fullAppId = fullAppId;
        }

        if (success)
            success(responseObject);
    };
    
    ServiceSubscription *appToAppSubscription = [ServiceSubscription subscriptionWithDelegate:webAppSession.socket target:URL payload:payload callId:-1];
    [appToAppSubscription addSuccess:connectSuccess];
    [appToAppSubscription addFailure:connectFailure];
    
    webAppSession.appToAppSubscription = appToAppSubscription;
    [appToAppSubscription subscribe];
}


- (void) pinWebApp:(NSString *)webAppId success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!webAppId || webAppId.length == 0)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid web app id"]);
        
        return;
    }
    
    NSURL *URL = [NSURL URLWithString:@"ssap://webapp/pinWebApp"];
    NSMutableDictionary *payload = [NSMutableDictionary new];
    [payload setObject:webAppId forKey:@"webAppId"];
     __weak typeof(self) weakSelf = self;
    __block ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:payload success:^(NSDictionary *responseDict)
                                         {
                                             if([responseDict valueForKey:@"pairingType"]){
                                                [weakSelf showAlertWithTitle:@"Pin Web App" andMessage:@"Please confirm on your device"];
                                                 
                                             }
                                             else
                                             {
                                                 [weakSelf dismissPinAlertView];
                                                 [subscription unsubscribe];
                                                 success(responseDict);
                                             }
                                             
                                         }failure:^(NSError *error){
                                             [weakSelf dismissPinAlertView];
                                             [subscription unsubscribe];
                                             failure(error);
                                         }];
}

- (void)unPinWebApp:(NSString *)webAppId success:(SuccessBlock)success failure:(FailureBlock)failure
{
    if (!webAppId || webAppId.length == 0)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid web app id"]);
        
        return;
    }
    
    NSURL *URL = [NSURL URLWithString:@"ssap://webapp/removePinnedWebApp"];
    NSMutableDictionary *payload = [NSMutableDictionary new];
    [payload setObject:webAppId forKey:@"webAppId"];
    
    __weak typeof(self) weakSelf = self;
    __block ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:payload success:^(NSDictionary *responseDict)
                                         {
                                             if([responseDict valueForKey:@"pairingType"]){
                                                [weakSelf showAlertWithTitle:@"Un Pin Web App" andMessage:@"Please confirm on your device"];
                                                
                                             }
                                             else
                                             {
                                                 [weakSelf dismissPinAlertView];
                                                 [subscription unsubscribe];
                                                  success(responseDict);
                                             }
                                             
                                             
                                         }failure:^(NSError *error){
                                             [weakSelf dismissPinAlertView];
                                             [subscription unsubscribe];
                                             failure(error);
                                         }];
}

- (void)isWebAppPinned:(NSString *)webAppId success:(WebAppPinStatusBlock)success failure:(FailureBlock)failure
{
    if (!webAppId || webAppId.length == 0)
    {
        if (failure)
            failure([ConnectError generateErrorWithCode:ConnectStatusCodeArgumentError andDetails:@"You must provide a valid web app id"]);
        
        return;
    }
    NSURL *URL = [NSURL URLWithString:@"ssap://webapp/isWebAppPinned"];
    NSMutableDictionary *payload = [NSMutableDictionary new];
    [payload setObject:webAppId forKey:@"webAppId"];
    
    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = (^(NSDictionary *responseDic)
                                {
                                    BOOL status = [[responseDic objectForKey:@"pinned"] boolValue];
                                    if(success){
                                        success(status);
                                    }
                                    
                                });
    command.callbackError = failure;
    [command send];
}

- (ServiceSubscription *)subscribeIsWebAppPinned:(NSString*)webAppId success:(WebAppPinStatusBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://webapp/isWebAppPinned"];
    NSMutableDictionary *payload = [NSMutableDictionary new];
    [payload setObject:webAppId forKey:@"webAppId"];
    
    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:payload success:^(NSDictionary *responseObject)
                                         {
                                             BOOL status = [[responseObject objectForKey:@"pinned"] boolValue];
                                             if (success){
                                                 success(status);
                                             }
                                             
                                         } failure:failure];    
    return subscription;
}

- (void)sendPairingKey:(NSString *)pairingKey success:(SuccessBlock)success failure:(FailureBlock)failure {
   
    NSURL *URL = [NSURL URLWithString:@"ssap://pairing/setPin"];
    NSMutableDictionary *payload = [NSMutableDictionary new];
    [payload setObject:pairingKey forKey:@"pin"];
    
    ServiceCommand *command = [ServiceAsyncCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = (^(NSDictionary *responseDic)
                                {
                                    if (success) {
                                        success(responseDic);
                                    }
                                    
                                });
    command.callbackError = ^(NSError *error){
                                if(failure){
                                    failure(error);
                                }
                            };
    [command send];
}

- (WebOSWebAppSession *) webAppSessionForLaunchSession:(LaunchSession *)launchSession
{
    if (!_webAppSessions)
        _webAppSessions = [NSMutableDictionary new];

    if (!launchSession.service)
        launchSession.service = self;

    WebOSWebAppSession *webAppSession = _webAppSessions[launchSession.appId];

    if (!webAppSession)
    {
        webAppSession = [self createWebAppSessionWithLaunchSession:launchSession
                                                        andService:self];
        _webAppSessions[launchSession.appId] = webAppSession;
    }

    return webAppSession;
}

- (NSDictionary *) appToAppIdMappings
{
    return [NSDictionary dictionaryWithDictionary:_appToAppIdMappings];
}

- (NSDictionary *) webAppSessions
{
    return [NSDictionary dictionaryWithDictionary:_webAppSessions];
}

#pragma mark - Text Input Control

- (id<TextInputControl>) textInputControl
{
    return self;
}

- (CapabilityPriorityLevel) textInputControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void) sendText:(NSString *)input success:(SuccessBlock)success failure:(FailureBlock)failure
{
    [_keyboardQueue addObject:input];

    if (!_keyboardQueueProcessing)
        [self sendKeys];
}

- (void)sendEnterWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [_keyboardQueue addObject:kKeyboardEnter];

    if (!_keyboardQueueProcessing)
        [self sendKeys];
}

- (void)sendDeleteWithSuccess:(SuccessBlock)success failure:(FailureBlock)failure
{
    [_keyboardQueue addObject:kKeyboardDelete];

    if (!_keyboardQueueProcessing)
        [self sendKeys];
}

- (void) sendKeys
{
    _keyboardQueueProcessing = YES;

    NSString *target;
    NSString *key = [_keyboardQueue firstObject];
    NSMutableDictionary *payload = [[NSMutableDictionary alloc] init];

    if ([key isEqualToString:kKeyboardEnter])
    {
        [_keyboardQueue removeObjectAtIndex:0];
        target = @"ssap://com.webos.service.ime/sendEnterKey";
    } else if ([key isEqualToString:kKeyboardDelete])
    {
        target = @"ssap://com.webos.service.ime/deleteCharacters";

        int count = 0;

        for (NSUInteger i = 0; i < _keyboardQueue.count; i++)
        {
            if ([[_keyboardQueue objectAtIndex:i] isEqualToString:kKeyboardDelete]) {
                count++;
            } else {
                break;
            }
        }

        NSRange deleteRange = NSMakeRange(0, count);
        [_keyboardQueue removeObjectsInRange:deleteRange];

        [payload setObject:@(count) forKey:@"count"];
    } else
    {
        target = @"ssap://com.webos.service.ime/insertText";
        NSMutableString *stringToSend = [[NSMutableString alloc] init];

        int count = 0;

        for (NSUInteger i = 0; i < _keyboardQueue.count; i++)
        {
            NSString *text = [_keyboardQueue objectAtIndex:i];

            if (![text isEqualToString:kKeyboardEnter] && ![text isEqualToString:kKeyboardDelete]) {
                [stringToSend appendString:text];
                count++;
            } else {
                break;
            }
        }

        NSRange textRange = NSMakeRange(0, count);
        [_keyboardQueue removeObjectsInRange:textRange];

        [payload setObject:stringToSend forKey:@"text"];
        [payload setObject:@(NO) forKey:@"replace"];
    }

    NSURL *URL = [NSURL URLWithString:target];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.socket target:URL payload:payload];
    command.callbackComplete = ^(id responseObject)
    {
        _keyboardQueueProcessing = NO;

        if (_keyboardQueue.count > 0)
            [self sendKeys];
    };
    command.callbackError = ^(NSError *error)
    {
        _keyboardQueueProcessing = NO;

        if (_keyboardQueue.count > 0)
            [self sendKeys];
    };
    [command send];
}

- (ServiceSubscription *) subscribeTextInputStatusWithSuccess:(TextInputStatusInfoSuccessBlock)success failure:(FailureBlock)failure
{
    _keyboardQueue = [[NSMutableArray alloc] init];
    _keyboardQueueProcessing = NO;

    NSURL *URL = [NSURL URLWithString:@"ssap://com.webos.service.ime/registerRemoteKeyboard"];

    ServiceSubscription *subscription = [self.socket addSubscribe:URL payload:nil success:^(NSDictionary *responseObject)
    {
        BOOL isVisible = [[[responseObject objectForKey:@"currentWidget"] objectForKey:@"focus"] boolValue];
        NSString *type = [[responseObject objectForKey:@"currentWidget"] objectForKey:@"contentType"];

        UIKeyboardType keyboardType = UIKeyboardTypeDefault;

        if ([type isEqualToString:@"url"])
            keyboardType = UIKeyboardTypeURL;
        else if ([type isEqualToString:@"number"])
            keyboardType = UIKeyboardTypeNumberPad;
        else if ([type isEqualToString:@"phonenumber"])
            keyboardType = UIKeyboardTypeNamePhonePad;
        else if ([type isEqualToString:@"email"])
            keyboardType = UIKeyboardTypeEmailAddress;

        TextInputStatusInfo *keyboardInfo = [[TextInputStatusInfo alloc] init];
        keyboardInfo.isVisible = isVisible;
        keyboardInfo.keyboardType = keyboardType;
        keyboardInfo.rawData = [responseObject copy];

        if (success)
            success(keyboardInfo);
    } failure:failure];

    return subscription;
}

#pragma mark - Toast Control

- (id<ToastControl>)toastControl
{
    return self;
}

- (CapabilityPriorityLevel)toastControlPriority
{
    return CapabilityPriorityLevelHigh;
}

- (void)showToast:(NSString *)message success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (message) [params setValue:message forKey:@"message"];

    [self showToastWithParams:params success:success failure:failure];
}

- (void)showToast:(NSString *)message iconData:(NSString *)iconData iconExtension:(NSString *)iconExtension success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (message) [params setValue:message forKey:@"message"];
    if (iconData) [params setValue:iconData forKey:@"iconData"];
    if (iconExtension) [params setValue:iconExtension forKey:@"iconExtension"];

    [self showToastWithParams:params success:success failure:failure];
}

- (void)showClickableToast:(NSString *)message appInfo:(AppInfo *)appInfo params:(NSDictionary *)launchParams success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (message) [params setValue:message forKey:@"message"];
    if (appInfo) [params setValue:appInfo.id forKey:@"target"];
    if (launchParams) [params setValue:launchParams forKey:@"params"];

    [self showToastWithParams:params success:success failure:failure];
}

- (void)showClickableToast:(NSString *)message appInfo:(AppInfo *)appInfo params:(NSDictionary *)launchParams iconData:(NSString *)iconData iconExtension:(NSString *)iconExtension success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (message) [params setValue:message forKey:@"message"];
    if (appInfo) [params setValue:appInfo.id forKey:@"target"];
    if (launchParams) [params setValue:launchParams forKey:@"params"];
    if (iconData) [params setValue:iconData forKey:@"iconData"];
    if (iconExtension) [params setValue:iconExtension forKey:@"iconExtension"];

    [self showToastWithParams:params success:success failure:failure];
}

- (void)showClickableToast:(NSString *)message URL:(NSURL *)URL success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (message) [params setValue:message forKey:@"message"];
    if (URL) [params setValue:URL.absoluteString forKey:@"target"];

    [self showToastWithParams:params success:success failure:failure];
}

- (void)showClickableToast:(NSString *)message URL:(NSURL *)URL iconData:(NSString *)iconData iconExtension:(NSString *)iconExtension success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (message) [params setValue:message forKey:@"message"];
    if (URL) [params setValue:URL.absoluteString forKey:@"target"];
    if (iconData) [params setValue:iconData forKey:@"iconData"];
    if (iconExtension) [params setValue:iconExtension forKey:@"iconExtension"];

    [self showToastWithParams:params success:success failure:failure];
}

- (void) showToastWithParams:(NSDictionary *)params success:(SuccessBlock)success failure:(FailureBlock)failure
{
    NSMutableDictionary *toastParams = [NSMutableDictionary dictionaryWithDictionary:params];

    if ([toastParams objectForKey:@"iconData"] == nil)
    {
        NSString *imageName = [[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIconFiles"] objectAtIndex:0];

        if (imageName == nil)
            imageName = [[[[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleIcons"] objectForKey:@"CFBundlePrimaryIcon"] objectForKey:@"CFBundleIconFiles"] firstObject];

        UIImage *appIcon = [UIImage imageNamed:imageName];
        NSString *dataString;

        if (appIcon)
            dataString = [UIImagePNGRepresentation(appIcon) base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];

        if (dataString)
        {
            [toastParams setObject:dataString forKey:@"iconData"];
            [toastParams setObject:@"png" forKey:@"iconExtension"];
        }
    }

    ServiceCommand *command = [[ServiceCommand alloc] initWithDelegate:self.socket target:[NSURL URLWithString:@"ssap://system.notifications/createToast"] payload:toastParams];
    command.callbackComplete = success;
    command.callbackError = failure;
    [command send];
}

#pragma mark - System info

- (void)getServiceListWithSuccess:(ServiceListSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://api/getServiceList"];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        NSArray *services = [responseObject objectForKey:@"services"];

        if (success)
            success(services);
    };
    command.callbackError = failure;
    [command send];
}

- (void)getSystemInfoWithSuccess:(SystemInfoSuccessBlock)success failure:(FailureBlock)failure
{
    NSURL *URL = [NSURL URLWithString:@"ssap://system/getSystemInfo"];

    ServiceCommand *command = [ServiceCommand commandWithDelegate:self.socket target:URL payload:nil];
    command.callbackComplete = ^(NSDictionary *responseObject)
    {
        NSArray *features = [responseObject objectForKey:@"features"];

        if (success)
            success(features);
    };
    command.callbackError = failure;
    [command send];
}

#pragma mark - Helpers

- (WebOSWebAppSession *)createWebAppSessionWithLaunchSession:(LaunchSession *)launchSession
                                                  andService:(WebOSTVService *)service {
    return [[WebOSWebAppSession alloc] initWithLaunchSession:launchSession service:service];
}

#pragma mark - ScreenMirroringControl

- (id<ScreenMirroringControl>)screenMirroringControl {
    [[ScreenMirroringService sharedInstance] setDelegate:self];
    return self;
}

- (CapabilityPriorityLevel)screenMirroringControlPriority {
    return CapabilityPriorityLevelHigh;
}

- (void)startScreenMirroringWithSettings:(nullable NSDictionary<NSString *, id> *)settings {
    NSDictionary *allDevices = [[DiscoveryManager sharedManager] allDevices];
    ConnectableDevice *device;

    if (allDevices && allDevices.count > 0)
        device = [allDevices objectForKey:self.serviceDescription.address];
    
    [[ScreenMirroringService sharedInstance] startMirroring:device settings:settings];
}

- (void)startScreenMirroring {
    [self startScreenMirroringWithSettings:nil];
}

- (void)pushSampleBuffer:(CMSampleBufferRef)sampleBuffer with:(RPSampleBufferType)sampleBufferType {
    [[ScreenMirroringService sharedInstance] pushSampleBuffer:sampleBuffer with:sampleBufferType];
}

- (void)stopScreenMirroring {
    [[ScreenMirroringService sharedInstance] stopMirroring];
}

- (void)setScreenMirroringDelegate:(__weak id<ScreenMirroringControlDelegate>)delegate {
    _screenMirroringDelegate = delegate;
}

#pragma mark - ScreenMirroringServiceDelegate
- (void)screenMirroringDidStart:(BOOL)result {
    if(_screenMirroringDelegate != nil && [_screenMirroringDelegate respondsToSelector:@selector(screenMirroringDidStart:)]){
        [_screenMirroringDelegate screenMirroringDidStart:result];
    }
}

- (void)screenMirroringDidStop:(BOOL)result {
    if(_screenMirroringDelegate != nil && [_screenMirroringDelegate respondsToSelector:@selector(screenMirroringDidStop:)]){
        [_screenMirroringDelegate screenMirroringDidStop:result];
    }
}

- (void)screenMirroringErrorDidOccur:(ScreenMirroringError)error {
    if(_screenMirroringDelegate != nil && [_screenMirroringDelegate respondsToSelector:@selector(screenMirroringErrorDidOccur:)]){
        [_screenMirroringDelegate screenMirroringErrorDidOccur:error];
    }
}

#pragma mark - RemoteCameraControl

- (id<RemoteCameraControl>)remoteCameraControl {
    [[RemoteCameraService sharedInstance] setDelegate:self];
    return self;
}

- (CapabilityPriorityLevel)remoteCameraControlPriority {
    return CapabilityPriorityLevelHigh;
}

- (UIView *)startRemoteCameraWithSettings:(nullable NSDictionary<NSString *, id> *)settings{
    NSDictionary *allDevices = [[DiscoveryManager sharedManager] allDevices];
    ConnectableDevice *device;

    if (allDevices && allDevices.count > 0)
        device = [allDevices objectForKey:self.serviceDescription.address];
    
    return [[RemoteCameraService sharedInstance] startRemoteCamera:device settings:settings];
}

- (UIView *)startRemoteCamera {
    return [self startRemoteCameraWithSettings:nil];
}

- (void)stopRemoteCamera {
    [[RemoteCameraService sharedInstance] stopRemoteCamera];
}

- (void)setLensFacing:(int)lensFacing {
    [[RemoteCameraService sharedInstance] setLensFacing:lensFacing];
    return;
}

- (void)setMicMute:(BOOL)micMute {
    [[RemoteCameraService sharedInstance] setMicMute:micMute];
    return;
}

- (void)setRemoteCameraDelegate:(__weak id<RemoteCameraControlDelegate>)delegate {
    _remoteCameraDelegate = delegate;
}

#pragma mark - RemoteCameraServiceDelegate
- (void)remoteCameraDidPair {
    if(_remoteCameraDelegate != nil && [_remoteCameraDelegate respondsToSelector:@selector(remoteCameraDidPair)]){
        [_remoteCameraDelegate remoteCameraDidPair];
    }
}

- (void)remoteCameraDidPlay {
    if(_remoteCameraDelegate != nil && [_remoteCameraDelegate respondsToSelector:@selector(remoteCameraDidPlay)]){
        [_remoteCameraDelegate remoteCameraDidPlay];
    }
}

- (void)remoteCameraDidStart:(BOOL)result {
    if(_remoteCameraDelegate != nil && [_remoteCameraDelegate respondsToSelector:@selector(remoteCameraDidStart:)]){
        [_remoteCameraDelegate remoteCameraDidStart:result];
    }
}

- (void)remoteCameraDidStop:(BOOL)result {
    if(_remoteCameraDelegate != nil && [_remoteCameraDelegate respondsToSelector:@selector(remoteCameraDidStop:)]){
        [_remoteCameraDelegate remoteCameraDidStop:result];
    }
}

- (void)remoteCameraDidChange:(RemoteCameraProperty)property{
    if(_remoteCameraDelegate != nil && [_remoteCameraDelegate respondsToSelector:@selector(remoteCameraDidChange:)]){
        [_remoteCameraDelegate remoteCameraDidChange:property];
    }
}

- (void)remoteCameraErrorDidOccur:(RemoteCameraError)error {
    if(_remoteCameraDelegate != nil && [_remoteCameraDelegate respondsToSelector:@selector(remoteCameraErrorDidOccur:)]){
        [_remoteCameraDelegate remoteCameraErrorDidOccur:error];
    }
}

@end
