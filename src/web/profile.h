// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#import <Foundation/Foundation.h>

NSString* cookie_file(NSString* spec);
NSArray<NSHTTPCookie*>* read_cookies(NSString* db);
NSDictionary* read_session_store(NSString* profile);
NSArray<NSDictionary*>* read_history(NSString* profile, NSString* like, int limit);
NSArray<NSHTTPCookie*>* read_session_cookies(NSString* profile);
NSURL* origin_url(NSString* site);
NSDictionary<NSString*, NSString*>* read_storage(NSString* profile, NSURL* origin);
