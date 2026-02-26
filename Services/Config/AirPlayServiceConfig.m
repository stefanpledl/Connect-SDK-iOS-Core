//
//  AirPlayServiceConfig.m
//  Connect SDK
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

#import "AirPlayServiceConfig.h"

static NSString *const kAirPlayServiceConfigAuthToken = @"authToken";

@implementation AirPlayServiceConfig

- (instancetype)initWithJSONObject:(NSDictionary *)dictionary
{
    self = [super initWithJSONObject:dictionary];
    if (self)
    {
        self.authToken = dictionary[kAirPlayServiceConfigAuthToken];
    }
    return self;
}

- (NSDictionary *)toJSONObject
{
    NSMutableDictionary *dictionary = [[super toJSONObject] mutableCopy];

    if (self.authToken)
        dictionary[kAirPlayServiceConfigAuthToken] = self.authToken;

    return [NSDictionary dictionaryWithDictionary:dictionary];
}

- (void)setAuthToken:(NSString *)authToken
{
    _authToken = authToken;
    if (self.delegate && [self.delegate respondsToSelector:@selector(serviceConfigUpdate:)])
        [self.delegate serviceConfigUpdate:self];
}

@end
