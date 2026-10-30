/*@file
  Copyright (C) 2022 Marvin Häuser. All rights reserved.
  SPDX-License-Identifier: BSD-3-Clause
*/

#ifndef _BTPreprocessor_h_
#define _BTPreprocessor_h_

#include <Foundation/NSString.h>

__BEGIN_DECLS

/// The Battery Toolkit bundle identifier.
extern const NSString *const BT_APP_ID;

/// The Battery Toolkit Service identifier.
extern const NSString *const BT_SERVICE_ID;

/// The Battery Toolkit daemon identifier.
extern const NSString *const BT_DAEMON_ID;

/// The Battery Toolkit daemon connection name.
extern const NSString *const BT_DAEMON_CONN;

/// The Battery Toolkit Autostart identifier.
extern const NSString *const BT_AUTOSTART_ID;

/// The Battery Toolkit codesign Common Name.
extern const NSString *const BT_CODESIGN_CN;

/// The Battery Toolkit codesign certificate SHA-1 pin for independently
/// signed builds. Empty for Apple-issued certificates.
extern const NSString *const BT_CODESIGN_CERT_SHA1;

__END_DECLS

#endif
